import Foundation

/// Memory-only authorization for the immutable upload plan. Backend primitives remain
/// internal transport APIs; application directory execution must enter through this guard.
@MainActor
final class UploadPlanAuthorization {
    let plan: TransferPlan
    private let endpoint: FTPEndpoint
    private let destination: RemotePath
    private let credentials: FTPCredentials
    private let client: FTPServing
    private var confirmed = false
    private var invalidated = false
    private var active: FTPCancellationToken?
    private(set) var results: [UUID: TransferTaskResult] = [:]
    private(set) var directoryDetails: [UUID: RemoteDirectoryResult] = [:]
    var isExecuting: Bool { active != nil }
    var cancellationID: UUID? { active?.id }

    init(plan: TransferPlan, endpoint: FTPEndpoint, destination: RemotePath,
         credentials: FTPCredentials, client: FTPServing) throws {
        guard plan.direction == .upload, plan.canStart else {
            throw FTPError.localFile("上传计划不完整或存在问题，不能授权。")
        }
        for node in plan.nodes {
            guard case .remote(let target, _) = node.target,
                  target.components.map(\.bytes) == (destination.components + node.relativePath).map(\.bytes) else {
                throw FTPError.localFile("计划目标不在所选远程根范围内。")
            }
        }
        self.plan = plan; self.endpoint = endpoint; self.destination = destination
        self.credentials = credentials; self.client = client
    }

    /// The UI/coordinator must call this only after explicit confirmation of this exact plan.
    @discardableResult
    func confirm(planID: UUID) -> Bool {
        guard planID == plan.id, !confirmed, !invalidated, results.isEmpty else { return false }
        confirmed = true
        return true
    }

    func cancel(id: UUID? = nil) {
        if let id, id != active?.id { return }
        invalidated = true; confirmed = false; active?.cancel()
    }

    func executeDirectory(nodeID: UUID, cancellation: FTPCancellationToken = FTPCancellationToken()) async throws -> RemoteDirectoryResult {
        guard confirmed, !invalidated, active == nil, results[nodeID] == nil,
              let node = plan.nodes.first(where: { $0.id == nodeID }), node.kind == .directory,
              case .remote(let target, let encoding) = node.target else {
            throw FTPError.localFile("目录任务未授权、已结束或不属于确认计划。")
        }
        if let parent = node.parentID {
            guard results[parent] == .succeeded else { throw FTPError.localFile("父目录尚未成功，不能执行子项。") }
        }
        let token = cancellation
        active = token
        defer { active = nil }
        do {
            let detail = try await client.ensureDirectory(endpoint: endpoint, path: target, encoding: encoding,
                                                          credentials: credentials, cancellation: token)
            try token.checkCancellation()
            guard !invalidated else { throw CancellationError() }
            results[nodeID] = .succeeded; directoryDetails[nodeID] = detail
            return detail
        } catch {
            results[nodeID] = token.isCancelled || error is CancellationError ? .cancelled :
                .failed(credentials.redacting(error.localizedDescription))
            throw error
        }
    }
}
