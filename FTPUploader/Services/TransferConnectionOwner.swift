import Foundation

@MainActor
protocol ManagedTransferServing: FTPServing {
    var lifecycle: TransferTransportSession { get }
    func invalidate()
}

/// Only backend-classified directory-operation errors may enter the one-shot read branch.
struct DirectoryCreationError: LocalizedError {
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}

@MainActor
protocol DirectoryFailureRechecking {
    func recheckDirectory(endpoint: FTPEndpoint, parent: RemotePath, encoding: FTPTextEncoding,
                          credentials: FTPCredentials, cancellation: FTPCancellationToken,
                          after error: Error) async throws -> DirectoryListing
}

/// One single-file attempt, scan generation or confirmed batch owns this adapter.
/// It never selects targets, grants overwrite permission, rereads keys or retries a write.
@MainActor
final class TransferConnectionOwner: FTPServing, DirectoryFailureRechecking {
    typealias Scheduler = (Double, @escaping @MainActor () -> Void) -> () -> Void
    private let base: FTPServing
    private let endpoint: FTPEndpoint
    private let credentials: FTPCredentials
    private let executor: TransferExecutor
    private let readOnly: Bool
    private let schedule: Scheduler
    private var session: ManagedTransferServing?
    private var fixedConfiguration: TransportConfiguration?
    private var failed = false
    private var ended = false
    private var busy = false
    private var idleGeneration = UUID()
    private var cancelIdle: (() -> Void)?
    private(set) var idleExpired = false
    var lifecycleState: TransferTransportSession.State? { session?.lifecycle.state }

