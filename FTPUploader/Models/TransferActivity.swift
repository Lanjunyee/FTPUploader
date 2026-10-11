import Combine
import Foundation

/// Read-only display snapshots. No command, credentials, or alternate terminal state.
struct TransferActivity {
    enum Source: Hashable { case upload, download, pending, scan, queue(ObjectIdentifier), notice }
    enum Phase: Equatable {
        case scanning, preview, checking, executing, finalizing, overwrite, cancelling, paused, pending
        case succeeded, failed, cancelled, finished
        var priority: Int {
            switch self {
            case .scanning, .checking, .executing, .finalizing, .overwrite, .cancelling: return 0
            case .preview, .paused: return 1
            case .pending: return 2
            default: return 3
            }
        }
        var title: String {
            switch self {
            case .scanning: return "正在只读扫描"
            case .preview: return "待核对计划"
            case .checking: return "正在检查目标"
            case .executing: return "正在传输"
            case .finalizing: return "等待最终确认／提交"
            case .overwrite: return "等待本次覆盖确认"
            case .cancelling: return "正在取消，等待资源释放"
            case .paused: return "已暂停，等待明确处理"
            case .pending: return "待上传"
            case .succeeded: return "成功"
            case .failed: return "失败"
            case .cancelled: return "已取消"
            case .finished: return "已结束"
            }
        }
    }
    let source: Source
    let direction: TransferDirection?
    let phase: Phase
    let name: String
    let target: String?
    var kind: RemoteEntry.Kind? = nil
    var estimate: TransferMetrics.Estimate? = nil
    var previousTarget: String? = nil
    var warning: String? = nil
    var bytes: Int64 = 0
    var total: Int64? = nil
    var summary: TransferSummary? = nil
    var sessionTraffic: Int64? = nil
    var cancellationID: UUID? = nil
    var ended: Date = .distantPast

    var directionTitle: String { direction == .upload ? "上传" : (direction == .download ? "下载" : "传输") }
    var title: String { directionTitle + " · " + phase.title }
    var targetDiffers: Bool { previousTarget != nil && target != previousTarget }
    /// Content reception is not success. Unknown/zero totals never create percentages.
    var contentFraction: Double? {
        guard kind != .directory, let total, total > 0 else { return nil }
        let fraction = min(max(Double(bytes) / Double(total), 0), 1)
        return phase == .succeeded ? fraction : min(fraction, Double(1).nextDown)
    }
    static func warning(phase: Phase, direction: TransferDirection, error: String? = nil, cleanup: String? = nil) -> String? {
        var text: String?
        switch phase {
        case .finalizing:
            text = direction == .upload ? "等待服务器确认：数据已发送，最终确认前不算成功。" : "等待服务器最终确认及本地安全提交，内容已接收不代表成功。"
        case .overwrite: text = "等待本次普通文件覆盖确认；默认为取消。"
        case .cancelling: text = "正在取消，等待资源释放；尚不可开始新传输。"
        case .cancelled: text = direction == .upload ? "远程可能存在部分或完整文件，请核对目标后再操作。" : "下载已取消，未确认提交不算成功。"
        case .failed:
            text = direction == .upload ? "未能确认上传成功，远程可能存在部分或完整文件，请核对目标。" : "未能确认下载成功，请核对目标。"
            text = (text ?? "") + (error.map { "\n" + $0 } ?? "")
        default: break
        }
        if let cleanup { text = [text, "临时文件清理失败：" + cleanup].compactMap { $0 }.joined(separator: "\n") }
        return text
    }
    static func select(_ candidates: [Self]) -> Self? {
        candidates.enumerated().min { a, b in
            if a.element.phase.priority != b.element.phase.priority { return a.element.phase.priority < b.element.phase.priority }
            if a.element.phase.priority == 3, a.element.ended != b.element.ended { return a.element.ended > b.element.ended }
            return a.offset > b.offset // newest retry outranks an older active/paused queue
        }?.element
    }
}

