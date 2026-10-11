import AppKit
import SwiftUI

@MainActor
struct TransferActivityBar: View {
    @ObservedObject var model: AppModel
    @StateObject private var observer: TransferActivityObserver
    @EnvironmentObject private var bus: TransferCommandBus
    @State private var detail: Detail?
    @State private var lastAnnouncement: TransferActivityAnnouncement.Key?
    let announcementsEnabled: Bool
    private struct Detail: Identifiable {
        let id: TransferActivity.Source
        let target: String?
        let previousTarget: String?
        let title: String
        let text: String
    }
    init(model: AppModel, announcementsEnabled: Bool = true) {
        self.model = model
        self.announcementsEnabled = announcementsEnabled
        _observer = StateObject(wrappedValue: TransferActivityObserver(model: model))
    }
    var body: some View {
        if let activity = observer.activity {
            Divider()
            TransferActivitySummary(activity: activity) {
                WorkbenchIconMenu(title: "传输详情", symbol: "info.circle", help: "核对完整名称、目标及统计", enabled: true) {
                    ForEach(TransferActivityLayout.targets(for: activity), id: \.title) { target in
                        Button(target.title + "…") {
                            detail = Detail(id: activity.source, target: activity.target, previousTarget: activity.previousTarget,
                                title: target.title, text: TransferActivityLayout.details(for: activity, target: target))
                        }
                    }
                    if activity.target == nil {
                        Button("完整传输信息…") {
                            detail = Detail(id: activity.source, target: nil, previousTarget: activity.previousTarget,
                                title: "传输信息", text: activity.warning ?? activity.title)
                        }
                    }
                    Button("队列与记录…") { bus.send(.showTransfers) }
                }
                WorkbenchIconButton(title: "选择文件", symbol: "doc.badge.plus", help: "选择单个文件，不开始上传", enabled: model.canChooseFile) { bus.send(.chooseFile) }
                if activity.source == .pending {
                    Button { model.upload() } label: {
                        Text("开始上传").font(.callout)
                            .foregroundStyle(Color(nsColor: WorkbenchAccentContrast.foreground))
                    }
                    .buttonStyle(.borderedProminent).disabled(!model.canUpload)
                }
                if activity.phase.priority < 2 {
                    WorkbenchIconButton(title: "取消当前", symbol: "stop.circle", help: "请求取消当前项，等待资源释放", enabled: model.canCancel && activity.cancellationID != nil && activity.phase != .cancelling) {
                        if let id = activity.cancellationID { model.cancelOperation(id: id) }
                    }
                    if model.canCancelAllTransfers {
                        Button("取消全部") {
                            guard observer.activity?.source == activity.source,
                                  activity.cancellationID == model.cancellationID else { return }
                            model.cancelAllTransfers(id: activity.cancellationID)
                        }.disabled(activity.phase == .cancelling)
                    }
                }
                WorkbenchIconButton(title: "队列与记录", symbol: "list.bullet.rectangle", help: "查看完整队列和结果，不取消任务", enabled: true) { bus.send(.showTransfers) }
            }
            .popover(item: $detail) { item in
                TextDetailsPopover(title: item.title, text: item.text) { detail = nil }
            }
            .onChange(of: observer.activity?.source) { _ in detail = nil }
            .onChange(of: observer.activity?.target) { _ in detail = nil }
            .onChange(of: observer.activity?.previousTarget) { _ in detail = nil }
            .onChange(of: observer.activity?.phase) { _ in detail = nil }
            .onChange(of: observer.activity?.warning) { _ in detail = nil }
            .onChange(of: model.selectedFile.map { ObjectIdentifier($0) }) { _ in detail = nil }
            .onAppear { announce() }
            .onChange(of: TransferActivityAnnouncement.key(for: observer.activity)) { _ in announce() }
            .onChange(of: announcementsEnabled) { enabled in if enabled { announce() } }
        }
    }
    private func announce() {
        guard announcementsEnabled else { return }
        let key = TransferActivityAnnouncement.key(for: observer.activity)
        guard key != lastAnnouncement else { return }
        lastAnnouncement = key
        guard key != nil, let activity = observer.activity else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: TransferActivityAnnouncement.text(for: activity),
                       .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

/// The same summary surface is hosted in tests; controls remain in its trailing slot.
@MainActor
struct TransferActivitySummary<Controls: View>: View {
    let activity: TransferActivity
    @ViewBuilder let controls: () -> Controls
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            HStack(spacing: Metrics.spacing8) {
                Image(systemName: activity.direction == .download ? "arrow.down.circle" : "arrow.up.circle")
                    .foregroundStyle(Color.accentColor).accessibilityHidden(true)
                Text(activity.title).font(.callout).lineLimit(1).layoutPriority(1)
                Text((activity.kind == .directory ? "文件夹 · " : "") + activity.name)
                    .font(.callout).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if activity.phase == .executing || activity.phase == .finalizing {
                    if let fraction = activity.contentFraction {
                        ProgressView(value: fraction).frame(width: 56)
                            .accessibilityLabel(activity.directionTitle + "内容进度，不代表最终成功")
                    } else if activity.kind != .directory {
                        Text("已传 " + TransferActivityLayout.bytes(activity.bytes)).font(.callout)
                            .accessibilityLabel("已传内容，总大小未知")
                    }
                }
                controls().controlSize(.small)
            }
            if activity.targetDiffers { Text("待上传目标与上次结果不同，请分别核对。") .font(.callout) }
            if let warning = activity.warning {
                ScrollView {
                    Text(warning).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 88).accessibilityLabel("传输告警")
            }
        }
        .padding(Metrics.spacing12).background(.bar)
        .accessibilityElement(children: .contain).accessibilityLabel("双向传输摘要")
    }
}
