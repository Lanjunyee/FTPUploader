import Foundation

/// Accessed by one backend queue while an operation is active; closed only after return.
final class CurlTransportDriver: @unchecked Sendable {
    private var handle: OpaquePointer?
    private var closed = false
    private let ca: TransportCAFile?
    init(ca: TransportCAFile?) throws {
        self.ca = ca; handle = ftp_session_create()
        guard handle != nil else { throw FTPError.security("无法建立传输会话。") }
    }
    func borrow() throws -> OpaquePointer {
        guard !closed, let handle else { throw FTPError.security("传输会话已关闭，未重新发送请求。") }
        return handle
    }
    /// Only the pre-existing MLSD 500/502/504 -> LIST read-only compatibility branch.
    /// This does not retry MLSD or a content/directory write.
    func replaceForUnsupportedMLSD(cancellation: FTPCancellationToken) throws {
        guard !closed else { throw FTPError.security("传输会话已关闭。") }
        if let handle { ftp_session_destroy(handle) }; handle = nil
        try cancellation.checkCancellation()
        try ca?.validateOnBackendQueue(cancellation: cancellation)
        try cancellation.checkCancellation()
        handle = ftp_session_create()
        guard handle != nil else { throw FTPError.security("无法建立只读 LIST 兼容连接。") }
    }
    func close() {
        guard !closed else { return }
        closed = true
        if let handle { ftp_session_destroy(handle) }; handle = nil
    }
    deinit { if let handle { ftp_session_destroy(handle) } }
}

/// Fixed-context protocol adapter. It does not choose targets or grant overwrite permission.
@MainActor
final class ManagedCurlTransferSession: ManagedTransferServing {
    let lifecycle: TransferTransportSession
    private let backend: FTPClient
    private let executor: TransferExecutor
    private let configuration: TransportConfiguration
    init(endpoint: FTPEndpoint, credentials: FTPCredentials, backend: FTPClient, driver: CurlTransportDriver,
         configuration: TransportConfiguration, executor: TransferExecutor) {
        self.backend = backend; self.executor = executor; self.configuration = configuration
        lifecycle = TransferTransportSession(endpoint: endpoint, credentials: credentials, configuration: configuration,
            executor: executor, closeDriver: { driver.close() })
    }
    func invalidate() { lifecycle.invalidate() }
    private func run<T>(endpoint: FTPEndpoint, credentials: FTPCredentials, cancellation: FTPCancellationToken,
                        operation: (FTPCancellationToken) async throws -> T) async throws -> T {
        try cancellation.checkCancellation()
        guard let job = executor.activeJob, job.cancellation === cancellation else {
            throw FTPError.localFile("会话请求不属于当前固定任务。")
        }
        return try await lifecycle.execute(job: job, endpoint: endpoint, credentials: credentials, configuration: configuration, operation: operation)
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
