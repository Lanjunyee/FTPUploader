import AppKit
import SwiftUI

/// Toolbar plus a single content column: the connection form before a directory
/// loads, the remote directory afterwards, and the activity summary at the bottom.
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
    @State private var showsSites = true

    var body: some View {
        HStack(spacing: 0) {
            if showsSites {
                SiteIconRail(model: model, sites: model.sites)
                Divider()
            }
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
            TransferActivityBar(model: model, announcementsEnabled: !showTransfers)
        }
            }
        .modifier(UploadPresentationOwner(model: model))
        .modifier(FileDropTarget(model: model))
        .fileImporter(isPresented: $chooseBatch, allowedContentTypes: [.data, .folder], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): _ = model.prepareUploadCollection(urls)
            case .failure(let error): model.fileSelectionFailed(error)
            }
        }
        .sheet(item: transferSheet) { sheet in
            switch sheet {
            case .queue: TransferPanel(model: model)
            case .collection: TransferPreviewView(model: model, onConfirmed: { showTransfers = true })
            }
        }
        .modifier(BatchOverwriteDialog(model: model, enabled: !showTransfers && !model.collectionScan.isLocked))
        .onChange(of: model.collectionScan.phase) { phase in
            switch phase {
            case .scanning: announce("正在只读扫描传输计划")
            case .preview: announce("扫描完成，请核对完整计划")
            case .cancelling: announce("正在取消扫描，等待资源释放")
            default: break
            }
        }
        .onChange(of: bus.request) { request in
            if request == .chooseBatch {
                if model.canPrepareCollection { chooseBatch = true }
                bus.clear(.chooseBatch)
            }
            if request == .toggleSites { showsSites.toggle(); bus.clear(.toggleSites) }
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
                Button { showsSites.toggle() } label: {
                    Label(showsSites ? "收起站点栏" : "展开站点栏", systemImage: "sidebar.left")
                }
                .help(showsSites ? "收起站点栏" : "展开站点栏")
                .accessibilityValue(showsSites ? "已展开" : "已收起")
                WorkbenchIconButton(title: "上一级", symbol: "chevron.up", help: "上一级（⌘↑）",
                                    enabled: model.hasDirectory && model.path.parent != nil && !model.isBusy) { model.goUp() }
                PathToolbarItem(model: model)
                WorkbenchIconButton(title: "刷新", symbol: "arrow.clockwise", help: "刷新（⌘R）",
                                    enabled: model.endpoint != nil && !model.isBusy) { model.refresh() }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let cancellationID = model.cancellationID {
                    Button { model.cancelOperation(id: cancellationID) } label: {
                        Label("取消当前操作", systemImage: "stop.circle")
                    }
                    .help("取消当前操作（⌘.）")
                    .disabled(!model.canCancel)
                }
                WorkbenchIconMenu(title: "上传", symbol: "doc.badge.arrow.up",
                                  help: "上传：选择文件或扫描文件／文件夹", enabled: model.canChooseFile) {
                    Button("选择单个文件…") { bus.send(.chooseFile) }.disabled(!model.canChooseFile)
                    Button("上传文件／文件夹…") { bus.send(.chooseBatch) }.disabled(!model.canPrepareCollection)
                }
                WorkbenchIconButton(title: "下载", symbol: "arrow.down.doc", help: "下载所选项目（⌘D）",
                                    enabled: bus.canDownloadSelection) { bus.send(.downloadSelectedItems) }
                WorkbenchIconButton(title: "筛选", symbol: "line.3.horizontal.decrease.circle", help: "筛选当前目录（⌘F）",
                                    enabled: model.hasDirectory) { bus.send(.showFilter) }
                WorkbenchIconButton(title: "队列与记录", symbol: "list.bullet.rectangle", help: "队列与记录（⌘⇧H）") {
                    bus.send(.showTransfers)
                }
                WorkbenchIconMenu(title: "更多", symbol: "ellipsis.circle", help: "更多操作") {
                    Button("上一级") { model.goUp() }.disabled(!model.hasDirectory || model.path.parent == nil || model.isBusy)
                    Button("刷新") { model.refresh() }.disabled(model.endpoint == nil || model.isBusy)
                    Divider()
                    Button("选择单个文件…") { bus.send(.chooseFile) }.disabled(!model.canChooseFile)
                    Button("上传文件／文件夹…") { bus.send(.chooseBatch) }.disabled(!model.canPrepareCollection)
                    Button(bus.downloadSelectionTitle) { bus.send(.downloadSelectedItems) }.disabled(!bus.canDownloadSelection)
                    Button("筛选当前目录…") { bus.send(.showFilter) }.disabled(!model.hasDirectory)
                    Button("文件信息／完整名称") { bus.send(.showDirectoryInfo) }.disabled(!bus.canShowDirectoryInfo)
                    Button("队列与记录…") { bus.send(.showTransfers) }
                    Button("连接与完整位置") { bus.send(.showPath) }
                    Button(showsSites ? "收起站点栏" : "展开站点栏") { bus.send(.toggleSites) }
                    SiteMenu(model: model, sites: model.sites)
                }
            }
        }
    }
    private enum TransferSheet: Hashable, Identifiable {
        case queue, collection
        var id: Self { self }
    }
    private var transferSheet: Binding<TransferSheet?> {
        let collectionID = model.collectionScan.cancellationID
        let displayed: TransferSheet? = model.collectionScan.isLocked ? .collection : (showTransfers ? .queue : nil)
        return Binding(get: {
            model.collectionScan.isLocked ? .collection : (showTransfers ? .queue : nil)
        }, set: { value in
            guard value == nil else { return }
            if displayed == .collection, let collectionID { model.cancelOperation(id: collectionID) }
            else if displayed == .queue, !model.collectionScan.isLocked { showTransfers = false }
        })
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
                Image(systemName: model.directoryError != nil ? "exclamationmark.circle" :
                        (model.isDirectoryLoading ? "arrow.triangle.2.circlepath" : "network"))
                Text(model.hasDirectory ? (model.path.components.last?.name ?? "/") : "连接与站点")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 80, maxWidth: 180, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(model.hasDirectory ? "当前路径：\(model.currentLocation)" : "连接与站点（尚未连接）")
        .accessibilityLabel("连接与位置")
        .accessibilityValue(model.hasDirectory ? model.currentLocation : "未连接")
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
            SiteMenu(model: model, sites: model.sites)
            if model.hasDirectory {
                Text(model.isDirectoryLoading ? "正在读取目录" : (model.directoryError == nil ? "已连接" : "目录未更新"))
                    .font(.callout)
                Text(model.connectionIdentity).font(.callout).textSelection(.enabled)
            }
            Text(model.hasDirectory ? "当前有效连接与完整路径" : "尚未连接").font(.headline)
            ScrollView {
                Text(model.hasDirectory ? model.currentLocation : "尚无有效目录连接").font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Metrics.detailsPopoverMaxHeight)
            Divider()
            Text("待连接地址（修改不改变当前有效连接）").font(.subheadline).foregroundStyle(.secondary)
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
                Button("复制路径") { copy(model.currentLocation) }.disabled(!model.hasDirectory)
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
    @ObservedObject var sites: SiteManager

    var body: some View {
        Menu {
            Button("手动连接") { model.selectSite(nil) }
                .disabled(!model.canEditConnection)
            if !sites.sites.isEmpty {
                Divider()
                ForEach(sites.sites) { site in
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
              let site = sites.sites.first(where: { $0.id == id }) else { return "手动连接" }
        return site.name
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

/// A scrollable, visibly distinguished site list; choosing never connects.
@MainActor
private struct SiteIconRail: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sites: SiteManager

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Metrics.spacing8) {
                    Button { model.selectSite(nil) } label: {
                        Label("手动", systemImage: "network")
                            .accessibilityLabel(model.selectedSiteID == nil ? "手动连接，已选择" : "手动连接，未选择")
                    }
                    .help("手动连接（不自动连接）")

                    .disabled(!model.canEditConnection)
                    ForEach(Array(sites.sites.enumerated()), id: \.element.id) { index, site in
                        Button { model.selectSite(site.id) } label: {
                            Label("\(index + 1) · \(site.name.prefix(3))", systemImage: "server.rack")
                            .font(.callout).lineLimit(1)
                            .accessibilityLabel("选择站点：" + site.name + (model.selectedSiteID == site.id ? "，已选择" : "，未选择"))
                            .frame(maxWidth: .infinity)
                            .padding(Metrics.spacing4)
                            .background(model.selectedSiteID == site.id ? Color.accentColor.opacity(0.15) : Color.clear)
                            .cornerRadius(Metrics.cornerRadius)
                        }
                        .id(site.id)
                        .help(site.name + "（选择后需另行连接）")

                        .disabled(!model.canEditConnection)
                    }
                }
                .buttonStyle(.borderless)
                .padding(Metrics.spacing8)
            }
            .onChange(of: model.selectedSiteID) { id in
                if let id { proxy.scrollTo(id) }
            }
            .onAppear { if let id = model.selectedSiteID { proxy.scrollTo(id) } }
        }
        .frame(width: 88)
        .background(.bar)
        .accessibilityLabel("站点栏")
    }
}

