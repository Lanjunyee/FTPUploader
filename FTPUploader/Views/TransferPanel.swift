import AppKit
import SwiftUI

@MainActor
struct TransferPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var history: TransferHistory
    @State private var clearConfirmation = false
    @FocusState private var listFocused: Bool
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel) { self.model = model; history = model.history }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("传输队列与记录").font(.title2)
                Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("最近 100 条终态记录仅保存在本机，包含服务器、路径和结果；不保存密码，重启不恢复任务。完整会话结果不受历史上限影响。正常退出等待已接收记录保存；强制终止可能丢失待保存记录。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            KeyboardPlanScrollView(active: listFocused, onCancel: { dismiss() }, accessibilityName: "完整传输队列与结果清单") {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let session = model.sessionSummary {
                        TransferSummaryView(summary: session.original, title: "原计划")
                        Text("累计实际传输（含重试）：" + bytes(session.actualBytes)).font(.caption)
                        Text("重试不改写原计划结果或成功字节；各次重试结果在下方单独列出。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(model.sessionQueues.enumerated()), id: \.element.id) { index, queue in
                        if !queue.items.isEmpty {
                            TransferQueueSection(model: model, queue: queue, label: index == 0 ? "原队列" : "重试 \(index)")
                        }
                    }
                    Divider(); Text("最近传输记录").font(.headline)
                    Text(history.persistenceStatus).font(.caption).foregroundStyle(.secondary)
                    if history.canRetrySave {
                        Button(history.hasPendingClear ? "重试本机清除／保存" : "重试本机保存") { history.retrySave() }
                    }
                    if let error = history.error { PlanPathText(text: error).foregroundStyle(.red) }
                    if history.records.isEmpty { Text("暂无记录").foregroundStyle(.secondary) }
                    ForEach(history.records) { record in
                        DisclosureGroup {
                            PlanPathText(text: record.transport.title + " · " + record.server)
                            PlanPathText(text: record.target)
                            Text("\(record.started.formatted()) → \(record.ended.formatted()) · \(record.trafficOverflow == true ? "实际字节未知（计数溢出）" : ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file))")
                            if let error = record.error { PlanPathText(text: error) }
                            if let reason = record.blockedReason { Text("依赖原因：" + reason.title) }
                        } label: {
                            Text((record.direction == .upload ? "↑ 上传 · " : "↓ 下载 · ") +
                                 (record.taskKind == .directory ? "目录 · " : "文件 · ") + record.name + " · " + record.result)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.padding(8)
            }.focused($listFocused).frame(minHeight: 100, maxHeight: .infinity)
            HStack {
                Button("取消全部") { model.cancelAllTransfers() }.disabled(!model.canCancelAllTransfers)
                Spacer()
                Button("清除记录…") { clearConfirmation = true }.disabled(!history.canClear)
            }.controlSize(.small)
        }
        .padding(16).frame(minWidth: 580, idealWidth: 700, minHeight: 420, idealHeight: 550)
        .modifier(BatchOverwriteDialog(model: model))
        .alert("清除全部本机传输记录？", isPresented: $clearConfirmation) {
            Button("取消", role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button("清除记录", role: .destructive) { history.clear() }
        } message: { Text("仅清除记录，不删除任何本地或远程文件，不修改站点及保存密码。") }
    }
    private func bytes(_ value: Int64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "未知"
    }
}

@MainActor
struct BatchOverwriteDialog: ViewModifier {
    @ObservedObject var model: AppModel
    var enabled = true
    func body(content: Content) -> some View {
        let prompt = model.batchOverwritePrompt
        let presented = Binding(get: { enabled && model.batchOverwritePrompt != nil }, set: { value in
            if !value, let prompt { prompt.queue.cancelOverwrite(prompt.id) }
        })
        content.alert("覆盖此普通文件目标？", isPresented: presented, presenting: prompt) { prompt in
            Button("取消当前项", role: .cancel) { prompt.queue.cancelOverwrite(prompt.id) }.keyboardShortcut(.defaultAction)
            Button("跳过此文件") { prompt.queue.skipOverwrite(prompt.id) }
            Button("仅本次覆盖") { prompt.queue.confirmOverwrite(prompt.id) }
        } message: { prompt in
            Text(prompt.target + "\n仅授权本次核对的目标；检测到下载目标变化仍须独立确认。")
        }
    }
}

