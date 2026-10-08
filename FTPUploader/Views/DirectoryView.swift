import AppKit
import SwiftUI

/// One directory row adapted for the table's sortable columns. The sort keys come
/// from `DirectorySorting`, so the table orders entries exactly as the unit tests say.
private struct DirectoryRow: Identifiable {
    let entry: RemoteEntry
    let location: String

    var id: Data { entry.id }
    var name: String { entry.name }
    var kindRank: Int { DirectorySorting.kindRank(isDirectory: entry.isDirectory) }
    var sizeRank: Int64 { DirectorySorting.sizeRank(entry.size) }
}

/// The connected state: a native table becomes the window body. Navigation lives in
/// the toolbar, so this view owns the table, the failure notice and the footer only.
@MainActor
struct DirectoryView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var bus: TransferCommandBus
    @State private var selectedEntry: Data?
    @State private var sortOrder: [KeyPathComparator<DirectoryRow>] = []
    @State private var showFailure = false
    @State private var nameEntry: Data?

    private var rows: [DirectoryRow] {
        // SwiftUI's Table reports header clicks through `sortOrder` but does not sort
        // the data itself, so the ordering is applied here.
        if sortOrder.isEmpty {
            // Before the first header click the table keeps the parser's order.
            return DirectorySorting.sorted(model.entries, by: .kind, ascending: true)
                .map { DirectoryRow(entry: $0, location: model.currentLocation) }
        }
        return model.entries
            .map { DirectoryRow(entry: $0, location: model.currentLocation) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.directoryError, model.hasDirectory {
                failureNotice(error)
                Divider()
            }
            if model.entries.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minHeight: 100)
            } else {
                table
            }
            Divider()
            footer
        }
        .onChange(of: model.currentLocation) { _ in
            selectedEntry = nil
            nameEntry = nil
        }
        .onChange(of: model.entries) { entries in
            if !entries.contains(where: { $0.id == selectedEntry }) { selectedEntry = nil }
            if !entries.contains(where: { $0.id == nameEntry }) { nameEntry = nil }
            syncOpenAvailability()
        }
        .onChange(of: selectedEntry) { _ in syncOpenAvailability() }
        .onChange(of: model.isBusy) { _ in syncOpenAvailability() }
        .onAppear { syncOpenAvailability() }
        .onDisappear { bus.setOpenAvailability(false); bus.canDownloadSelectedFile = false }
        .onChange(of: bus.request) { request in
            switch request {
            case .showDirectoryError:
                showFailure = true
                bus.clear(.showDirectoryError)
            case .downloadSelectedFile:
                if let row = selectedRow { chooseDownload(row.entry) }
                bus.clear(.downloadSelectedFile)
            case .openSelectedFolder:
                openSelectedFolder()
                bus.clear(.openSelectedFolder)
            default:
                break
            }
        }
        .modifier(FileDropTarget(model: model))
    }

    /// The selected row, and the subset of it that the open command can act on.
    private var selectedRow: DirectoryRow? { rows.first { $0.id == selectedEntry } }
    private var selectedFolder: DirectoryRow? {
        guard let row = selectedRow, row.entry.isDirectory else { return nil }
        return row
    }

    private func syncOpenAvailability() {
        bus.setOpenAvailability(selectedFolder != nil && !model.isBusy)
        bus.canDownloadSelectedFile = selectedRow != nil && selectedFolder == nil && !model.isBusy
    }

    private func openSelectedFolder() {
        guard let folder = selectedFolder, !model.isBusy else { return }
        model.enter(folder.entry)
    }

    private func chooseDownload(_ entry: RemoteEntry) {
        guard !entry.isDirectory, !model.isBusy else { return }
        let panel = NSSavePanel()
        panel.title = "下载文件"; panel.prompt = "保存"; panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let identity = try LocalDownload.identity(url)
                model.download(entry, to: url, authorizedIdentity: identity)
            } catch { model.downloadSelectionFailed(error) }
        }
    }

    private var table: some View {
        Table(rows, selection: $selectedEntry, sortOrder: $sortOrder) {
            TableColumn("名称", value: \.name) { row in
                DirectoryEntryCell(entry: row.entry,
                                   isSelected: selectedEntry == row.id,
                                   isBusy: model.isBusy,
                                   showName: Binding(get: { nameEntry == row.id },
                                                     set: { nameEntry = $0 ? row.id : nil })) {
                    guard !model.isBusy else { return }
                    model.enter(row.entry)
                }
            }
            TableColumn("类型", value: \.kindRank) { row in
                Text(row.entry.isDirectory ? "文件夹" : "文件")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .width(min: 56, ideal: 64, max: 120)
            TableColumn("大小", value: \.sizeRank) { row in
                Text(DirectoryEntryCell.sizeText(row.entry))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .width(min: 64, ideal: 88, max: 180)
        }
        .contextMenu(forSelectionType: Data.self) { ids in
            if ids.count == 1, let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                if row.entry.isDirectory {
                    Button("打开") { open(ids) }
                        .disabled(model.isBusy)
                }
                if !row.entry.isDirectory {
                    Button("下载…") { chooseDownload(row.entry) }.disabled(model.isBusy)
                        .accessibilityLabel("下载文件 " + row.entry.name)
                }
                Button("查看完整名称") { nameEntry = id }
            }
        } primaryAction: { ids in
            open(ids)
        }
        .frame(minHeight: 100)
    }

    private func open(_ ids: Set<Data>) {
        guard !model.isBusy, ids.count == 1, let id = ids.first,
              let row = rows.first(where: { $0.id == id }), row.entry.isDirectory else { return }
        model.enter(row.entry)
    }

    private func failureNotice(_ error: String) -> some View {
        HStack(spacing: Metrics.spacing8) {
            Label { Text("目录读取失败，已保留原目录").foregroundStyle(.primary) } icon: {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
            }
            Spacer(minLength: Metrics.spacing8)
            Button("查看详情") { showFailure = true }
                .help("查看目录错误详情（⌘⇧D）")
                .popover(isPresented: $showFailure, arrowEdge: .bottom) {
                    TextDetailsPopover(title: "目录错误", text: error) { showFailure = false }
                }
        }
        .font(.callout)
        .padding(.horizontal, Metrics.spacing12)
        .padding(.vertical, Metrics.spacing8)
        .onChange(of: error) { _ in showFailure = false }
    }

    private var footer: some View {
        HStack {
            Text("\(model.entries.count) 个项目")
            Spacer()
            HStack(spacing: Metrics.spacing4) {
                Image(systemName: connectionStatusSymbol).foregroundStyle(connectionStatusTint)
                Text(connectionStatusTitle).foregroundStyle(.primary).fixedSize()
            }
            .accessibilityElement(children: .combine)
            Text("·")
            Text(model.connectionIdentity).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Metrics.spacing12)
        .padding(.vertical, Metrics.spacing8)
    }

    private var connectionStatusTitle: String {
        if model.isDirectoryLoading { return "正在读取" }
        if model.directoryError != nil { return "目录未更新" }
        return "已连接"
    }

    private var connectionStatusSymbol: String {
        if model.isDirectoryLoading { return "arrow.triangle.2.circlepath" }
        if model.directoryError != nil { return "exclamationmark.circle.fill" }
        return "checkmark.circle.fill"
    }

    private var connectionStatusTint: Color {
        if model.isDirectoryLoading { return .secondary }
        if model.directoryError != nil { return .orange }
        return .green
    }

    private var emptyState: some View {
        VStack(spacing: Metrics.spacing12) {
            if model.isDirectoryLoading {
                ProgressView().controlSize(.small)
                Text("远程目录").font(.headline)
                Text("读取完成后即可选择上传文件。").font(.callout).foregroundStyle(.secondary)
            } else {
                Image(systemName: "folder")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor.opacity(0.7))
                Text("这个文件夹是空的").font(.headline)
                Text("选择一个文件，上传到当前目录。").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(Metrics.spacing16)
    }
}

/// Name cell: a single click selects the row through the native table, a double
/// click on a folder row opens it, and the full name stays reachable from the
/// row's info button or its ⌘I shortcut. There is no separate open button, so a
/// stray single click can never navigate.
@MainActor
private struct DirectoryEntryCell: View {
    let entry: RemoteEntry
    let isSelected: Bool
    let isBusy: Bool
    @Binding var showName: Bool
    let open: () -> Void
    @State private var isHovering = false

    static func sizeText(_ entry: RemoteEntry) -> String {
        entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
    }

    var body: some View {
        HStack(spacing: Metrics.spacing8) {
            interactiveName
            // Hover reveals the entry point, but it is never the only way in:
            // the selected row keeps it, so ⌘I stays reachable without a pointer.
            if isHovering || isSelected {
                Button { showName = true } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .keyboardShortcut(isSelected ? KeyboardShortcut("i", modifiers: .command) : nil)
                    .help("查看完整名称（选中后 ⌘I）").accessibilityLabel("查看名称：\(entry.name)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovering = $0 }
        .popover(isPresented: $showName, arrowEdge: .trailing) {
            TextDetailsPopover(title: entry.isDirectory ? "文件夹名称" : "文件名称", text: entry.name) {
                showName = false
            }
        }
    }

    @ViewBuilder
    private var interactiveName: some View {
        if entry.isDirectory {
            name
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // Combine so the folder is one accessibility element that exposes a
                // semantic open action, not just a pointer gesture.
                .accessibilityElement(children: .combine)
                .accessibilityLabel(entry.name)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { if !isBusy { open() } }
        } else {
            name
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityLabel("远程文件：\(entry.name)")
        }
    }

    private var name: some View {
        HStack(spacing: Metrics.spacing8) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
            Text(entry.name).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
    }
}
