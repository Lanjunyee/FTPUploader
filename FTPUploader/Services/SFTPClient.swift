import Foundation

final class SFTPClient: FTPServing, @unchecked Sendable {
    private final class Context {
        let endpoint: FTPEndpoint
        let cancellation: FTPCancellationToken
        let trust: HostTrustStoring
        let progress: ((Int64, Int64) -> Void)?
        var entries: [RemoteEntry] = []
        var failure: Error?
        var receive: ((Data) throws -> Void)?
        var bytes = 0
        init(endpoint: FTPEndpoint, cancellation: FTPCancellationToken, trust: HostTrustStoring, progress: ((Int64, Int64) -> Void)?) {
            self.endpoint = endpoint; self.cancellation = cancellation; self.trust = trust; self.progress = progress
        }
    }
    private let queue = DispatchQueue(label: "local.ftpuploader.sftp", qos: .userInitiated)
    private let trust: HostTrustStoring
    private let options: FTPOptions
    private var driver: SSHTransportDriver?
    private init(copying client: SFTPClient, driver: SSHTransportDriver) {
        trust = client.trust; options = client.options; self.driver = driver
    }
    @MainActor
    func makeSession(endpoint: FTPEndpoint, credentials: FTPCredentials, executor: TransferExecutor) throws -> ManagedSSHTransferSession {
        guard endpoint.transport == .sftp, credentials.mode == .account, ssh_available() != 0 else {
            throw FTPError.security("SFTP 会话需要可用后端及固定账户认证。")
        }
        let revision = try trust.sessionRevision()
        let driver = try SSHTransportDriver()
        let configuration = TransportConfiguration(connectTimeout: Int(options.connect_timeout),
            responseTimeout: Int(options.response_timeout), stallTimeout: Int(options.stall_timeout))
        return ManagedSSHTransferSession(endpoint: endpoint, credentials: credentials, backend: SFTPClient(copying: self, driver: driver),
            driver: driver, configuration: configuration, trust: trust, revision: revision, executor: executor)
    }
    init(trust: HostTrustStoring = HostTrustStore(), connectTimeout: Int = 15, responseTimeout: Int = 60, stallTimeout: Int = 60) {
        self.trust = trust
        options = FTPOptions(connect_timeout: connectTimeout, response_timeout: responseTimeout, stall_timeout: stallTimeout, tls_mode: 0, ca_file: nil)
    }
    func trustHost(_ identity: SSHHostIdentity) throws { try trust.trust(identity) }
    func resetHost(_ identity: SSHHostIdentity) throws { try trust.reset(host: identity.host, port: identity.port) }