@MainActor
private struct TransferQueueSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var queue: BatchTransferQueue
    let label: String
    private var direction: String { queue.items.first?.direction == .download ? "下载队列" : "上传队列" }
    var body: some View {
        Group {
            Text(label + " · " + direction + " · " + phaseTitle).font(.headline)
            if label != "原队列", let summary = queue.summary { TransferSummaryView(summary: summary, title: label) }
            ForEach(queue.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    PlanPathText(text: item.directionTitle + " · " + item.kindTitle + " · " + item.name + " · " + item.statusTitle)
                    PlanPathText(text: "目标：" + item.target).font(.caption)
                    Text(item.sizeDescription).font(.caption)
                    if let dependency = queue.dependencyDescription(for: item) {
                        PlanPathText(text: dependency).font(.caption).foregroundStyle(.secondary)
                    }
                    if item.kind == .regularFile {
                        Text("本项实际流量：" + bytes(item.trafficOverflow ? nil : item.actualBytes) + " · 已传：" + bytes(item.bytes)).font(.caption)
                        if let total = item.snapshot?.size ?? item.sizeHint, total > 0,
                           item.state == .running || item.state == .awaitingCompletion {
                            ProgressView(value: Double(min(item.bytes, total)), total: Double(total))
                                .accessibilityLabel("当前文件内容进度，仍须等待最终确认和下载提交")
                        }
                    }
                    if case .failed = item.state, queue.collectionPlanID != nil {
                        Button("重试失败项…") { _ = model.prepareCollectionRetry(itemID: item.id) }
                            .disabled(!model.canPrepareCollectionRetry(itemID: item.id))
                            .accessibilityLabel("重新核对并预览失败项 " + item.name)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).id(item.id)
                Divider()
            }
            if let error = queue.error { PlanPathText(text: "批次提示：" + error).foregroundStyle(.red) }
            HStack {
                if queue.state == .preview, queue.collectionPlanID == nil {
                    Button("确认开始本队列") { model.continueQueue(queue) }.disabled(!model.canContinueQueue(queue))
                }
                if queue.state == .paused {
                    Button("跳过当前项") { model.skipQueue(queue) }.disabled(!model.canSkipQueue(queue))
                    Button("继续队列") { model.continueQueue(queue) }.disabled(!model.canContinueQueue(queue))
                }
                if queue.isExecuting {
                    let cancellationID = queue.cancellationID
                    Button("取消当前项") { if let cancellationID { model.cancelOperation(id: cancellationID) } }
                        .disabled(queue.state == .cancelling)
                }
                if queue.state == .finished, let planID = queue.collectionPlanID {
                    Button("重试本批失败项…") { _ = model.prepareCollectionRetry(batchID: planID) }
                        .disabled(!model.canPrepareCollectionRetry(batchID: planID))
                }
            }.controlSize(.small)
        }
        .onAppear { announce() }
        .onChange(of: phaseTitle) { _ in announce() }
    }
    private var phaseTitle: String { queue.displayPhaseTitle }
    private func announce() {
        var text = label + "，" + direction + "，" + phaseTitle
        if queue.state == .finished, let summary = queue.summary {
            text += "，成功 \(summary.succeeded)，失败 \(summary.failed)，取消 \(summary.cancelled)，跳过 \(summary.skipped)，阻塞 \(summary.blocked)"
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    private func bytes(_ value: Int64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "未知"
    }
}

private struct TransferSummaryView: View {
    let summary: TransferSummary
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title + (summary.allSuccessful ? "全部成功" : (summary.isFinished ? "已结束 · 非全部成功" : "进度"))).font(.headline)
            Text("文件 \(summary.completedFiles)/\(summary.fileCount) · 目录 \(summary.completedDirectories)/\(summary.directoryCount) 已结束")
            Text("成功 \(summary.succeeded) · 失败 \(summary.failed) · 取消 \(summary.cancelled) · 跳过 \(summary.skipped) · 阻塞 \(summary.blocked)")
            Text("计划大小：" + bytes(summary.totalSize) + " · 成功字节：" + bytes(summary.successfulBytes))
            Text("实际流量：" + bytes(summary.actualBytes))
            if let fraction = summary.byteSuccessFraction {
                ProgressView(value: fraction).accessibilityLabel(title + "成功字节进度")
            } else {
                ProgressView(value: summary.successFraction).accessibilityLabel(title + "成功项进度")
                if summary.totalSize == nil { Text("总大小未知，不估算总体字节百分比或剩余时间。").font(.caption) }
            }
        }.accessibilityElement(children: .combine)
    }
    private func bytes(_ value: Int64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "未知"
    }
}

@MainActor
struct MetricsView: View {
    @ObservedObject var monitor: TransferMetricsMonitor
    var body: some View {
        let estimate = monitor.estimate
        HStack(spacing: 12) {
            Text(estimate.speed.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) + "/秒" } ?? "速度：估算中")
            Text(estimate.remaining.map { "估算剩余 \(Int(ceil($0))) 秒" } ?? "剩余时间：估算中")
        }.font(.caption).foregroundStyle(.secondary).accessibilityElement(children: .combine)
    }
}
