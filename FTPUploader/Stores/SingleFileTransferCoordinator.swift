import Foundation

/// One single-file attempt at a time, using AppModel's shared executor.
/// Owns backend sessions and one-shot decisions, not view/form state.
@MainActor
final class SingleFileTransferCoordinator {
    struct UploadSnapshot {
        let id = UUID()
        let version: Int
        let endpoint: FTPEndpoint
        let path: RemotePath
        let credentials: FTPCredentials
        let encoding: FTPTextEncoding
        let file: SelectedLocalFile
        let local: SelectedLocalFile.Snapshot

        func matches(version: Int, endpoint: FTPEndpoint?, path: RemotePath,
                     encoding: FTPTextEncoding, file: SelectedLocalFile?, credentials: FTPCredentials?) -> Bool {
            guard self.version == version, self.endpoint == endpoint, self.path == path,
                  self.encoding == encoding, self.file === file, let credentials else { return false }
            return self.credentials.sameAuthentication(as: credentials)
        }
    }
    private struct DownloadDecision {
        let id: UUID
        let job: TransferJob
        let target: URL
        let identity: LocalDownload.Identity?
        let continuation: CheckedContinuation<Bool, Error>
    }
    private let client: FTPServing
    private let executor: TransferExecutor
    var uploadGeneration = 0
    var uploadCancellation: FTPCancellationToken?
    var downloadCancellation: FTPCancellationToken?
    private(set) var uploadConnection: TransferConnectionOwner?
    private(set) var downloadConnection: TransferConnectionOwner?
    var pendingOverwrite: UploadSnapshot?
    var pendingUploadJob: TransferJob?
    private var pendingDownload: DownloadDecision?

    init(client: FTPServing, executor: TransferExecutor) {
        self.client = client; self.executor = executor
    }

    func uploadSession(endpoint: FTPEndpoint, credentials: FTPCredentials, continuing: Bool) -> TransferConnectionOwner {
        if continuing, let uploadConnection { return uploadConnection }
        uploadConnection?.close()
        let connection = TransferConnectionOwner(base: client, endpoint: endpoint, credentials: credentials, executor: executor)
        uploadConnection = connection
        return connection
    }
    func downloadSession(endpoint: FTPEndpoint, credentials: FTPCredentials) -> TransferConnectionOwner {
        let connection = TransferConnectionOwner(base: client, endpoint: endpoint, credentials: credentials, executor: executor)
        downloadConnection = connection
        return connection
    }
    func closeUpload(_ connection: TransferConnectionOwner? = nil) {
        guard connection == nil || uploadConnection === connection else { return }
        uploadConnection?.close(); uploadConnection = nil
    }
    func closeDownload(_ connection: TransferConnectionOwner) {
        connection.close()
        if downloadConnection === connection { downloadConnection = nil }
    }

    func clearOverwrite(preserveJob: Bool, history: TransferHistory, target: String) {
        if !preserveJob, let job = pendingUploadJob {
            closeUpload()
            job.finish(.cancelled)
            history.record(job, target: target, bytes: 0)
        }
        pendingUploadJob = nil; pendingOverwrite = nil
    }

    func waitForDownloadDecision(id: UUID, job: TransferJob, target: URL,
                                 identity: LocalDownload.Identity?, continuation: CheckedContinuation<Bool, Error>) {
        precondition(pendingDownload == nil)
        pendingDownload = DownloadDecision(id: id, job: job, target: target, identity: identity, continuation: continuation)
    }
    @discardableResult
    func confirmDownload(_ id: UUID) -> Bool {
        guard let decision = pendingDownload, decision.id == id,
              downloadCancellation === decision.job.cancellation,
              !decision.job.cancellation.isCancelled, decision.job.outcome == nil else { return false }
        downloadConnection?.resume()
        pendingDownload = nil
        // Only resolve the captured decision. The shared runner checks its captured identity.
        decision.continuation.resume(returning: true)
        return true
    }
    @discardableResult
    func cancelDownloadDecision(_ id: UUID?) -> Bool {
        guard let decision = pendingDownload, id == nil || id == decision.id,
              downloadCancellation === decision.job.cancellation else { return false }
        decision.job.cancellation.cancel(); downloadConnection?.close()
        pendingDownload = nil
        decision.continuation.resume(throwing: CancellationError())
        return true
    }
}