    private static let hostCallback: SSHHostCallback = { key, count, _, pointer in
        guard let key, let pointer, count <= 1024 * 1024 else { return 0 }
        let context = Unmanaged<Context>.fromOpaque(pointer).takeUnretainedValue()
        do {
            try context.cancellation.checkCancellation()
            try context.trust.verify(SSHHostIdentity(host: context.endpoint.host, port: context.endpoint.port, key: Data(bytes: key, count: count)))
            return 1
        } catch { context.failure = error; return 0 }
    }
    private static let cancelCallback: FTPCancelCallback = { pointer in
        guard let pointer else { return 1 }
        return Unmanaged<Context>.fromOpaque(pointer).takeUnretainedValue().cancellation.isCancelled ? 1 : 0
    }
    private static let entryCallback: SSHEntryCallback = { bytes, count, kind, size, pointer in
        guard let bytes, let pointer else { return 0 }
        let context = Unmanaged<Context>.fromOpaque(pointer).takeUnretainedValue()
        do {
            try context.cancellation.checkCancellation()
            guard context.entries.count < 100_000, count <= 16 * 1024 * 1024 - context.bytes else { throw FTPError.incompatibleListing }
            let data = Data(bytes: bytes, count: count)
            try RemotePath.validateName(data)
            guard let name = String(data: data, encoding: .utf8) else { throw FTPError.incompatibleEncoding }
            context.entries.append(RemoteEntry(name: name, rawName: data, kind: RemoteEntry.Kind(rawValue: Int(kind)) ?? .unknown, size: size >= 0 ? size : nil))
            context.bytes += count
            return 1
        } catch { context.failure = error; return 0 }
    }
    private func withAuthentication<T>(_ credentials: FTPCredentials,
                                       _ body: (UnsafePointer<UInt8>?, Int, UnsafePointer<CChar>?) -> T) -> T {
        guard let material = credentials.privateKey else { return body(nil, 0, nil) }
        return material.bytes.withUnsafeBytes { buffer in
            (credentials.passphrase ?? "").withCString { phrase in
                body(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, phrase)
            }
        }
    }
    private func pathString(_ path: RemotePath) throws -> String {
        for component in path.components {
            try RemotePath.validateName(component.bytes)
            guard String(data: component.bytes, encoding: .utf8) == component.name else { throw FTPError.incompatibleEncoding }
        }
        return path.display
    }
    private func validate(_ result: SSHResult, context: Context) throws {
        try context.cancellation.checkCancellation()
        if let failure = context.failure { throw failure }
        guard result.code == 0 else {
            if result.code == -1010 { throw FieldIssue(field: .passphrase, message: "私钥无法解锁或格式不支持，请检查私钥及口令（SSH -1010）。") }
            if result.code == -1011 { throw FTPError.security("服务器拒绝公钥认证，请核对用户名及服务器授权密钥（SSH -1011）。") }
            if result.code == -18 { throw FTPError.security("SFTP 账户密码认证失败（SSH -18），请核对账户。") }
            if result.code == -1001 { throw FTPError.security("SFTP 操作超时，尚未确认成功。") }
            if result.code == -1005 { throw FTPError.localFile("读取失败或文件大小发生变化。") }
            throw FTPError.security("SFTP 操作失败（SSH \(result.code)，SFTP \(result.status)），尚未确认成功。")
        }
    }
    func list(endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding?, credentials: FTPCredentials,
              cancellation: FTPCancellationToken) async throws -> DirectoryListing {
        guard ssh_available() != 0 else { throw FTPError.security("当前构建缺少可用 SFTP 后端，请更新应用；没有发送密码。") }
        guard endpoint.transport == .sftp, credentials.mode == .account else { throw FTPError.security("SFTP 需要账户认证。") }
        let remote = try pathString(path)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                let context = Context(endpoint: endpoint, cancellation: cancellation, trust: trust, progress: nil)
                let pointer = Unmanaged.passUnretained(context).toOpaque()
                do {
                    try cancellation.checkCancellation()
                    let handle = try driver?.borrow()
                    let result = withAuthentication(credentials) { key, length, phrase in ssh_session_list(handle, endpoint.host, Int32(endpoint.port), remote, credentials.username, credentials.password, key, length, phrase, options,
                                          Self.hostCallback, Self.entryCallback, Self.cancelCallback, pointer) }
                    try validate(result, context: context)
                    continuation.resume(returning: DirectoryListing(entries: context.entries, encoding: .utf8))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func createDirectory(endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding,
                         credentials: FTPCredentials, cancellation: FTPCancellationToken) async throws {
        guard ssh_available() != 0, endpoint.transport == .sftp, credentials.mode == .account, encoding == .utf8 else {
            throw FTPError.security("SFTP 目录创建需要可用后端、账户认证与 UTF-8 名称。")
        }
        guard !path.components.isEmpty else { throw FTPError.invalidName }
        let remote = try pathString(path)
        try cancellation.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                let context = Context(endpoint: endpoint, cancellation: cancellation, trust: trust, progress: nil)
                let pointer = Unmanaged.passUnretained(context).toOpaque()
                do {
                    try cancellation.checkCancellation()
                    let handle = try driver?.borrow()
                    let result = withAuthentication(credentials) { key, length, phrase in
                        ssh_session_mkdir(handle, endpoint.host, Int32(endpoint.port), remote, credentials.username, credentials.password,
                                  key, length, phrase, options, Self.hostCallback, Self.cancelCallback, pointer)
                    }
                    do { try validate(result, context: context) }
                    catch {
                        if driver != nil, result.directory_attempted != 0, context.failure == nil, !cancellation.isCancelled,
                           result.code != 0, result.code != -1000, result.code != -1003 {
                            throw DirectoryCreationError(underlying: error)
                        }
                        throw error
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func upload(endpoint: FTPEndpoint, path: RemotePath, file: URL, encoding: FTPTextEncoding, credentials: FTPCredentials,
                cancellation: FTPCancellationToken, progress: @escaping (Int64, Int64) -> Void) async throws {
        let selected = try SelectedLocalFile(url: file)
        defer { selected.endAccess() }
        let expected = try await selected.snapshot(cancellation: cancellation)
        let source = try await selected.verifiedSource(matching: expected, cancellation: cancellation)
        try await upload(endpoint: endpoint, path: path, source: source, encoding: encoding,
                         credentials: credentials, cancellation: cancellation, progress: progress)
    }

    func upload(endpoint: FTPEndpoint, path: RemotePath, source: SelectedLocalFile.VerifiedSource,
                encoding: FTPTextEncoding, credentials: FTPCredentials,
                cancellation: FTPCancellationToken, progress: @escaping (Int64, Int64) -> Void) async throws {
        guard ssh_available() != 0 else { throw FTPError.security("当前构建缺少可用 SFTP 后端，请更新应用；没有发送密码。") }
        guard endpoint.transport == .sftp, credentials.mode == .account, encoding == .utf8 else { throw FTPError.security("SFTP 需要账户认证和 UTF-8 文件名。") }
        let parent = try pathString(path)
        let name = source.url.lastPathComponent
        try RemotePath.validateName(FTPTextEncoding.utf8.encode(name))
        let remote = parent + (parent == "/" ? "" : "/") + name
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                let context = Context(endpoint: endpoint, cancellation: cancellation, trust: trust, progress: progress)
                let pointer = Unmanaged.passUnretained(context).toOpaque()
                do {
                    try cancellation.checkCancellation()
                    try source.validateDescriptor()
                    let handle = try driver?.borrow()
                    let result = withAuthentication(credentials) { key, length, phrase in ssh_session_upload_fd(handle, endpoint.host, Int32(endpoint.port), remote, source.descriptor, credentials.username, credentials.password, key, length, phrase, options,
                                            Self.hostCallback, { sent, total, pointer in
                        guard let pointer else { return }
                        let context = Unmanaged<Context>.fromOpaque(pointer).takeUnretainedValue()
                        if !context.cancellation.isCancelled { context.progress?(sent, total) }
                    }, Self.cancelCallback, pointer) }
                    try validate(result, context: context)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func download(endpoint: FTPEndpoint, path: RemotePath, credentials: FTPCredentials, cancellation: FTPCancellationToken,
                  receive: @escaping (Data) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws {
        guard ssh_available() != 0, endpoint.transport == .sftp, credentials.mode == .account else {
            throw FTPError.security("SFTP 下载需要可用的后端和账户认证。")
        }
        let remote = try pathString(path)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                let context = Context(endpoint: endpoint, cancellation: cancellation, trust: trust, progress: progress)
                context.receive = receive
                let pointer = Unmanaged.passUnretained(context).toOpaque()
                do {
                    try cancellation.checkCancellation()
                    let handle = try driver?.borrow()
                    let result = withAuthentication(credentials) { key, length, phrase in ssh_session_download(handle, endpoint.host, Int32(endpoint.port), remote, credentials.username, credentials.password, key, length, phrase, options,
                                              Self.hostCallback, { bytes, count, pointer in
                        guard let bytes, let pointer else { return 0 }
                        let context = Unmanaged<Context>.fromOpaque(pointer).takeUnretainedValue()
                        do {
                            try context.cancellation.checkCancellation()
                            try context.receive?(Data(bytes: bytes, count: count)); return 1
                        } catch { context.failure = error; return 0 }
                    }, { received, total, pointer in
                        guard let pointer else { return }
                        let context = Unmanaged<Context>.fromOpaque(pointer).takeUnretainedValue()
                        if !context.cancellation.isCancelled { context.progress?(received, total) }
                    }, Self.cancelCallback, pointer) }
                    try validate(result, context: context)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

}
