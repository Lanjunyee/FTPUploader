import Foundation

/// One token per operation; never reset or reuse a cancelled token.
final class FTPCancellationToken: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
    func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }
}

protocol FTPServing {
    func download(endpoint: FTPEndpoint, path: RemotePath, credentials: FTPCredentials, cancellation: FTPCancellationToken,
                  receive: @escaping (Data) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws
    func trustHost(_ identity: SSHHostIdentity) throws
    func resetHost(_ identity: SSHHostIdentity) throws
    func checkUploadTarget(endpoint: FTPEndpoint, path: RemotePath, name: String, encoding: FTPTextEncoding,
                           credentials: FTPCredentials, cancellation: FTPCancellationToken) async throws -> RemoteEntry?
    func list(endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding?, credentials: FTPCredentials, cancellation: FTPCancellationToken) async throws -> DirectoryListing
    func upload(endpoint: FTPEndpoint, path: RemotePath, file: URL, encoding: FTPTextEncoding, credentials: FTPCredentials, cancellation: FTPCancellationToken,
                progress: @escaping (Int64, Int64) -> Void) async throws
}

extension FTPServing {
    func download(endpoint: FTPEndpoint, path: RemotePath, credentials: FTPCredentials, cancellation: FTPCancellationToken,
                  receive: @escaping (Data) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws {
        throw FTPError.localFile("此后端不支持下载。")
    }

    func trustHost(_ identity: SSHHostIdentity) throws { throw FTPError.security("当前后端不支持主机信任。") }
    func resetHost(_ identity: SSHHostIdentity) throws { throw FTPError.security("当前后端不支持主机信任重置。") }
    func resolveInitialDirectory(endpoint: FTPEndpoint, policy: FTPEncodingPolicy, credentials: FTPCredentials,
                                 cancellation: FTPCancellationToken) async throws -> (path: RemotePath, listing: DirectoryListing) {
        try cancellation.checkCancellation()
        if let encoding = endpoint.transport == .sftp ? FTPTextEncoding.utf8 : policy.explicitEncoding {
            // Encode every segment before the first request, so invalid local
            // input cannot partially traverse the server.
            let path = try endpoint.initialPath(using: encoding)
            let listing = try await list(endpoint: endpoint, path: path, encoding: encoding, credentials: credentials, cancellation: cancellation)
            return (path, listing)
        }
        if endpoint.hasRawInitialPath {
            let hint: FTPTextEncoding? = endpoint.initialPath.components.contains {
                String(data: $0.bytes, encoding: .utf8) == nil
            } ? .gb18030 : nil
            let listing = try await list(endpoint: endpoint, path: endpoint.initialPath, encoding: hint, credentials: credentials, cancellation: cancellation)
            var path = RemotePath.root
            for component in endpoint.initialPath.components {
                path = try path.appending(name: listing.encoding.decode(component.bytes), bytes: component.bytes)
            }
            return (path, listing)
        }
        var path = RemotePath.root
        var listing: DirectoryListing
        do { listing = try await list(endpoint: endpoint, path: path, encoding: nil, credentials: credentials, cancellation: cancellation) }
        catch {
            if cancellation.isCancelled || error is CancellationError { throw CancellationError() }
            if let first = endpoint.initialSegments.first {
                throw FTPError.initialPath(first.source, "根目录无法读取，请选择明确的文件名编码或使用百分号原始字节路径。 " + error.localizedDescription)
            }
            throw error
        }
        var confirmedEncoding: FTPTextEncoding? = listing.entries.contains { $0.rawName.contains { $0 >= 128 } } ? listing.encoding : nil
        for segment in endpoint.initialSegments {
            try cancellation.checkCancellation()
            do {
                let bytes = try segment.encoded(using: confirmedEncoding ?? .utf8)
                if let entry = listing.entries.first(where: { $0.rawName == bytes }) {
                    guard entry.isDirectory else { throw FTPError.invalidName }
                    path = try path.appending(name: entry.name, bytes: entry.rawName)
                } else {
                    guard confirmedEncoding == nil else {
                        throw FTPError.invalidAddress("列表中没有此目录，目标未改变。")
                    }
                    // ASCII/empty listings prove no encoding. Try UTF-8 only;
                    // failure asks for an explicit policy instead of guessing.
                    path = try path.appending(name: FTPTextEncoding.utf8.decode(bytes), bytes: bytes)
                }
                listing = try await list(endpoint: endpoint, path: path, encoding: confirmedEncoding, credentials: credentials, cancellation: cancellation)
                if listing.entries.contains(where: { $0.rawName.contains { $0 >= 128 } }) { confirmedEncoding = listing.encoding }
            } catch {
                if cancellation.isCancelled || error is CancellationError { throw CancellationError() }
                let hint = confirmedEncoding == nil ? " 根目录为空或仅有 ASCII 名称，请选择明确的 UTF-8 或 GB18030 编码。" : ""
                throw FTPError.initialPath(segment.source, error.localizedDescription + hint)
            }
        }
        return (path, listing)
    }

    /// Read-only check. The caller must obtain per-operation authorization for a
    /// returned ordinary file before invoking the upload transport.
    func checkUploadTarget(endpoint: FTPEndpoint, path: RemotePath, name: String, encoding: FTPTextEncoding,
                           credentials: FTPCredentials, cancellation: FTPCancellationToken) async throws -> RemoteEntry? {
        let bytes = try encoding.encode(name)
        try RemotePath.validateName(bytes)
        let listing = try await list(endpoint: endpoint, path: path, encoding: encoding, credentials: credentials, cancellation: cancellation)
        try cancellation.checkCancellation()
        return listing.entries.first { $0.rawName == bytes }
    }

    func list(endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding? = nil,
              credentials: FTPCredentials = .anonymous) async throws -> DirectoryListing {
        try await list(endpoint: endpoint, path: path, encoding: encoding, credentials: credentials, cancellation: FTPCancellationToken())
    }
    func upload(endpoint: FTPEndpoint, path: RemotePath, file: URL, encoding: FTPTextEncoding,
                credentials: FTPCredentials = .anonymous, progress: @escaping (Int64, Int64) -> Void) async throws {
        try await upload(endpoint: endpoint, path: path, file: file, encoding: encoding, credentials: credentials,
                         cancellation: FTPCancellationToken(), progress: progress)
    }
}

final class FTPClient: FTPServing, @unchecked Sendable {
    private final class TransferContext {
        var data = Data()
        var receive: ((Data) throws -> Void)?
        var failure: Error?
        let progress: ((Int64, Int64) -> Void)?
        let cancellation: FTPCancellationToken
        init(cancellation: FTPCancellationToken, progress: ((Int64, Int64) -> Void)? = nil) { self.cancellation = cancellation; self.progress = progress }
    }