    init(base: FTPServing, endpoint: FTPEndpoint, credentials: FTPCredentials, executor: TransferExecutor,
         readOnly: Bool = false, schedule: @escaping Scheduler = TransferConnectionOwner.scheduleIdle) {
        self.base = base; self.endpoint = endpoint; self.credentials = credentials; self.executor = executor
        self.readOnly = readOnly; self.schedule = schedule
    }
    nonisolated static func scheduleIdle(_ delay: Double, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }; action()
        }
        return { task.cancel() }
    }
    private func cancelTimer() {
        idleGeneration = UUID(); cancelIdle?(); cancelIdle = nil
    }
    /// Also used for overwrite waits: no active backend operation is ever closed by this timer.
    func pause() {
        cancelTimer()
        guard !ended, !failed, !busy, session?.lifecycle.state == .open else { return }
        let generation = idleGeneration
        cancelIdle = schedule(60) { [weak self] in
            guard let self, self.idleGeneration == generation, !self.busy, !self.ended else { return }
            self.session?.invalidate(); self.session = nil; self.idleExpired = true
            self.cancelTimer()
        }
    }
    /// Called only by an explicit start/continue/overwrite-confirm action, never on backend error.
    func resume() {
        cancelTimer()
        guard !ended, !busy else { return }
        if failed || idleExpired { session?.invalidate(); session = nil }
        failed = false; idleExpired = false
    }
    func stopAfterFailure() {
        cancelTimer(); failed = true; session?.invalidate()
    }
    func close() {
        cancelTimer(); ended = true; session?.invalidate()
        // Active drivers stay retained by the awaited managed operation until return.
        if !busy { session = nil }
    }
    private func makeSession(cancellation: FTPCancellationToken) async throws -> ManagedTransferServing? {
        guard let client = base as? FTPClient else { return nil }
        if let fixedConfiguration, let ca = fixedConfiguration.ca { try await ca.validate(cancellation: cancellation) }
        try cancellation.checkCancellation()
        let created: ManagedTransferServing
        if endpoint.transport == .sftp {
            created = try client.makeSSHSession(endpoint: endpoint, credentials: credentials, executor: executor)
        } else {
            created = try await client.makeCurlSession(endpoint: endpoint, credentials: credentials,
                executor: executor, cancellation: cancellation)
        }
        if let fixedConfiguration, created.lifecycle.key.configuration != fixedConfiguration {
            created.invalidate(); throw FTPError.security("固定 TLS 配置已变化，未重新发送请求。")
        }
        fixedConfiguration = created.lifecycle.key.configuration
        return created
    }
    private func run<T>(endpoint: FTPEndpoint, credentials: FTPCredentials, cancellation: FTPCancellationToken,
                        operation: (FTPServing) async throws -> T) async throws -> T {
        try cancellation.checkCancellation()
        guard !ended, !failed, !idleExpired, !busy else { throw FTPError.security("会话已停止，请明确继续或重新核对；未重发请求。") }
        guard endpoint.transport == self.endpoint.transport, endpoint.host.lowercased() == self.endpoint.host.lowercased(),
              endpoint.port == self.endpoint.port, credentials.sameAuthentication(as: self.credentials) else {
            close(); throw FTPError.security("会话固定身份已失效。")
        }
        cancelTimer(); busy = true
        defer { busy = false; if ended { session = nil } }
        do {
            if session == nil { session = try await makeSession(cancellation: cancellation) }
            try cancellation.checkCancellation()
            guard !ended else { throw CancellationError() }
            let backend: FTPServing = (session as FTPServing?) ?? base
            // Preflight and scans borrow the same serial executor without changing an actual file job's outcome.
            if let job = executor.activeJob {
                guard job.cancellation === cancellation else { throw FTPError.localFile("共享执行器正由其他任务占用。") }
                return try await operation(backend)
            }
            let permit = TransferJob(direction: .download, endpoint: self.endpoint, path: .root, encoding: .utf8,
                credentials: self.credentials, localURL: FileManager.default.temporaryDirectory, cancellation: cancellation,
                name: "只读核对")
            var result: T?
            try await executor.execute(permit) { result = try await operation(backend) }
            guard let result else { throw FTPError.localFile("只读核对未返回结果。") }
            return result
        } catch {
            failed = true; session?.invalidate()
            throw error
        }
    }
    func list(endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding?, credentials: FTPCredentials,
              cancellation: FTPCancellationToken) async throws -> DirectoryListing {
        try await run(endpoint: endpoint, credentials: credentials, cancellation: cancellation) { backend in
            try await backend.list(endpoint: endpoint, path: path, encoding: encoding, credentials: credentials, cancellation: cancellation)
        }
    }
    func listPreviewTargets(endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding, credentials: FTPCredentials,
                            cancellation: FTPCancellationToken) async throws -> DirectoryListing {
        try await run(endpoint: endpoint, credentials: credentials, cancellation: cancellation) { backend in
            try await backend.listPreviewTargets(endpoint: endpoint, path: path, encoding: encoding, credentials: credentials, cancellation: cancellation)
        }
    }
    func checkUploadTarget(endpoint: FTPEndpoint, path: RemotePath, name: String, encoding: FTPTextEncoding,
                           credentials: FTPCredentials, cancellation: FTPCancellationToken) async throws -> RemoteEntry? {
        try await run(endpoint: endpoint, credentials: credentials, cancellation: cancellation) { backend in
            try await backend.checkUploadTarget(endpoint: endpoint, path: path, name: name, encoding: encoding, credentials: credentials, cancellation: cancellation)
        }
    }
    func createDirectory(endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding, credentials: FTPCredentials,
                         cancellation: FTPCancellationToken) async throws {
        guard !readOnly else { throw FTPError.localFile("扫描会话不能写入。") }
        try await run(endpoint: endpoint, credentials: credentials, cancellation: cancellation) { backend in
            try await backend.createDirectory(endpoint: endpoint, path: path, encoding: encoding, credentials: credentials, cancellation: cancellation)
        }
    }
    func recheckDirectory(endpoint: FTPEndpoint, parent: RemotePath, encoding: FTPTextEncoding,
                          credentials: FTPCredentials, cancellation: FTPCancellationToken, after error: Error) async throws -> DirectoryListing {
        try cancellation.checkCancellation()
        guard !ended, !busy, failed else { throw error }
        if !(base is FTPClient) {
            // Existing injected backends retain their own failure semantics and have no connection cache.
            return try await base.list(endpoint: endpoint, path: parent, encoding: encoding, credentials: credentials, cancellation: cancellation)
        }
        guard error is DirectoryCreationError else { throw error }
        let previousRevision = session?.lifecycle.key.trustRevision
        session?.invalidate(); session = nil
        // A fresh scope can perform only this read. No write permit is restored by failure recovery.
        let fresh = try await makeSession(cancellation: cancellation)
        if let fresh, fresh.lifecycle.key.trustRevision != previousRevision {
            fresh.invalidate(); throw FTPError.security("主机信任已变化，建目录失败后的复核已阻止。")
        }
        session = fresh; failed = false
        do {
            let listing = try await list(endpoint: endpoint, path: parent, encoding: encoding, credentials: credentials, cancellation: cancellation)
            // This connection is not retained as a generic error-recovery pool.
            session?.invalidate(); session = nil
            return listing
        } catch { failed = true; session?.invalidate(); throw error }
    }
    func upload(endpoint: FTPEndpoint, path: RemotePath, file: URL, encoding: FTPTextEncoding, credentials: FTPCredentials,
                cancellation: FTPCancellationToken, progress: @escaping (Int64, Int64) -> Void) async throws {
        let selected = try SelectedLocalFile(url: file); defer { selected.endAccess() }
        let snapshot = try await selected.snapshot(cancellation: cancellation)
        let source = try await selected.verifiedSource(matching: snapshot, cancellation: cancellation)
        try await upload(endpoint: endpoint, path: path, source: source, encoding: encoding, credentials: credentials,
            cancellation: cancellation, progress: progress)
    }
    func upload(endpoint: FTPEndpoint, path: RemotePath, source: SelectedLocalFile.VerifiedSource, encoding: FTPTextEncoding,
                credentials: FTPCredentials, cancellation: FTPCancellationToken, progress: @escaping (Int64, Int64) -> Void) async throws {
        guard !readOnly else { throw FTPError.localFile("扫描会话不能写入。") }
        try await run(endpoint: endpoint, credentials: credentials, cancellation: cancellation) { backend in
            try await backend.upload(endpoint: endpoint, path: path, source: source, encoding: encoding, credentials: credentials,
                cancellation: cancellation, progress: progress)
        }
    }
    func download(endpoint: FTPEndpoint, path: RemotePath, credentials: FTPCredentials, cancellation: FTPCancellationToken,
                  receive: @escaping (Data) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws {
        guard !readOnly else { throw FTPError.localFile("扫描会话不能接收文件。") }
        try await run(endpoint: endpoint, credentials: credentials, cancellation: cancellation) { backend in
            try await backend.download(endpoint: endpoint, path: path, credentials: credentials, cancellation: cancellation, receive: receive, progress: progress)
        }
    }
    deinit { cancelIdle?() }
}
