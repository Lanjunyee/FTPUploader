import Foundation

/// Columns the directory table can be sorted by.
enum DirectorySortColumn: String, CaseIterable, Identifiable {
    case kind, name, size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kind: return "类型"
        case .name: return "名称"
        case .size: return "大小"
        }
    }
}

/// Directory ordering rules.
///
/// Kept pure so they can be unit tested without a window, and shared with the
/// table columns' sort keys so the view and the tests cannot drift apart:
/// directories rank before files, and an unknown size ranks after every known size.
enum DirectorySorting {
    static func kindRank(isDirectory: Bool) -> Int { isDirectory ? 0 : 1 }

    static func sizeRank(_ size: Int64?) -> Int64 { size ?? Int64.max }

    static func sorted(_ entries: [RemoteEntry],
                       by column: DirectorySortColumn,
                       ascending: Bool) -> [RemoteEntry] {
        entries.sorted { lhs, rhs in
            ascending ? precedes(lhs, rhs, by: column) : precedes(rhs, lhs, by: column)
        }
    }

    private static func precedes(_ lhs: RemoteEntry, _ rhs: RemoteEntry, by column: DirectorySortColumn) -> Bool {
        switch column {
        case .name:
            return ordered(lhs, rhs)
        case .kind:
            let left = kindRank(isDirectory: lhs.isDirectory)
            let right = kindRank(isDirectory: rhs.isDirectory)
            return left == right ? ordered(lhs, rhs) : left < right
        case .size:
            let left = sizeRank(lhs.size)
            let right = sizeRank(rhs.size)
            return left == right ? ordered(lhs, rhs) : left < right
        }
    }

    private static func ordered(_ lhs: RemoteEntry, _ rhs: RemoteEntry) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

/// Pure local projection; never rebuilds entries or remote identity from display text.
enum DirectoryFiltering {
    struct Projection {
        let entries: [RemoteEntry]
        let selectedIDs: Set<Data>
        var selectedEntries: [RemoteEntry] {
            RemoteDirectorySelection.selected(in: entries, ids: selectedIDs)
        }
        var folderToOpen: RemoteEntry? { RemoteDirectorySelection.uniqueFolder(selectedEntries) }
        var downloadRoute: RemoteDirectorySelection.DownloadRoute? {
            RemoteDirectorySelection.downloadRoute(selectedEntries)
        }
    }

    static func project(_ entries: [RemoteEntry], query: String,
                        sort: DirectorySortColumn, ascending: Bool,
                        selectedIDs: Set<Data>) -> Projection {
        let visible = DirectorySorting.sorted(filtered(entries, query: query), by: sort, ascending: ascending)
        return Projection(entries: visible, selectedIDs: selectedIDs.intersection(Set(visible.map(\.id))))
    }

    static func filtered(_ entries: [RemoteEntry], query: String) -> [RemoteEntry] {
        guard !query.isEmpty else { return entries }
        let needle = query.precomposedStringWithCanonicalMapping
        return entries.filter {
            $0.name.precomposedStringWithCanonicalMapping.range(
                of: needle, options: [.caseInsensitive, .literal],
                locale: Locale(identifier: "en_US_POSIX")) != nil
        }
    }
}

struct DirectoryContext: Equatable {
    let identity: FTPIdentity
    let path: RemotePath
}

struct DirectorySelectionTicket {
    let revision: UInt64
    let entries: [RemoteEntry]
    func isCurrent(revision: UInt64, entries: [RemoteEntry]) -> Bool {
        self.revision == revision && self.entries == entries && !entries.isEmpty
    }
}

/// Pure lifetime rule; refresh generations are deliberately not part of context.
enum DirectoryFilterLifetime {
    static func shouldReset(from old: DirectoryContext?, to new: DirectoryContext?) -> Bool { old != new }
}

enum DirectoryFeedback: Equatable {
    case reading, failed, empty, noMatches, ready
    static func resolve(loaded: Int, visible: Int, isReading: Bool, hasError: Bool) -> Self {
        if isReading { return .reading }
        if hasError { return .failed }
        if loaded == 0 { return .empty }
        return visible == 0 ? .noMatches : .ready
    }
}

struct DirectoryRow: Identifiable {
    let entry: RemoteEntry
    let location: String
    var id: Data { entry.id }
    var name: String { entry.name }
    var kindRank: Int { DirectorySorting.kindRank(isDirectory: entry.isDirectory) }
    var sizeRank: Int64 { DirectorySorting.sizeRank(entry.size) }
    var kindTitle: String { entry.kindTitle }
}

/// Window-local event projection. Revision-based callers never compare the full listing on redraw.
struct DirectoryProjectionCache {
    private struct Input: Equatable {
        let entries: [RemoteEntry]?
        let generation: UInt64?
        let location: String
        let query: String
        let sort: DirectorySortColumn
        let ascending: Bool
    }
    private var input: Input?
    private var visibleIDs = Set<Data>()
    private var rowsByID: [Data: DirectoryRow] = [:]
    private var selectionRevision = -1
    private(set) var entries: [RemoteEntry] = []
    private(set) var rows: [DirectoryRow] = []
    private(set) var selectedIDs = Set<Data>()
    private(set) var selectedEntries: [RemoteEntry] = []
    private var selectionActions: [RemoteDirectorySelection.ActionItem] = []
    private(set) var projectionCount = 0
    private(set) var rowProjectionCount = 0
    private(set) var selectionProjectionCount = 0
    private(set) var selectionTraversalCount = 0
    var selectedRow: DirectoryRow? { selectedEntries.count == 1 ? rowsByID[selectedEntries[0].id] : nil }
    func row(id: Data) -> DirectoryRow? { rowsByID[id] }
    func actions(isBusy: Bool) -> [RemoteDirectorySelection.ActionItem] {
        selectionActions.map { .init(id: $0.id, title: $0.title, enabled: $0.id == .information || !isBusy) }
    }

