import AppKit
import SwiftUI

/// Toolbar plus a single content column: the connection form before a directory
/// loads, the remote directory afterwards, and the upload bar pinned to the bottom.
///
/// Key equivalents live in the 传输 menu (`TransferCommands`); the controls here keep
/// help text only, so no shortcut fires twice.
@MainActor
struct ContentView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var bus: TransferCommandBus
    @State private var showResetTrust = false
    @State private var showTransfers = false
    @State private var chooseBatch = false

    var body: some View {
        VStack(spacing: 0) {
            if model.hasDirectory {
                DirectoryView(model: model)
            } else {
                ConnectionView(model: model)
            }
            if model.isDirectoryCancelling || model.directoryCancelled {
                Label(model.isDirectoryCancelling ? "正在取消，等待操作停止…" : "目录操作已取消",
                      systemImage: "stop.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Metrics.spacing12)
            }
            if let changed = model.changedHost {
                VStack(alignment: .leading, spacing: Metrics.spacing8) {
                    Text("SFTP 主机密钥已变化，已阻止认证。请先向服务器管理员核实。")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(changed.host):\(String(changed.port)) · \(changed.keyType)\n\(changed.fingerprint)").textSelection(.enabled)
                    Button("重置此主机的信任…") { showResetTrust = true }
                        .disabled(!model.canEditConnection)
                }
                .padding(Metrics.spacing12)
            }
            if model.isUploading || model.isDownloading || model.batch.isExecuting {
                MetricsView(monitor: model.metrics).padding(.horizontal, 12)
            }
            if model.downloadState != .idle {
                VStack(alignment: .leading, spacing: 4) {
                    Text(downloadStatus).font(.callout)
                    if let cleanup = model.downloadCleanupError { Text(cleanup).font(.caption).textSelection(.enabled) }
                    if let target = model.downloadTarget {
                        Text(target).font(.caption).lineLimit(2).textSelection(.enabled)
                    }
                    if model.isDownloading {
                        ProgressView(value: Double(model.downloadBytes), total: Double(max(1, model.downloadTotal)))
                            .accessibilityLabel("下载进度")
                    }
                }.padding(Metrics.spacing12)
            }
            if model.hasDirectory {
                Divider()
                UploadView(model: model)
            }
        }
        .fileImporter(isPresented: $chooseBatch, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.prepareBatch(urls); if model.batch.isLocked { showTransfers = true }
            case .failure(let error): model.fileSelectionFailed(error)
            }
        }
        .sheet(isPresented: $showTransfers) { TransferPanel(model: model) }
        .onChange(of: bus.request) { request in
            if request == .chooseBatch { chooseBatch = true; bus.clear(.chooseBatch) }
            if request == .showTransfers { showTransfers = true; bus.clear(.showTransfers) }
        }
        .frame(minWidth: Metrics.minimumWindowWidth, minHeight: Metrics.minimumWindowHeight)
        .onChange(of: model.isDirectoryCancelling) { cancelling in
            if cancelling { announce("正在取消，等待操作停止") }
        }
        .onChange(of: model.directoryCancelled) { cancelled in
            if cancelled { announce("目录操作已取消") }
        }
        .onChange(of: model.downloadState) { _ in announce(downloadStatus) }
        .alert("下载目标已发生变化，覆盖？", isPresented: Binding(
            get: { model.downloadConfirmationID != nil },
            set: { if !$0 { model.cancelDownloadConfirmation() } }
        ), presenting: model.downloadConfirmationID) { id in
            Button("取消", role: .cancel) { model.cancelDownloadConfirmation() }.keyboardShortcut(.defaultAction)
            Button("仅本次覆盖") { model.confirmDownloadCommit(id) }
        } message: { _ in Text(model.downloadTarget ?? "") }
        .alert("核对 SFTP 服务器指纹", isPresented: Binding(
            get: { model.hostTrustRequest != nil },
            set: { if !$0 { model.cancelHostTrust() } }
        ), presenting: model.hostTrustRequest) { identity in
            Button("取消", role: .cancel) { model.cancelHostTrust() }.keyboardShortcut(.defaultAction)
            Button("已核对，信任此主机") { model.acceptHostTrust(identity.id) }
        } message: { identity in
            Text("主机：\(identity.host)\n端口：\(String(identity.port))\n密钥类型：\(identity.keyType)\n指纹：\(identity.fingerprint)\n请与管理员提供的指纹核对。取消不会发送账户密码。")
        }
        .alert("重置已保存的 SFTP 主机信任？", isPresented: $showResetTrust, presenting: model.changedHost) { identity in
            Button("取消", role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button("重置并重新核对", role: .destructive) { model.resetHostTrust(identity.id) }
        } message: { identity in
            Text("仅移除 \(identity.host):\(String(identity.port)) 的已保存主机密钥。随后必须重新核对新指纹，重置本身不会信任新密钥。请先向管理员确认服务器变更。")
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.goUp() } label: { Label("上一级", systemImage: "chevron.up") }
                    .labelStyle(.iconOnly)
                    .help("上一级（⌘↑）")
                    .disabled(!model.hasDirectory || model.path.parent == nil || model.isBusy)
                PathToolbarItem(model: model)
                Button { model.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .labelStyle(.iconOnly)
                    .help("刷新（⌘R）")
                    .disabled(model.endpoint == nil || model.isBusy)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let cancellationID = model.cancellationID {
                    Button { model.cancelOperation(id: cancellationID) } label: {
                        Label("取消当前操作", systemImage: "stop.circle")
                    }
                    .help("取消当前操作（⌘.）")
                    .disabled(!model.canCancel)
                }
                Button { showTransfers = true } label: { Label("队列与记录", systemImage: "list.bullet.rectangle") }
                SiteMenu(model: model)
            }
        }
    }
    private var downloadStatus: String {
        switch model.downloadState {
        case .idle: return ""
        case .checkingTarget: return "正在校验下载目标"
        case .uploading: return "正在下载"
        case .awaitingCompletion: return "下载等待最终确认"
        case .awaitingOverwrite: return "下载完成，等待本地覆盖确认"
        case .cancelling: return "正在取消下载"
        case .cancelled: return "下载已取消"
        case .succeeded: return "下载成功"
        case .failed(let reason): return "下载失败：" + reason
        }
    }
    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// The path control: a middle-truncated read-only path that opens the full path,
