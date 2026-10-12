import Foundation

/// Borrowed only on the backend serial queue; closure waits for backend return.
final class SSHTransportDriver: @unchecked Sendable {
    private var handle: OpaquePointer? = ssh_session_create()
    init() throws {
        guard handle != nil else { throw FTPError.security("无法建立 SFTP 会话。") }
    }
    func borrow() throws -> OpaquePointer {
        guard let handle else { throw FTPError.security("SFTP 会话已关闭，未重新发送请求。") }
        return handle
    }
    func close() {
        if let handle { ssh_session_destroy(handle) }; handle = nil
    }
    deinit { if let handle { ssh_session_destroy(handle) } }
}

@MainActor
final class ManagedSSHTransferSession: ManagedTransferServing {
    let lifecycle: TransferTransportSession
    private let backend: SFTPClient
    private let executor: TransferExecutor
    private let configuration: TransportConfiguration
    private let trust: HostTrustStoring
    init(endpoint: FTPEndpoint, credentials: FTPCredentials, backend: SFTPClient, driver: SSHTransportDriver,
         configuration: TransportConfiguration, trust: HostTrustStoring, revision: UUID?, executor: TransferExecutor) {
        self.backend = backend; self.executor = executor; self.configuration = configuration; self.trust = trust
        lifecycle = TransferTransportSession(endpoint: endpoint, credentials: credentials, configuration: configuration,
            trustRevision: revision, executor: executor, closeDriver: { driver.close() })
    }
    func invalidate() { lifecycle.invalidate() }
    private func run<T>(endpoint: FTPEndpoint, credentials: FTPCredentials, cancellation: FTPCancellationToken,
                        operation: (FTPCancellationToken) async throws -> T) async throws -> T {
        try cancellation.checkCancellation()
        guard let job = executor.activeJob, job.cancellation === cancellation else {
            throw FTPError.localFile("会话请求不属于当前固定任务。")
        }
        let revision: UUID?
        do { revision = try trust.sessionRevision() }
        catch { lifecycle.invalidate(); throw error }
        return try await lifecycle.execute(job: job, endpoint: endpoint, credentials: credentials,
            configuration: configuration, trustRevision: revision, operation: operation)
    }
    func list(endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding?, credentials: FTPCredentials,
              cancellation: FTPCancellationToken) async throws -> DirectoryListing {
        try await run(endpoint: endpoint, credentials: credentials, cancellation: cancellation) { token in
            try await backend.list(endpoint: endpoint, path: path, encoding: encoding, credentials: credentials, cancellation: token)
        }
    }
    func createDirectory(endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding, credentials: FTPCredentials,
                         cancellation: FTPCancellationToken) async throws {
        try await run(endpoint: endpoint, credentials: credentials, cancellation: cancellation) { token in
            try await backend.createDirectory(endpoint: endpoint, path: path, encoding: encoding, credentials: credentials, cancellation: token)
        }
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
        try await run(endpoint: endpoint, credentials: credentials, cancellation: cancellation) { token in
            try await backend.upload(endpoint: endpoint, path: path, source: source, encoding: encoding, credentials: credentials,
                cancellation: token, progress: progress)
        }
    }
    func download(endpoint: FTPEndpoint, path: RemotePath, credentials: FTPCredentials, cancellation: FTPCancellationToken,
                  receive: @escaping (Data) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws {
        try await run(endpoint: endpoint, credentials: credentials, cancellation: cancellation) { token in
            try await backend.download(endpoint: endpoint, path: path, credentials: credentials, cancellation: token,
                receive: receive, progress: progress)
        }
    }
}