enum TransferActivityAnnouncement {
    struct Key: Equatable {
        let source: TransferActivity.Source
        let phase: TransferActivity.Phase
        let direction: TransferDirection?
    }
    static func key(for activity: TransferActivity?) -> Key? {
        guard let activity, case .queue = activity.source else { return nil }
        return Key(source: activity.source, phase: activity.phase, direction: activity.direction)
    }
    static func text(for activity: TransferActivity) -> String {
        var text = activity.title + "，" + (activity.kind == .directory ? "文件夹，" : "") + activity.name
        if activity.phase == .finished, let summary = activity.summary {
            text += summary.allSuccessful ? "，全部成功" : "，不是全部成功"
            text += "，成功 \(summary.succeeded)，失败 \(summary.failed)，取消 \(summary.cancelled)，跳过 \(summary.skipped)，阻塞 \(summary.blocked)"
        }
        return text
    }
}

/// Observes every actual queue plus scan and metrics. The computed projection always
/// reads live objects; notifications invalidate presentation, never set business state.
@MainActor
final class TransferActivityObserver: ObservableObject {
    let model: AppModel
    private var subscriptions: [AnyCancellable] = []
    private var queueSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    init(model: AppModel) {
        self.model = model
        subscriptions = [model.objectWillChange, model.collectionScan.objectWillChange,
                         model.metrics.objectWillChange, model.history.objectWillChange].map { publisher in
            publisher.sink { [weak self] in self?.objectWillChange.send() }
        }
        subscriptions.append(model.$retryBatch.sink { [weak self] queue in
            self?.synchronizeQueues(extra: queue)
            // This callback precedes retryBatches append; observe the published queue directly.
        })
        synchronizeQueues()
    }
    private func synchronizeQueues(extra: BatchTransferQueue? = nil) {
        let queues = model.sessionQueues + (extra.map { [$0] } ?? [])
        let ids = Set(queues.map(\.id))
        queueSubscriptions = queueSubscriptions.filter { ids.contains($0.key) }
        queues.forEach(observe)
    }
    func observe(_ queue: BatchTransferQueue) {
        guard queueSubscriptions[queue.id] == nil else { return }
        queueSubscriptions[queue.id] = queue.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
    var activity: TransferActivity? {
        var candidates: [TransferActivity] = []
        if let value = single(state: model.uploadState, direction: .upload, name: model.selectedFile?.name ?? "单文件", target: model.uploadTarget, bytes: model.sent, total: model.total) { candidates.append(value) }
        if let value = single(state: model.downloadState, direction: .download, name: model.downloadName ?? "单文件", target: model.downloadTarget, bytes: model.downloadBytes, total: model.downloadTotal) { candidates.append(value) }
        for queue in model.sessionQueues where !queue.items.isEmpty || queue.state == .scanning {
            candidates.append(queueActivity(queue))
        }
        if model.collectionScan.isLocked {
            let phase: TransferActivity.Phase = model.collectionScan.phase == .cancelling ? .cancelling : (model.collectionScan.phase == .preview ? .preview : .scanning)
            candidates.append(.init(source: .scan, direction: model.collectionDirection, phase: phase,
                name: "传输计划", target: model.collectionTarget,
                cancellationID: model.collectionScan.cancellationID))
        }
        if let file = model.selectedFile, !model.isUploading, model.uploadState != .awaitingOverwrite,
           model.uploadState == .idle || model.pendingTarget != model.uploadTarget {
            let prior = model.history.records.first { $0.direction == .upload && $0.batchID == nil }?.target
            candidates.append(.init(source: .pending, direction: .upload, phase: .pending, name: file.name,
                target: model.pendingTarget, kind: .regularFile, previousTarget: prior, total: file.size))
        }
        if let error = model.selectionError ?? model.collectionScan.error {
            candidates.append(.init(source: .notice, direction: nil, phase: .failed, name: "来源选择", target: nil, warning: error, ended: .distantFuture))
        }
        var result = TransferActivity.select(candidates)
        if let error = model.selectionError ?? model.collectionScan.error, result?.source != .notice {
            let warning = [error, result?.warning].compactMap { $0 }.joined(separator: "\n")
            result?.warning = warning
        }
        if let cleanup = model.downloadCleanupError, result?.source != .download {
            let warning = [result?.warning, "临时文件清理失败：" + cleanup].compactMap { $0 }.joined(separator: "\n")
            result?.warning = warning
        }
        return result
    }
    private func single(state: UploadState, direction: TransferDirection, name: String, target: String?, bytes: Int64, total: Int64) -> TransferActivity? {
        let phase: TransferActivity.Phase
        var error: String?
        switch state {
        case .idle: return nil
        case .checkingTarget: phase = .checking
        case .uploading: phase = .executing
        case .awaitingCompletion: phase = .finalizing
        case .awaitingOverwrite: phase = .overwrite
        case .cancelling: phase = .cancelling
        case .cancelled: phase = .cancelled
        case .succeeded: phase = .succeeded
        case .failed(let message): phase = .failed; error = message
        }
        let warning = TransferActivity.warning(phase: phase, direction: direction, error: error,
            cleanup: direction == .download ? model.downloadCleanupError : nil)
        let date = model.history.records.first { $0.direction == direction && $0.batchID == nil && $0.target == target }?.ended ?? .distantPast
        return .init(source: direction == .upload ? .upload : .download, direction: direction, phase: phase,
            name: name, target: target, kind: .regularFile,
            estimate: phase == .executing ? model.metrics.estimate : nil,
            warning: warning, bytes: bytes, total: total >= 0 ? total : nil,
            cancellationID: phase.priority == 0 ? model.cancellationID : nil, ended: date)
    }
    private func queueActivity(_ queue: BatchTransferQueue) -> TransferActivity {
        let phase: TransferActivity.Phase
        switch queue.state {
        case .scanning: phase = .scanning
        case .preview: phase = .preview
        case .running:
            if queue.items.contains(where: { $0.state == .awaitingOverwrite }) { phase = .overwrite }
            else if queue.items.contains(where: { $0.state == .awaitingCompletion }) { phase = .finalizing }
            else { phase = .executing }
        case .paused: phase = .paused
        case .cancelling: phase = .cancelling
        case .finished: phase = queue.isLocked ? .cancelling : .finished
        }
        let item = queue.items.first { [.running, .awaitingCompletion, .awaitingOverwrite].contains($0.state) }
            ?? queue.items.first { if case .failed = $0.state { return true }; return false }
            ?? queue.items.first { $0.state == .waiting } ?? queue.items.last
        let summary = queue.summary ?? TransferSummary(entries: queue.items.map { item in
            .init(id: item.id, target: item.target, kind: item.kind == .directory ? .directory : .file,
                  direction: item.direction, result: item.state.terminalResult, size: item.snapshot?.size ?? item.sizeHint,
                  successfulBytes: item.successfulBytes, actualBytes: item.actualBytes, trafficOverflow: item.trafficOverflow)
        }, isFinished: queue.state == .finished && !queue.isLocked)
        var warning = queue.error
        if phase == .paused { warning = "批次已暂停，需明确继续、跳过或取消；不是停止按钮创建的暂停。" + (warning.map { "\n" + $0 } ?? "") }
        if phase == .cancelling { warning = "正在取消，等待后端与资源释放；锁定仍有效。" }
        if phase == .overwrite { warning = "等待本次普通文件覆盖确认，默认取消。" }
        if phase == .finalizing { warning = "等待服务器最终确认及下载安全提交，内容字节不代表成功。" }
        if summary.isFinished && !summary.allSuccessful { warning = "已结束，不是全部成功。成功 \(summary.succeeded)，失败 \(summary.failed)，取消 \(summary.cancelled)，跳过 \(summary.skipped)，阻塞 \(summary.blocked)。" + (warning.map { "\n" + $0 } ?? "") }
        let ids = Set(queue.items.map(\.id))
        let date = model.history.records.first { ids.contains($0.id) || (queue.collectionPlanID != nil && $0.batchID == queue.collectionPlanID) }?.ended
            ?? queue.items.compactMap(\.started).max() ?? .distantPast
        return .init(source: .queue(queue.id), direction: item?.direction ?? .upload, phase: phase,
            name: item?.name ?? "传输队列", target: item?.target, kind: item?.kind,
            estimate: phase == .executing && item?.kind == .regularFile ? model.metrics.estimate : nil,
            warning: warning, bytes: item?.bytes ?? 0,
            total: item?.snapshot?.size ?? item?.sizeHint, summary: summary, sessionTraffic: model.sessionSummary?.actualBytes,
            cancellationID: queue.cancellationID, ended: date)
    }
}
