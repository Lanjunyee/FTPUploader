import Foundation

/// Shared file-task primitive. Plan dependencies and overwrite UI remain in the coordinator;
/// this layer owns the common executor, fixed job credentials, backend and final confirmation.
@MainActor
final class FileTransferRunner {
    private let client: FTPServing
    private let executor: TransferExecutor
    init(client: FTPServing, executor: TransferExecutor) { self.client = client; self.executor = executor }

    /// Collection file primitive: caller creates the sink only after initial conflict approval.
    /// A cleanup warning never rewrites a committed result or hides the original backend error.
    func runDownload(_ job: TransferJob, sink: LocalDownload,
                     confirmTarget: (URL, LocalDownload.Identity?) async throws -> Bool = { _, _ in false },
                     cleanupFailure: (Error) -> Void = { _ in },
                     progress: @escaping (Int64, Int64) -> Void) async throws -> Int64 {
        guard job.direction == .download, job.localURL.standardizedFileURL == sink.destination.standardizedFileURL,
              executor.activeJob == nil, job.outcome == nil else {
            throw FTPError.localFile("下载接收器与任务不符，或执行器/任务已不可开始。")
        }
        do {
            try await run(job, receive: { try sink.receive($0) }, finalizing: {
                try sink.closeFile()
                while true {
                    try job.cancellation.checkCancellation()
                    do { try sink.commit(); break }
                    catch LocalDownload.CommitError.confirmationRequired {
                        let shown = try sink.currentTargetIdentity()
                        guard try await confirmTarget(sink.destination, shown) else { throw CancellationError() }
                        try job.cancellation.checkCancellation()
                        sink.authorizeTarget(shown)
                    }
                }
            }, progress: progress)
        } catch {
            do { try sink.cleanUp() } catch { cleanupFailure(error) }
            throw error
        }
        job.completedFileBytes = sink.byteCount
        do { try sink.cleanUp() } catch { cleanupFailure(error) }
        return sink.byteCount
    }

    func run(_ job: TransferJob, preparing: () async throws -> Void = {},
             receive: ((Data) throws -> Void)? = nil, finalizing: () async throws -> Void = {},
             progress: @escaping (Int64, Int64) -> Void) async throws {
        let counter = job.byteCounter
        defer { counter.finish() }
        try await executor.execute(job) {
            defer { counter.finish(); job.uploadSource = nil }
            try await preparing()
            try job.cancellation.checkCancellation()
            switch job.direction {
            case .upload:
                guard let source = job.uploadSource,
                      source.url.standardizedFileURL == job.localURL.standardizedFileURL else {
                    throw FTPError.localFile("上传任务缺少与固定来源匹配的已验证句柄。")
                }
                try await client.upload(endpoint: job.endpoint, path: job.path, source: source,
                    encoding: job.encoding, credentials: job.credentials, cancellation: job.cancellation,
                    progress: { bytes, total in counter.sample(bytes); progress(bytes, total) })
                job.completedFileBytes = source.expected.size
                counter.sample(source.expected.size)
            case .download:
                guard let receive else { throw FTPError.localFile("下载任务缺少临时文件接收器。") }
                try await client.download(endpoint: job.endpoint, path: job.path, credentials: job.credentials,
                    cancellation: job.cancellation,
                    receive: { data in counter.receive(data.count); try receive(data) },
                    progress: { bytes, total in counter.sample(bytes); progress(bytes, total) })
            }
            // The backend has stopped; user confirmation/local commit must not extend traffic accounting.
            counter.finish()
            try job.cancellation.checkCancellation()
            try await finalizing()
            // Success is committed only after protocol completion and local finalization.
            try job.cancellation.checkCancellation()
        }
    }
}
