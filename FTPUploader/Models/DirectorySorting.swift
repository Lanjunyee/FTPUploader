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
