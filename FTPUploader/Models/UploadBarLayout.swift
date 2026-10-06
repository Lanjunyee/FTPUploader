import Foundation

/// Which rows the bottom upload bar shows.
///
/// Kept as a pure function so all four layouts are unit tested without a window:
/// not connected 0, connected with no file 1, file chosen and idle 2,
/// transferring or finished 3.
enum UploadBarLayout {
    struct Rows: Equatable {
        var isVisible: Bool
        var showsTarget: Bool
        var showsStatus: Bool

        /// The file slot is always the first row when the bar is visible.
        var count: Int { isVisible ? 1 + (showsTarget ? 1 : 0) + (showsStatus ? 1 : 0) : 0 }
    }

    static func rows(isConnected: Bool,
                     hasSelectedFile: Bool,
                     isIdle: Bool,
                     hasSelectionError: Bool) -> Rows {
        guard isConnected else { return Rows(isVisible: false, showsTarget: false, showsStatus: false) }
        return Rows(isVisible: true,
                    showsTarget: hasSelectedFile,
                    showsStatus: !isIdle || hasSelectionError)
    }

    static func rowCount(isConnected: Bool,
                         hasSelectedFile: Bool,
                         isIdle: Bool,
                         hasSelectionError: Bool) -> Int {
        rows(isConnected: isConnected,
             hasSelectedFile: hasSelectedFile,
             isIdle: isIdle,
             hasSelectionError: hasSelectionError).count
    }
}