    private let queue = DispatchQueue(label: "local.ftpuploader.ftp", qos: .userInitiated)
    private let options: FTPOptions
    private let sftp: SFTPClient
    private let caFile: String?
    private let tlsAvailable: () -> Bool

    init(connectTimeout: Int = 15, responseTimeout: Int = 60, stallTimeout: Int = 60, caFile: String? = nil, tlsAvailable: @escaping () -> Bool = { ftps_available() != 0 }, trust: HostTrustStoring = HostTrustStore()) {
        self.sftp = SFTPClient(trust: trust, connectTimeout: connectTimeout, responseTimeout: responseTimeout, stallTimeout: stallTimeout)
        self.caFile = caFile; self.tlsAvailable = tlsAvailable
        options = FTPOptions(connect_timeout: connectTimeout, response_timeout: responseTimeout, stall_timeout: stallTimeout, tls_mode: 0, ca_file: nil)
    }

    func trustHost(_ identity: SSHHostIdentity) throws { try sftp.trustHost(identity) }
    func resetHost(_ identity: SSHHostIdentity) throws { try sftp.resetHost(identity) }

    private func checkCapability(_ endpoint: FTPEndpoint) throws {
        guard endpoint.transport != .sftp else { throw FTPError.security("此构建缺少 SFTP 后端，无法连接；请使用包含 SFTP 后端的版本。") }
        if endpoint.transport.requiresTLS && !tlsAvailable() {
            throw FTPError.security("当前运行环境不支持 TLS，无法连接 FTPS；没有发送密码，请使用支持 TLS 的构建。")
        }
    }

