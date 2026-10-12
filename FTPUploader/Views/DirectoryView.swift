import AppKit
import SwiftUI

/// The connected state: a native table becomes the window body. Navigation lives in
/// the toolbar, so this view owns the table, the failure notice and the footer only.
@MainActor
struct DirectoryView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var bus: TransferCommandBus
    @State private var selectedEntries: Set<Data> = []
    @State private var sortOrder: [KeyPathComparator<DirectoryRow>] = []
    @State private var showFailure = false
    @State private var nameEntry: Data?
    @State private var showsKind = false
    @State private var showsFilter = false
    @State private var filterQuery = ""
    @State private var filterFocusRequest = UUID()
    @State private var projection = DirectoryProjectionCache()
    @State private var uiRevision: UInt64 = 0
    @State private var directoryContext: DirectoryContext?
    private enum Focus: Hashable { case filter, directory }
    @FocusState private var focus: Focus?

    private var sortColumn: DirectorySortColumn {
        guard let comparator = sortOrder.first else { return .kind }
        return comparator.keyPath == \.name ? .name : (comparator.keyPath == \.sizeRank ? .size : .kind)
    }
    private var sortAscending: Bool { sortOrder.first?.order != .reverse }
    private var rows: [DirectoryRow] { projection.rows }
    private var selectionIsCurrent: Bool {
        directoryContext == model.effectiveDirectoryContext &&
            projection.isCurrent(model.entries, query: filterQuery, sort: sortColumn, ascending: sortAscending,
                generation: model.directoryContentRevision, location: model.currentLocation)
    }
    private func updateProjection() {
        uiRevision &+= 1
        projection.update(model.entries, query: filterQuery, sort: sortColumn, ascending: sortAscending,
            generation: model.directoryContentRevision, location: model.currentLocation)
        projection.select(selectedEntries)
        selectedEntries = projection.selectedIDs
        nameEntry = nil
        syncOpenAvailability()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                WorkbenchIconMenu(title: "所选项目更多操作", symbol: "ellipsis.circle", help: "所选项目的打开、下载及文件信息") {
                    selectionMenu
                }
                .disabled(selectedRows.isEmpty)
                Menu("目录显示") {
                    Toggle("显示类型列", isOn: $showsKind)
                    Menu("排序") {
                        ForEach(DirectorySortColumn.allCases) { column in
                            Button("按" + column.title + "升序") { setSort(column, ascending: true) }
                            Button("按" + column.title + "降序") { setSort(column, ascending: false) }
                        }
                    }
                }
                .help("显示类型列及排序")
            }.padding(Metrics.spacing8)
            if showsFilter { filterBar }
            if let error = model.directoryError, model.hasDirectory {
                failureNotice(error)
                Divider()
            }
            if model.isDirectoryLoading {
                HStack { ProgressView().controlSize(.small); Text("正在读取目录…").font(.callout); Spacer() }
                    .padding(Metrics.spacing8)
            }
            if projection.entries.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minHeight: 100)
                    .focusable().focused($focus, equals: .directory)
            } else {
                table.focused($focus, equals: .directory)
            }
            Divider()
            footer
        }
        .onChange(of: filterQuery) { _ in updateProjection() }
        .onChange(of: sortOrder) { _ in updateProjection() }
        .onChange(of: model.effectiveDirectoryContext) { context in
            if DirectoryFilterLifetime.shouldReset(from: directoryContext, to: context) {
                filterQuery = ""
                selectedEntries = []
                nameEntry = nil
            }
            directoryContext = context
            updateProjection()
        }
        .onChange(of: model.directoryContentRevision) { _ in updateProjection() }
        .onChange(of: selectedEntries) { _ in
            projection.select(selectedEntries)
            selectedEntries = projection.selectedIDs
            uiRevision &+= 1; nameEntry = nil; syncOpenAvailability()
        }
        .onChange(of: model.isBusy) { _ in syncOpenAvailability() }
        .onAppear { directoryContext = model.effectiveDirectoryContext; updateProjection() }
        .onDisappear {
            uiRevision &+= 1
            selectedEntries = []
            projection.select([])
            filterQuery = ""
            directoryContext = nil
            nameEntry = nil
            bus.setOpenAvailability(false)
            bus.canDownloadSelection = false
            bus.canShowDirectoryInfo = false
        }
        .onChange(of: bus.request) { request in
            switch request {
            case .showFilter:
                showsFilter = true
                focus = .filter
                filterFocusRequest = UUID()
                bus.clear(.showFilter)
            case .showDirectoryInfo:
                perform(.information)
                bus.clear(.showDirectoryInfo)
            case .showDirectoryError:
                showFailure = true
                bus.clear(.showDirectoryError)
            case .downloadSelectedItems:
                perform(.download)
                bus.clear(.downloadSelectedItems)
            case .openSelectedFolder:
                perform(.openFolder)
                bus.clear(.openSelectedFolder)
            default:
                break
            }
        }
        .popover(isPresented: Binding(get: { nameEntry != nil && nameEntry == selectedRow?.id },
                                      set: { if !$0 { nameEntry = nil } })) {
            if let row = selectedRow, nameEntry == row.id {
                TextDetailsPopover(title: "文件信息", text: row.entry.information(in: model.currentLocation)) { nameEntry = nil }
            }
        }
        .modifier(FileDropTarget(model: model))
    }

    private var filterBar: some View {
        HStack(spacing: Metrics.spacing8) {
            Text("筛选当前目录").font(.callout)
            DirectoryFilterField(query: $filterQuery, focusRequest: filterFocusRequest) { currentText in
                if !currentText.isEmpty { filterQuery = "" }
                else { closeFilter() }
            }
            .frame(height: 24)
            Button("清除") { filterQuery = ""; focus = .filter; filterFocusRequest = UUID() }
                .disabled(filterQuery.isEmpty).help("清除当前目录筛选")
            Button("收起") { closeFilter() }.help("收起筛选并返回目录")
        }
        .padding(Metrics.spacing8)
    }

    private func closeFilter() {
        filterQuery = ""
        showsFilter = false
        focus = .directory
    }

    private var selectedRows: [RemoteEntry] { selectionIsCurrent ? projection.selectedEntries : [] }

    private var selectionMenu: some View {
        ForEach(selectionIsCurrent ? projection.actions(isBusy: model.isBusy) : []) { item in
            Button(item.title) { perform(item.id) }.disabled(!item.enabled)
        }
    }

    private func perform(_ action: RemoteDirectorySelection.Action) {
        // Every route resolves the current selection again at event time.
        switch action {
        case .openFolder: openSelectedFolder()
        case .download: chooseDownload(selectedRows)
        case .information: nameEntry = selectedRow?.id
        }
    }
    private var selectedRow: DirectoryRow? { selectionIsCurrent ? projection.selectedRow : nil }
    private var selectedFolder: RemoteEntry? { RemoteDirectorySelection.uniqueFolder(selectedRows) }

    private func syncOpenAvailability() {
        let entries = selectedRows
        bus.canShowDirectoryInfo = selectedRow != nil
        bus.setOpenAvailability(selectedFolder != nil && !model.isBusy)
        bus.canDownloadSelection = model.canDownloadSelection(entries)
        bus.downloadSelectionTitle = entries.count == 1 ? (entries[0].isDirectory ? "下载所选文件夹…" : "下载所选文件…") : "下载所选项目…"
    }

    private func openSelectedFolder() {
        guard let folder = selectedFolder, !model.isBusy else { return }
        model.enter(folder)
    }

    private func chooseDownload(_ entries: [RemoteEntry]) {
        guard let context = model.captureDownloadSelection(entries),
              let route = RemoteDirectorySelection.downloadRoute(entries) else { return }
        let ticket = DirectorySelectionTicket(revision: uiRevision, entries: entries)
        switch route {
        case .singleFile(let entry):
            let panel = NSSavePanel()
            panel.title = "下载文件"; panel.prompt = "保存"; panel.nameFieldStringValue = entry.name
            panel.canCreateDirectories = true
            panel.begin { response in
                guard response == .OK, let url = panel.url,
                      ticket.isCurrent(revision: uiRevision, entries: selectedRows),
                      model.isCurrentDownloadSelection(context) else { return }
                do {
                    let identity = try LocalDownload.identity(url)
                    model.downloadSelection(context, to: url, authorizedIdentity: identity)
                } catch { model.downloadSelectionFailed(error) }
            }
        case .collection:
            let panel = NSOpenPanel()
            panel.title = "选择下载保存目录"; panel.prompt = "选择目录"
            panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
            panel.begin { response in
                guard response == .OK, let url = panel.url,
                      ticket.isCurrent(revision: uiRevision, entries: selectedRows),
                      model.isCurrentDownloadSelection(context) else { return }
                model.downloadSelection(context, to: url)
            }
        }
    }

    private func setSort(_ column: DirectorySortColumn, ascending: Bool) {
        let key: KeyPath<DirectoryRow, String> = \.name
        switch column {
        case .name: sortOrder = [KeyPathComparator(key, order: ascending ? .forward : .reverse)]
        case .kind: sortOrder = [KeyPathComparator(\DirectoryRow.kindRank, order: ascending ? .forward : .reverse)]
        case .size: sortOrder = [KeyPathComparator(\DirectoryRow.sizeRank, order: ascending ? .forward : .reverse)]
        }
    }

    private var selectionBinding: Binding<Set<Data>> {
        Binding(get: { selectedEntries }, set: { ids in
            // Cache and selection move together; no event-delay window authorizes an old row.
            projection.select(ids)
            selectedEntries = projection.selectedIDs
            uiRevision &+= 1; nameEntry = nil; syncOpenAvailability()
        })
    }

    private var table: some View {
        Table(rows, selection: selectionBinding, sortOrder: $sortOrder) {
            TableColumn("名称", value: \.name) { row in
                DirectoryEntryCell(entry: row.entry,
                                   isSelected: selectedRow?.id == row.id,
                                   isBusy: model.isBusy,
                                   showInformation: { perform(.information) }) {
                    guard !model.isBusy, selectedFolder?.id == row.id else { return }
                    model.enter(row.entry)
                }
            }
            if showsKind {
                TableColumn("类型", value: \.kindRank) { row in
                    Text(row.kindTitle)
                        .font(.callout).foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .width(min: 56, ideal: 80, max: 160)
            }
            TableColumn("大小", value: \.sizeRank) { row in
                Text(DirectoryEntryCell.sizeText(row.entry))
                    .font(.callout.monospacedDigit()).foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .width(min: 64, ideal: 88, max: 180)
        }
        .contextMenu(forSelectionType: Data.self) { _ in
            selectionMenu
        } primaryAction: { ids in
            open(ids)
        }
        .frame(minHeight: 100)
    }

    private func open(_ ids: Set<Data>) {
        guard !model.isBusy, ids == selectedEntries, ids.count == 1, let id = ids.first,
              selectionIsCurrent, let row = projection.row(id: id), row.entry.isDirectory else { return }
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
            Text("\(projection.entries.count) / \(model.entries.count) 个项目")
            if !filterQuery.isEmpty { Label("筛选生效", systemImage: "line.3.horizontal.decrease.circle") }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.primary)
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

    private var feedback: DirectoryFeedback {
        DirectoryFeedback.resolve(loaded: model.entries.count, visible: projection.entries.count,
                                  isReading: model.isDirectoryLoading, hasError: model.directoryError != nil)
    }

    private var emptyState: some View {
        VStack(spacing: Metrics.spacing12) {
            if feedback == .reading {
                ProgressView().controlSize(.small)
                Text("正在读取目录").font(.headline)
                Text("保留已加载目录，等待读取结果。").font(.callout).foregroundStyle(.primary)
            } else if feedback == .failed {
                Label("目录读取失败", systemImage: "exclamationmark.circle").font(.headline)
                Text("原目录与筛选保留；可查看上方错误详情。").font(.callout).foregroundStyle(.primary)
            } else if feedback == .noMatches {
                Label("没有匹配项目", systemImage: "line.3.horizontal.decrease.circle").font(.headline)
                Text("仅筛选当前已加载项目，不搜索子目录。").font(.callout).foregroundStyle(.primary)
                Button("清除筛选") { filterQuery = ""; filterFocusRequest = UUID() }
            } else {
                Image(systemName: "folder")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor.opacity(0.7))
                Text("这个文件夹是空的").font(.headline)
                if model.selectedFile == nil && !model.isBusy {
                    Text("选择文件后，再明确开始上传。").font(.callout).foregroundStyle(.primary)
                }
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
    let showInformation: () -> Void
    let open: () -> Void

    static func sizeText(_ entry: RemoteEntry) -> String {
        entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
    }

    var body: some View {
        HStack(spacing: Metrics.spacing8) {
            interactiveName
            if isSelected {
                Button(action: showInformation) { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("查看完整名称（选中后 ⌘I）").accessibilityLabel("查看名称：\(entry.name)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .accessibilityLabel(entry.kindTitle + "：" + entry.name)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { if !isBusy { open() } }
        } else {
            name
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityLabel(entry.kindTitle + "：" + entry.name)
        }
    }

    private var name: some View {
        HStack(spacing: Metrics.spacing8) {
            Image(systemName: entry.kindSymbol)
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
            Text(entry.name).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
    }
}
