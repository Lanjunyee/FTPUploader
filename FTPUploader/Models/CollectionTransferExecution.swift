import Foundation
import Darwin

/// Memory-only execution context for a fixed plan; never a persisted/resumable queue.
@MainActor
final class CollectionTransferExecution {
    let plan: TransferPlan
    private let endpoint: FTPEndpoint
    private let credentials: FTPCredentials
    private let client: FTPServing
    private let files: FileTransferRunner
    private let executor: TransferExecutor
    private let sources: [UUID: LocalSourceRoot]
    private let destination: LocalDestinationRoot?
    private let local: LocalDestinationService?
    private let upload: UploadPlanAuthorization?
    private var confirmed = false
    private var policy = TransferConflictPolicy.ask

    init(plan: TransferPlan, endpoint: FTPEndpoint, remoteRoot: RemotePath, credentials: FTPCredentials,
         client: FTPServing, executor: TransferExecutor, sources: [UUID: LocalSourceRoot],
         destination: LocalDestinationRoot?) throws {
        guard plan.canStart else { throw FTPError.localFile("集合计划存在问题或不完整。") }
        self.plan = plan; self.endpoint = endpoint; self.credentials = credentials; self.client = client
        self.executor = executor; files = FileTransferRunner(client: client, executor: executor)
        self.sources = sources; self.destination = destination
        switch plan.direction {
        case .upload:
            guard destination == nil, sources.count == plan.roots.count else { throw FTPError.localFile("来源授权与计划不符。") }
            for root in plan.roots {
                guard let access = sources[root.id], root.source == .local(access.url), root.kind == access.identity.kind else {
                    throw FTPError.localFile("所选来源根与计划不符。")
                }
                try access.validateIdentity()
            }
            for node in plan.nodes {
                guard let root = sources[node.rootID],
                      node.source == .local(node.relativePath.dropFirst().reduce(root.url) { $0.appendingPathComponent($1.name) }) else {
                    throw FTPError.localFile("计划来源越出所选根。")
                }
            }
            upload = try UploadPlanAuthorization(plan: plan, endpoint: endpoint, destination: remoteRoot,
                                                  credentials: credentials, client: client)
            local = nil
        case .download:
            guard sources.isEmpty, let destination else { throw FTPError.localFile("下载缺少所选目的根授权。") }
            for node in plan.nodes {
                let target = node.relativePath.reduce(destination.url) { $0.appendingPathComponent($1.name) }
                guard node.target == .local(target),
                      let root = plan.roots.first(where: { $0.id == node.rootID }),
                      case .remote(let rootPath, _) = root.source,
                      case .remote(let sourcePath, _) = node.source,
                      sourcePath.components.map(\.bytes) == (rootPath.components + node.relativePath.dropFirst()).map(\.bytes) else {
                    throw FTPError.localFile("下载来源或目标与固定计划不符。")
                }
                try node.relativePath.forEach { try LocalDestinationService.validateName($0.name) }
            }
            local = try LocalDestinationService(root: destination); upload = nil
        }
    }

    func confirm(policy: TransferConflictPolicy = .ask) -> Bool {
        guard !confirmed else { return true }
        guard upload?.confirm(planID: plan.id) ?? true else { return false }
        self.policy = policy; confirmed = true; return true
    }
    func invalidate() { upload?.cancel() }
    func release() {
        sources.values.forEach { $0.endAccess() }; destination?.endAccess()
    }
    private func directories(rootID: UUID) -> [[String]: (UInt64, UInt64)] {
        var values: [[String]: (UInt64, UInt64)] = [:]
        for node in plan.nodes where node.rootID == rootID {
            if case .localDirectory(let device, let inode) = node.snapshot {
                values[node.relativePath.dropFirst().map(\.name)] = (device, inode)
            }
        }
        return values
    }
    func job(for node: TransferPlan.Node) throws -> TransferJob {
        let remote: RemotePath, encoding: FTPTextEncoding, url: URL
        switch (plan.direction, node.source, node.target) {
        case (.upload, .local(let source), .remote(let target, let selectedEncoding)):
            guard let parent = target.parent, let last = target.components.last,
                  try selectedEncoding.encode(source.lastPathComponent) == last.bytes else { throw FTPError.invalidName }
            remote = node.kind == .directory ? target : parent; encoding = selectedEncoding; url = source
        case (.download, .remote(let source, let selectedEncoding), .local(let target)):
            remote = source; encoding = selectedEncoding; url = target
        default: throw FTPError.localFile("任务方向与计划不符。")
        }
        return TransferJob(direction: plan.direction, endpoint: endpoint, path: remote, encoding: encoding,
                           credentials: credentials, localURL: url, name: node.relativePath.last?.name)
    }
    private func verifyRemote(_ node: TransferPlan.Node, job: TransferJob) async throws {
        guard case .remote(let path, let encoding) = node.source, let parent = path.parent,
              let name = path.components.last else { throw FTPError.invalidName }
        let listing = try await client.list(endpoint: endpoint, path: parent, encoding: encoding,
                                             credentials: credentials, cancellation: job.cancellation)
        try job.cancellation.checkCancellation()
        guard listing.entries.first(where: { $0.rawName == name.bytes })?.kind == node.kind else {
            throw FTPError.localFile("远程来源消失或类型发生变化。")
        }
    }