    private func withOptions<T>(_ endpoint: FTPEndpoint, _ work: (FTPOptions) throws -> T) rethrows -> T {
        var configured = options
        configured.tls_mode = endpoint.transport == .ftpsImplicit ? 2 : (endpoint.transport == .ftpsExplicit ? 1 : 0)
        if let caFile {
            return try caFile.withCString { pointer in
                configured.ca_file = pointer
                return try work(configured)
            }
        }
        return try work(configured)
    }

    func list(endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding? = nil, credentials: FTPCredentials = .anonymous, cancellation: FTPCancellationToken) async throws -> DirectoryListing {
        if endpoint.transport == .sftp {
            return try await sftp.list(endpoint: endpoint, path: path, encoding: encoding, credentials: credentials, cancellation: cancellation)
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try cancellation.checkCancellation()
                    try checkCapability(endpoint)
                    let url = endpoint.directoryURL(path)
                    let data: Data
                    let machineReadable: Bool
                    do {
                        data = try fetch(endpoint: endpoint, url: url, method: "MLSD", credentials: credentials, cancellation: cancellation)
                        machineReadable = true
                    } catch let error as FTPError where [500, 502, 504].contains(error.responseCode ?? 0) {
                        data = try fetch(endpoint: endpoint, url: url, method: "LIST", credentials: credentials, cancellation: cancellation)
                        machineReadable = false
                    }
                    try cancellation.checkCancellation()
                    let listing = try DirectoryParser.parse(data, machineReadable: machineReadable, preferredEncoding: encoding)
                    continuation.resume(returning: listing)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func fetch(endpoint: FTPEndpoint, url: String, method: String, credentials: FTPCredentials, cancellation: FTPCancellationToken) throws -> Data {
        try cancellation.checkCancellation()
        let context = TransferContext(cancellation: cancellation)
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        let result = withOptions(endpoint) { options in
            credentials.username.withCString { user in
            credentials.password.withCString { password in
                ftp_list(url, method, user, password, options, { bytes, count, pointer in
            guard let bytes, let pointer else { return 0 }
            let context = Unmanaged<TransferContext>.fromOpaque(pointer).takeUnretainedValue()
            // A malformed server cannot allocate unlimited memory for a directory.
            guard count <= 16 * 1024 * 1024 - context.data.count else { return 0 }
            context.data.append(bytes, count: count)
            return 1
        }, { pointer in
            guard let pointer else { return 1 }
            return Unmanaged<TransferContext>.fromOpaque(pointer).takeUnretainedValue().cancellation.isCancelled ? 1 : 0
        }, pointer)
            }
        }
        }
        try cancellation.checkCancellation()
        try validate(result, endpoint: endpoint, upload: false, credentials: credentials)
        return context.data
    }

    func upload(endpoint: FTPEndpoint, path: RemotePath, file: URL, encoding: FTPTextEncoding, credentials: FTPCredentials = .anonymous, cancellation: FTPCancellationToken,
                progress: @escaping (Int64, Int64) -> Void) async throws {
        if endpoint.transport == .sftp {
            return try await sftp.upload(endpoint: endpoint, path: path, file: file, encoding: encoding, credentials: credentials,
                                         cancellation: cancellation, progress: progress)
        }
        try cancellation.checkCancellation()
        try checkCapability(endpoint)
        let url = try endpoint.fileURL(path, name: file.lastPathComponent, encoding: encoding)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                let context = TransferContext(cancellation: cancellation, progress: progress)
                let pointer = Unmanaged.passUnretained(context).toOpaque()
                let result = withOptions(endpoint) { options in
                    credentials.username.withCString { user in
                    credentials.password.withCString { password in
                        ftp_upload(url, file.path, user, password, options, { sent, total, pointer in
                            guard let pointer else { return }
                            let context = Unmanaged<TransferContext>.fromOpaque(pointer).takeUnretainedValue()
                            if !context.cancellation.isCancelled { context.progress?(sent, total) }
                        }, { pointer in
            guard let pointer else { return 1 }
            return Unmanaged<TransferContext>.fromOpaque(pointer).takeUnretainedValue().cancellation.isCancelled ? 1 : 0
        }, pointer)
                    }
                }
                }
                do {
                    try cancellation.checkCancellation()
                    try validate(result, endpoint: endpoint, upload: true, credentials: credentials)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func download(endpoint: FTPEndpoint, path: RemotePath, credentials: FTPCredentials, cancellation: FTPCancellationToken,
                  receive: @escaping (Data) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws {
        if endpoint.transport == .sftp {
            return try await sftp.download(endpoint: endpoint, path: path, credentials: credentials, cancellation: cancellation,
                                           receive: receive, progress: progress)
        }
        try cancellation.checkCancellation()
        try checkCapability(endpoint)
        guard !path.components.isEmpty else { throw FTPError.invalidName }
        let remote = endpoint.display.replacingOccurrences(of: "ftp://", with: endpoint.transport == .ftpsImplicit ? "ftps://" : "ftp://")
            + "/" + path.components.map { RemotePath.percentEncode($0.bytes) }.joined(separator: "/")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                let context = TransferContext(cancellation: cancellation, progress: progress)
                context.receive = receive
                let pointer = Unmanaged.passUnretained(context).toOpaque()
                do {
                    try cancellation.checkCancellation()
                    let result = withOptions(endpoint) { options in
                        credentials.username.withCString { user in credentials.password.withCString { password in
                            ftp_download(remote, user, password, options, { bytes, count, pointer in
                                guard let bytes, let pointer else { return 0 }
                                let context = Unmanaged<TransferContext>.fromOpaque(pointer).takeUnretainedValue()
                                do {
                                    try context.cancellation.checkCancellation()
                                    try context.receive?(Data(bytes: bytes, count: count))
                                    return 1
                                } catch { context.failure = error; return 0 }
                            }, { received, total, pointer in
                                guard let pointer else { return }
                                let context = Unmanaged<TransferContext>.fromOpaque(pointer).takeUnretainedValue()
                                if !context.cancellation.isCancelled { context.progress?(received, total) }
                            }, { pointer in
                                guard let pointer else { return 1 }
                                return Unmanaged<TransferContext>.fromOpaque(pointer).takeUnretainedValue().cancellation.isCancelled ? 1 : 0
                            }, pointer)
                        } }
                    }
                    try cancellation.checkCancellation()
                    if let failure = context.failure { throw failure }
                    try validate(result, endpoint: endpoint, upload: false, credentials: credentials)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func validate(_ result: FTPResult, endpoint: FTPEndpoint, upload: Bool, credentials: FTPCredentials) throws {
        guard result.code == 0 else {
            let message = withUnsafePointer(to: result) { String(cString: ftp_result_message($0)) }
            if [35, 51, 58, 60, 64, 77, 80, 83, 90, 91].contains(Int(result.code)) {
                throw FTPError.security("FTPS 证书或 TLS 校验失败（连接错误 \(result.code)）。" + credentials.redacting(message))
            }
            if endpoint.transport.requiresTLS && result.response_code < 400 {
                throw FTPError.security("FTPS 连接或 TLS 数据传输失败（连接错误 \(result.code)）。" + credentials.redacting(message))
            }
            throw FTPError.transport(code: Int32(result.code), response: result.response_code, message: credentials.redacting(message), upload: upload, mode: credentials.mode)
        }
    }
}
