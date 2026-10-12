import Foundation
import CryptoKit
import Darwin

/// Public CA certificates are hashed in bounded chunks, never retained or logged.
/// Capture runs on the backend queue; revalidation is explicitly off MainActor.
struct TransportCAFile: Equatable, Sendable, CustomStringConvertible {
    private let url: URL
    private let digest: Data
    var description: String { "TransportCAFile([redacted])" }

    init(url: URL, cancellation: FTPCancellationToken) throws {
        self.url = url
        digest = try Self.readDigest(url, cancellation: cancellation)
    }
    func validate(cancellation: FTPCancellationToken) async throws {
        try await Task.detached(priority: .userInitiated) {
            try validateOnBackendQueue(cancellation: cancellation)
        }.value
    }
    func validateOnBackendQueue(cancellation: FTPCancellationToken) throws {
        guard try Self.readDigest(url, cancellation: cancellation) == digest else {
            throw FTPError.security("TLS CA 内容已变化，旧会话已失效，请明确重新开始。")
        }
    }
    private static func readDigest(_ url: URL, cancellation: FTPCancellationToken) throws -> Data {
        try cancellation.checkCancellation()
        // Existing CA paths may be symlinks. Bind the read to the opened regular file,
        // not a metadata-only signature, without changing that compatibility rule.
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw FTPError.security("无法核对 TLS CA，旧会话不能复用。") }
        defer { Darwin.close(fd) }
        var before = stat(), after = stat(), currentPath = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0 else {
            throw FTPError.security("TLS CA 不是可核对的普通文件，旧会话不能复用。")
        }
        var hash = SHA256(), count: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try cancellation.checkCancellation()
            let length = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if length < 0, errno == EINTR { continue }
            guard length >= 0 else { throw FTPError.security("读取 TLS CA 失败，旧会话不能复用。") }
            if length == 0 { break }
            let next = count.addingReportingOverflow(Int64(length))
            guard !next.overflow, next.partialValue <= before.st_size else {
                throw FTPError.security("核对期间 TLS CA 已变化，旧会话不能复用。")
            }
            count = next.partialValue
            hash.update(data: Data(buffer.prefix(length)))
        }
        try cancellation.checkCancellation()
        guard fstat(fd, &after) == 0, fstatat(AT_FDCWD, url.path, &currentPath, 0) == 0,
              count == before.st_size, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_mode == after.st_mode, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              currentPath.st_dev == after.st_dev, currentPath.st_ino == after.st_ino else {
            throw FTPError.security("核对期间 TLS CA 已变化，旧会话不能复用。")
        }
        return Data(hash.finalize())
    }
}

struct TransportConfiguration: Equatable, Sendable {
    let connectTimeout: Int
    let responseTimeout: Int
    let stallTimeout: Int
    let ca: TransportCAFile?
    init(connectTimeout: Int = 15, responseTimeout: Int = 60, stallTimeout: Int = 60, ca: TransportCAFile? = nil) {
        self.connectTimeout = connectTimeout; self.responseTimeout = responseTimeout
        self.stallTimeout = stallTimeout; self.ca = ca
    }
}

/// One owner, no process-wide pool. Concrete C drivers attach in tasks 10.2/10.3.
/// The close callback must synchronously release an idle driver, never an active one.
@MainActor
final class TransferTransportSession {
    struct Key: Equatable, CustomStringConvertible {
        let transport: FileTransport
        let host: String
        let port: Int
        let authenticationID: UUID
        let configuration: TransportConfiguration
        let trustRevision: UUID?
        var description: String { "TransportSessionKey([redacted])" }
    }
    enum State: Equatable { case open, busy, invalidating, closed }
    private(set) var state = State.open
    let key: Key
    private let credentials: FTPCredentials
    private let executor: TransferExecutor
    private var closeDriver: (() -> Void)?
    private var activeToken: FTPCancellationToken?
    private var completedOperations = 0

    init(endpoint: FTPEndpoint, credentials: FTPCredentials, configuration: TransportConfiguration,
         trustRevision: UUID? = nil, executor: TransferExecutor, closeDriver: @escaping () -> Void) {
        self.credentials = credentials; self.executor = executor; self.closeDriver = closeDriver
        key = Key(transport: endpoint.transport, host: endpoint.host.lowercased(), port: endpoint.port,
            authenticationID: UUID(), configuration: configuration, trustRevision: trustRevision)
    }
    func execute<T>(job: TransferJob, endpoint: FTPEndpoint, credentials: FTPCredentials,
                    configuration: TransportConfiguration, trustRevision: UUID? = nil,
                    operation: (FTPCancellationToken) async throws -> T) async throws -> T {
        guard state == .open else { throw FTPError.security("会话不可用或已有操作，未开始新的请求。") }
        guard executor.activeJob === job, job.outcome == nil else {
            throw FTPError.localFile("会话操作必须属于共享执行器的当前任务。")
        }
        guard endpoint.transport == key.transport, endpoint.host.lowercased() == key.host, endpoint.port == key.port,
              job.endpoint.transport == key.transport, job.endpoint.host.lowercased() == key.host, job.endpoint.port == key.port,
              credentials.sameAuthentication(as: self.credentials), job.credentials.sameAuthentication(as: self.credentials),
              configuration == key.configuration,
              trustRevision == key.trustRevision,
              key.transport != .sftp || key.trustRevision != nil || completedOperations == 0 else {
            invalidate()
            throw FTPError.security("固定认证、端点或信任配置已失效，旧会话不能复用。")
        }
        let token = FTPCancellationToken(parent: job.cancellation)
        activeToken = token; state = .busy
        do {
            try token.checkCancellation()
            if key.transport.requiresTLS, let ca = key.configuration.ca { try await ca.validate(cancellation: token) }
            try token.checkCancellation()
            let result = try await operation(token)
            try token.checkCancellation()
            completedOperations += 1
            finishOperation(healthy: true)
            return result
        } catch {
            finishOperation(healthy: false)
            throw error
        }
    }
    /// Active invalidation requests cancellation now, but cleanup waits for backend return.
    func invalidate() {
        guard state != .closed else { return }
        if state == .busy || state == .invalidating {
            state = .invalidating; activeToken?.cancel()
        } else { close() }
    }
    private func finishOperation(healthy: Bool) {
        activeToken?.cancel() // Retained operation callbacks cannot outlive their permit.
        activeToken = nil
        if healthy, state == .busy { state = .open }
        else { close() }
    }
    private func close() {
        state = .closed
        let close = closeDriver; closeDriver = nil
        close?()
    }
    deinit { closeDriver?() }
}