/// an editable address and a reconnect entry.
@MainActor
private struct PathToolbarItem: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var bus: TransferCommandBus
    @State private var showPath = false

    var body: some View {
        Button { showPath = true } label: {
            HStack(spacing: Metrics.spacing8) {
                Image(systemName: "folder")
                Text(model.currentLocation)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("当前路径：\(model.currentLocation)")
        .accessibilityLabel("当前路径：\(model.currentLocation)")
        .disabled(!model.hasDirectory)
        .popover(isPresented: $showPath, arrowEdge: .bottom) {
            PathPopover(model: model) { showPath = false }
        }
        .onChange(of: bus.request) { request in
            guard request == .showPath else { return }
            showPath = true
            bus.clear(.showPath)
        }
    }
}

/// Full path, editable address and reconnect. Every editable control is disabled
/// while a transfer is running, so the fixed-target contract cannot be bypassed.
@MainActor
private struct PathPopover: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    @State private var draftAddress = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            Text("当前完整路径").font(.headline)
            ScrollView {
                Text(model.currentLocation).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Metrics.detailsPopoverMaxHeight)
            Divider()
            Text("服务器地址").font(.subheadline).foregroundStyle(.secondary)
            TextField("输入 FTP 服务器地址", text: $draftAddress)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("FTP 服务器地址")
                .disabled(!model.canEditConnection)
                .onSubmit { reconnect() }
            Text("支持 ftp:// 地址或主机名，例如 ftp://example.com:21/uploads")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = model.fieldIssue?.message {
                Label { Text(message).foregroundStyle(.primary) } icon: {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Button("复制路径") { copy(model.currentLocation) }
                Spacer()
                Button("重新连接") { reconnect() }
                    .disabled(!model.canEditConnection || model.isDirectoryLoading
                              || draftAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(Metrics.spacing16)
        .frame(width: Metrics.detailsPopoverWidth)
        .onAppear {
            model.dismissFieldIssue()
            draftAddress = model.address
        }
        .onChange(of: model.currentLocation) { _ in close() }
    }

    private func reconnect() {
        // The model validates the draft before applying it, so an invalid address
        // keeps this popover, its draft and the old directory open.
        if model.reconnect(to: draftAddress) { close() }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
private struct SiteMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu {
            Button("手动连接") { model.selectSite(nil) }
                .disabled(!model.canEditConnection)
            if !model.sites.sites.isEmpty {
                Divider()
                ForEach(model.sites.sites) { site in
                    Button(site.name) { model.selectSite(site.id) }
                        .disabled(!model.canEditConnection)
                }
            }
            Divider()
            Button("站点设置…") { openSettings() }
        } label: {
            Label(title, systemImage: "bookmark")
        }
        .help("选择站点（不自动连接）")
    }

    private var title: String {
        guard let id = model.selectedSiteID,
              let site = model.sites.sites.first(where: { $0.id == id }) else { return "手动连接" }
        return site.name
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