    mutating func update(_ loaded: [RemoteEntry], query: String,
                         sort: DirectorySortColumn, ascending: Bool, generation: UInt64? = nil, location: String = "") {
        let next = Input(entries: generation == nil ? loaded : nil, generation: generation, location: location,
            query: query, sort: sort, ascending: ascending)
        guard input != next else { return }
        entries = DirectorySorting.sorted(DirectoryFiltering.filtered(loaded, query: query), by: sort, ascending: ascending)
        rows = entries.map { DirectoryRow(entry: $0, location: location) }
        rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        visibleIDs = Set(rowsByID.keys)
        input = next
        projectionCount += 1; rowProjectionCount += 1
        select(selectedIDs)
    }
    mutating func select(_ ids: Set<Data>) {
        let current = ids.intersection(visibleIDs)
        guard current != selectedIDs || selectionRevision != projectionCount else { return }
        selectedIDs = current; selectionRevision = projectionCount; selectionProjectionCount += 1
        if current.isEmpty { selectedEntries = []; selectionActions = []; return }
        selectionTraversalCount += entries.count
        let selected = entries.filter { current.contains($0.id) }
        selectedEntries = selected.count == current.count ? selected : []
        selectionActions = RemoteDirectorySelection.actions(for: selectedEntries, isBusy: false)
    }
    func isCurrent(_ loaded: [RemoteEntry], query: String,
                   sort: DirectorySortColumn, ascending: Bool, generation: UInt64? = nil, location: String = "") -> Bool {
        input == Input(entries: generation == nil ? loaded : nil, generation: generation, location: location,
            query: query, sort: sort, ascending: ascending)
    }
}

/// Read-only selection routing, shared by table/menu availability and model guards.
/// Selection and sorting themselves never schedule navigation or content requests.
enum RemoteDirectorySelection {
    enum Action: String, Identifiable {
        case openFolder, download, information
        var id: String { rawValue }
    }
    struct ActionItem: Identifiable, Equatable {
        let id: Action
        let title: String
        let enabled: Bool
    }
    static func actions(for entries: [RemoteEntry], isBusy: Bool) -> [ActionItem] {
        var items: [ActionItem] = []
        if uniqueFolder(entries) != nil {
            items.append(ActionItem(id: .openFolder, title: "打开所选文件夹", enabled: !isBusy))
        }
        if downloadRoute(entries) != nil {
            let title = entries.count == 1 ? (entries[0].isDirectory ? "下载文件夹…" : "下载文件…") : "下载所选项目…"
            items.append(ActionItem(id: .download, title: title, enabled: !isBusy))
        }
        if entries.count == 1 {
            items.append(ActionItem(id: .information, title: "文件信息／完整名称", enabled: true))
        }
        return items
    }

    enum DownloadRoute: Equatable {
        case singleFile(RemoteEntry)
        case collection([RemoteEntry])
    }
    static func selected(in orderedEntries: [RemoteEntry], ids: Set<Data>) -> [RemoteEntry] {
        let selected = orderedEntries.filter { ids.contains($0.id) }
        return selected.count == ids.count ? selected : []
    }
    static func uniqueFolder(_ entries: [RemoteEntry]) -> RemoteEntry? {
        entries.count == 1 && entries[0].kind == .directory ? entries[0] : nil
    }
    static func downloadRoute(_ entries: [RemoteEntry]) -> DownloadRoute? {
        guard !entries.isEmpty, entries.count <= TransferPlan.maximumNodes,
              Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ $0.kind == .regularFile || $0.kind == .directory }) else { return nil }
        if entries.count == 1, entries[0].kind == .regularFile { return .singleFile(entries[0]) }
        return .collection(entries)
    }
}