@MainActor
private struct TransferPreviewView: View {
    @ObservedObject var model: AppModel
    let onConfirmed: () -> Void
    @State private var confirmationFailed = false
    @FocusState private var scanCancelFocused: Bool
    var body: some View {
        let cancellationID = model.collectionScan.cancellationID
        VStack(alignment: .leading, spacing: 12) {
            if model.collectionScan.phase == .scanning || model.collectionScan.phase == .cancelling {
                Text("核对传输计划").font(.title2)
                ProgressView()
                Text(model.collectionScan.phase == .cancelling ? "正在取消，等待扫描停止及授权释放…" : "只读扫描 · 已发现 \(model.collectionScan.discoveredNodes) 项")
                Button("取消计划") { if let cancellationID { model.cancelOperation(id: cancellationID) } }
                    .keyboardShortcut(.cancelAction).disabled(model.collectionScan.phase == .cancelling)
                    .focused($scanCancelFocused)
                    .onAppear { scanCancelFocused = true }
            } else if let plan = model.collectionScan.plan {
                TransferPlanPreviewContent(plan: plan, canRemoveRoots: model.canRemoveCollectionRoots,
                    location: location, issueTitle: issueTitle,
                    onRemove: { _ = model.removeCollectionRoot($0) },
                    onConfirm: {
                        confirmationFailed = !model.confirmCollection(plan.id, policy: $0)
                        if !confirmationFailed { onConfirmed() }
                    },
                    onCancel: { if let cancellationID { model.cancelOperation(id: cancellationID) } })
            }
            if confirmationFailed {
                Text(model.selectionError ?? "计划确认已失效，请取消后重新扫描。")
                    .foregroundStyle(.red).textSelection(.enabled)
            }
        }.padding(16).frame(minWidth: 580, idealWidth: 760, minHeight: 420, idealHeight: 600)
        .onExitCommand {
            if model.collectionScan.phase != .cancelling, let cancellationID {
                model.cancelOperation(id: cancellationID)
            }
        }
        .onChange(of: model.collectionScan.plan?.id) { _ in confirmationFailed = false }
    }
    private func location(_ value: TransferPlan.Location) -> String {
        switch value {
        case .local(let url): return url.path
        case .remote(let path, _): return (model.endpoint?.display ?? "") + path.display
        }
    }
    private func issueTitle(_ reason: TransferPlan.Issue.Reason) -> String {
        switch reason {
        case .overlappingRoots: return "所选根重叠"
        case .duplicateTarget: return "目标重复"
        case .typeConflict: return "文件/目录类型冲突"
        case .localAlias: return "本地名称别名冲突"
        case .invalidName: return "名称无法安全保存或编码"
        case .unsupportedType: return "不支持链接、特殊或未知类型"
        case .invalidDependency: return "父目录依赖不完整"
        case .invalidDirection: return "任务方向不符"
        case .unreadable: return "无法读取"
        case .changedSource: return "来源已变化"
        case .nodeLimit: return "超过节点上限"
        case .depthLimit: return "超过深度上限"
        case .listingLimit: return "超过列表数据上限"
        case .sizeOverflow, .invalidSize: return "大小无效或溢出"
        case .cycle: return "循环来源"
        case .incomplete: return "扫描不完整"
        }
    }
}