    private func decideExisting(_ decide: () async throws -> Void) async throws {
        switch policy {
        case .ask: try await decide()
        case .skipExistingFiles: throw TransferSkipped.requested
        case .overwriteExistingFiles: break
        }
    }

    /// Returns whether a directory was reused; files return false and report bytes separately.
    func execute(_ node: TransferPlan.Node, job: TransferJob, decide: () async throws -> Void,
                 cleanupFailure: (Error) -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> Bool {
        guard confirmed, plan.nodes.contains(node) else { throw FTPError.localFile("节点不属于确认计划。") }
        if node.kind == .directory {
            var reused = false
            try await executor.execute(job) {
                if plan.direction == .upload {
                    guard let root = sources[node.rootID], let upload else { throw FTPError.localFile("来源根授权不可用。") }
                    let fd = try SelectedLocalFile.openSource(root: root, path: node.relativePath.dropFirst().map(\.name),
                                                             directories: directories(rootID: node.rootID), directory: true)
                    Darwin.close(fd)
                    reused = try await upload.executeDirectory(nodeID: node.id, cancellation: job.cancellation) != .created
                } else {
                    try await verifyRemote(node, job: job)
                    try job.cancellation.checkCancellation()
                    guard let local else { throw FTPError.localFile("目的根授权不可用。") }
                    reused = try local.createDirectory(node.relativePath.map(\.name)) == .reused
                }
            }
            return reused
        }
        guard node.kind == .regularFile else { throw FTPError.localFile("不能执行非普通文件。") }
        if plan.direction == .upload {
            try await files.run(job, preparing: {
                guard let root = sources[node.rootID], case .localFile(let expected) = node.snapshot else {
                    throw FTPError.localFile("来源快照不符。")
                }
                if let existing = try await client.checkUploadTarget(endpoint: endpoint, path: job.path, name: job.name,
                    encoding: job.encoding, credentials: credentials, cancellation: job.cancellation) {
                    guard existing.kind == .regularFile else { throw FTPError.uploadTargetConflict }
                    try await decideExisting(decide)
                }
                try job.cancellation.checkCancellation()
                job.uploadSource = try await SelectedLocalFile.verifiedSource(root: root,
                    path: node.relativePath.dropFirst().map(\.name), directories: directories(rootID: node.rootID),
                    matching: expected, cancellation: job.cancellation)
            }, progress: progress)
        } else {
            guard let local else { throw FTPError.localFile("目的根授权不可用。") }
            try await verifyRemote(node, job: job)
            let path = node.relativePath.map(\.name)
            let sink: LocalDownload
            var targetChanged = false
            while true {
                try job.cancellation.checkCancellation()
                let identity = try local.fileIdentity(path)
                if targetChanged { try await decide() }
                else if identity != nil { try await decideExisting(decide) }
                try job.cancellation.checkCancellation()
                do { sink = try local.download(path, authorizedIdentity: identity); break }
                catch LocalDownload.CommitError.confirmationRequired { targetChanged = true; continue }
            }
            _ = try await files.runDownload(job, sink: sink, confirmTarget: { _, _ in
                try await decide(); return true
            }, cleanupFailure: cleanupFailure, progress: progress)
        }
        return false
    }
}
