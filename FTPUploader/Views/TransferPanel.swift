import SwiftUI

@MainActor
struct TransferPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var batch: BatchTransferQueue
    @ObservedObject var history: TransferHistory
    @State private var clearConfirmation = false
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel) { self.model = model; batch = model.batch; history = model.history }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("传输队列与记录").font(.title2)
                Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("最近 100 条终态记录仅保存在本机，包含服务器、路径和结果；不保存密码，重启不恢复任务。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !batch.items.isEmpty {
                        Text("上传队列 · " + queueTitle).font(.headline)
                        ForEach(batch.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("↑ 上传 · " + item.name + " · " + item.state.title)
                                Text(item.target).font(.caption).textSelection(.enabled)
                                Text(ByteCountFormatter.string(fromByteCount: item.snapshot.size, countStyle: .file)).font(.caption)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let error = batch.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    Divider(); Text("最近传输记录").font(.headline)
                    if let error = history.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if history.records.isEmpty { Text("暂无记录").foregroundStyle(.secondary) }
                    ForEach(history.records) { record in
                        DisclosureGroup {
                            Text(record.transport.title + " · " + record.server).textSelection(.enabled)
                            Text(record.target).textSelection(.enabled)
                            Text("\(record.started.formatted()) → \(record.ended.formatted()) · \(ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file))")
                            if let error = record.error { Text(error).textSelection(.enabled) }
                        } label: {
                            Text((record.direction == .upload ? "↑ 上传 · " : "↓ 下载 · ") + record.name + " · " + record.result)
                        }
                    }
                }.padding(4)
            }
            HStack {
                if batch.state == .preview {
                    Button("确认开始批量上传") { batch.startOrContinue() }.keyboardShortcut(.defaultAction)
                }
                if batch.state == .paused {
                    Button("跳过当前项") { batch.skip() }
                    Button("明确重试当前项") { batch.retry() }
                    Button("继续队列") { batch.startOrContinue() }
                }
                if batch.isExecuting { Button("取消当前项") { batch.cancelCurrent() } }
                if batch.isLocked { Button("取消全部") { batch.cancelAll() } }
                Spacer()
                Button("清除记录…") { clearConfirmation = true }.disabled(history.records.isEmpty)
            }.controlSize(.small)
        }
        .padding(16).frame(minWidth: 580, idealWidth: 700, minHeight: 420, idealHeight: 550)
        .alert("仅本次覆盖队列目标？", isPresented: Binding(
            get: { batch.overwriteID != nil }, set: { if !$0 { batch.cancelCurrent() } }
        ), presenting: batch.overwriteID) { id in
            Button("取消当前项", role: .cancel) { batch.cancelCurrent() }.keyboardShortcut(.defaultAction)
            Button("仅本次覆盖") { batch.confirmOverwrite(id) }
        } message: { id in Text(batch.items.first { $0.id == id }?.target ?? "") }
        .alert("清除全部本机传输记录？", isPresented: $clearConfirmation) {
            Button("取消", role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button("清除记录", role: .destructive) { history.clear() }
        } message: { Text("仅清除记录，不删除任何本地或远程文件，不修改站点及保存密码。") }
    }
    private var queueTitle: String {
        switch batch.state { case .preview: return "待核对"; case .running: return "串行执行"; case .paused: return "已暂停"; case .finished: return "已结束" }
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
