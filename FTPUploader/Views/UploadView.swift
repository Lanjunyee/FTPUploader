import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The bottom upload bar. Row count is decided by `UploadBarLayout`:
/// file slot always, the target row once a file is chosen, and the status row only
/// while transferring, after finishing, or after a selection failure. The file slot
/// and its two actions never move between states.
///
/// Key equivalents live in the 传输 menu, so the buttons here keep help text only.
@MainActor
struct UploadView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var bus: TransferCommandBus
    @State private var showFilePicker = false
    @State private var detail: DetailItem?

    private struct DetailItem: Identifiable {
        let id: String
        let title: String
        let text: String
    }

    private var isIdle: Bool { model.uploadState == .idle }

    private var rows: UploadBarLayout.Rows {
        UploadBarLayout.rows(isConnected: model.hasDirectory,
                             hasSelectedFile: model.selectedFile != nil,
                             isIdle: isIdle,
                             hasSelectionError: model.selectionError != nil)
    }

    var body: some View {
        if rows.isVisible {
            bar
                .fileImporter(isPresented: $showFilePicker,
                              allowedContentTypes: [.data],
                              allowsMultipleSelection: false) { result in
                    switch result {
                    case .success(let urls):
                        if urls.count == 1 { model.selectFile(urls[0]) }
                    case .failure(let error): model.fileSelectionFailed(error)
                    }
                }
                .onChange(of: model.pendingTarget) { _ in detail = nil }
                .onChange(of: model.selectedFile?.name) { _ in detail = nil }
                .onChange(of: model.uploadState) { _ in detail = nil }
                .onChange(of: model.selectionError) { _ in detail = nil }
                .onChange(of: bus.request) { request in handle(request) }
        }
    }

    private func handle(_ request: TransferCommandBus.Request?) {
        switch request {
        case .chooseFile:
            showFilePicker = true
        case .showSelectedFileName:
            if let file = model.selectedFile {
                detail = DetailItem(id: "file", title: "所选文件", text: file.name)
            }
        case .showTarget:
            if let target = activeTarget {
                detail = DetailItem(id: "target", title: "完整上传目标", text: target)
            }
        case .showResult:
            if let target = model.uploadTarget {
                detail = DetailItem(id: "result", title: "本次上传结果的目标", text: target)
            }
        case .showUploadError:
            if let error = uploadError {
                detail = DetailItem(id: "uploadError",
                                    title: model.selectionError == nil ? "错误详情" : "文件选择错误",
                                    text: error)
            }
        default:
            return
        }
        if let request { bus.clear(request) }
    }

    private var bar: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            fileSlot
            if rows.showsTarget { targetRow }
            if rows.showsStatus { statusRow }
        }
        .padding(Metrics.spacing12)
        .background(.quaternary)
        .popover(item: $detail) { item in
            TextDetailsPopover(title: item.title, text: item.text) { detail = nil }
        }
    }

    private var fileSlot: some View {
        HStack(spacing: Metrics.spacing12) {
            Image(systemName: "doc.badge.arrow.up")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: Metrics.spacing4) {
                Text(model.selectedFile?.name ?? "选择要上传的文件")
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Text(sizeText)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let file = model.selectedFile {
                Button { detail = DetailItem(id: "file", title: "所选文件", text: file.name) } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("查看完整文件名").accessibilityLabel("查看完整文件名")
            }
            Button("选择文件…") { showFilePicker = true }
                .help("选择文件（⌘O）")
                .disabled(!model.canChooseFile)
            Button("上传到当前目录") { model.upload() }
                .buttonStyle(.borderedProminent)
                .help("上传到当前目录（⌘⇧U）")
                .disabled(!model.canUpload)
        }
    }

    private var sizeText: String {
        guard let file = model.selectedFile else { return "每次上传一个普通文件" }
        return ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
    }

    private var targetRow: some View {
        HStack(spacing: Metrics.spacing8) {
            Text(model.isUploading ? "上传目标" : "待上传目标").foregroundStyle(.secondary)
            Text(activeTarget ?? "—")
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(activeTarget ?? "")
            Button("完整路径") {
                if let target = activeTarget {
                    detail = DetailItem(id: "target", title: "完整上传目标", text: target)
                }
            }
            .help("查看完整目标（⌘⇧T）")
            .disabled(activeTarget == nil)
        }
        .font(.caption)
    }

    private var activeTarget: String? {
        model.isUploading ? (model.uploadTarget ?? model.pendingTarget) : model.pendingTarget
    }

    private var uploadError: String? {
        if let error = model.selectionError { return error }
        if case .failed(let error) = model.uploadState { return error }
        return nil
    }

    @ViewBuilder
    private var statusRow: some View {
        Divider()
        if let error = model.selectionError {
            failureLine(title: "无法读取所选文件",
                        detailText: "请重新选择一个可读取的普通文件。",
                        popoverID: "selectionError",
                        popoverTitle: "文件选择错误",
                        error: error)
        } else {
            switch model.uploadState {
            case .idle:
                Label("文件已就绪", systemImage: "arrow.up.circle")
                    .font(.caption).foregroundStyle(.secondary)
            case .uploading:
                VStack(alignment: .leading, spacing: Metrics.spacing8) {
                    HStack(spacing: Metrics.spacing8) {
                        Label("正在上传", systemImage: "arrow.up.circle.fill").foregroundStyle(Color.accentColor)
                        Spacer(minLength: Metrics.spacing8)
                        Text("\(bytes(model.sent)) / \(bytes(model.total))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    ProgressView(value: Double(model.sent), total: Double(max(model.total, 1)))
                }
            case .awaitingCompletion:
                HStack(spacing: Metrics.spacing8) {
                    ProgressView().controlSize(.small)
                    Text("数据已发送，等待服务器确认…").font(.callout)
                    Spacer(minLength: Metrics.spacing8)
                    Text("收到最终确认后才会显示上传成功。").font(.caption).foregroundStyle(.secondary)
                }
            case .succeeded:
                VStack(alignment: .leading, spacing: Metrics.spacing8) {
                    Label("上传成功", systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.green)
                    resultLine
                }
            case .failed(let error):
                failureLine(title: "未能确认上传成功",
                            detailText: "远程可能存在部分文件，请核对后再操作。",
                            popoverID: "uploadError",
                            popoverTitle: "错误详情",
                            error: error)
            }
        }
    }

    private func failureLine(title: String,
                             detailText: String,
                             popoverID: String,
                             popoverTitle: String,
                             error: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            HStack(spacing: Metrics.spacing8) {
                Label(title, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                Spacer(minLength: Metrics.spacing8)
                Button("查看错误详情") {
                    detail = DetailItem(id: popoverID, title: popoverTitle, text: error)
                }
                .help("查看错误详情（⌘⇧E）")
            }
            .font(.callout)
            if model.uploadState != .idle { resultLine }
            Text(detailText).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var resultLine: some View {
        HStack(spacing: Metrics.spacing8) {
            Text("本次结果").foregroundStyle(.secondary)
            Text(model.uploadTarget ?? "传输尚未开始")
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(model.uploadTarget ?? "")
            Button("查看目标") {
                if let target = model.uploadTarget {
                    detail = DetailItem(id: "result", title: "本次上传结果的目标", text: target)
                }
            }
            .help("查看目标（⌘⇧Y）")
            .disabled(model.uploadTarget == nil)
        }
        .font(.caption)
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
