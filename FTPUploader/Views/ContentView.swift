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

    var body: some View {
        VStack(spacing: 0) {
            if model.hasDirectory {
                DirectoryView(model: model)
            } else {
                ConnectionView(model: model)
            }
            if model.hasDirectory {
                Divider()
                UploadView(model: model)
            }
        }
        .frame(minWidth: Metrics.minimumWindowWidth, minHeight: Metrics.minimumWindowHeight)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.goUp() } label: { Image(systemName: "chevron.up") }
                    .help("上一级（⌘↑）")
                    .disabled(!model.hasDirectory || model.path.parent == nil || model.isBusy)
                PathToolbarItem(model: model)
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新（⌘R）")
                    .disabled(model.endpoint == nil || model.isBusy)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                ConnectionStatusBadge(model: model)
                SiteMenu(model: model)
            }
        }
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
            Text("服务器地址").font(.caption).foregroundStyle(.secondary)
            TextField("输入 FTP 服务器地址", text: $draftAddress)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("FTP 服务器地址")
                .disabled(!model.canEditConnection)
                .onSubmit { reconnect() }
            Text("支持 ftp:// 地址或主机名，例如 ftp://example.com:21/uploads")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = model.fieldIssue?.message {
                Text(message)
                    .font(.caption).foregroundStyle(.red)
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
private struct ConnectionStatusBadge: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: Metrics.spacing4) {
            Image(systemName: symbol)
            Text(title)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    private var title: String {
        if model.isDirectoryLoading { return "正在读取" }
        if model.directoryError != nil { return model.hasDirectory ? "目录未更新" : "连接失败" }
        if model.hasDirectory { return "已连接" }
        return "未连接"
    }

    private var symbol: String {
        if model.isDirectoryLoading { return "arrow.triangle.2.circlepath" }
        if model.directoryError != nil { return "exclamationmark.circle.fill" }
        if model.hasDirectory { return "checkmark.circle.fill" }
        return "circle"
    }

    private var tint: Color {
        if model.isDirectoryLoading { return .secondary }
        if model.directoryError != nil { return .orange }
        if model.hasDirectory { return .green }
        return .secondary
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
