import CoreGraphics

/// Spacing and corner scale for the transfer window.
/// Layout spacing uses only these values so the window keeps a single rhythm.
enum Metrics {
    static let spacing4: CGFloat = 4
    static let spacing8: CGFloat = 8
    static let spacing12: CGFloat = 12
    static let spacing16: CGFloat = 16
    static let spacing24: CGFloat = 24

    static let cornerRadius: CGFloat = 10

    static let minimumWindowWidth: CGFloat = 640
    static let minimumWindowHeight: CGFloat = 440
    static let defaultWindowWidth: CGFloat = 820
    static let defaultWindowHeight: CGFloat = 600

    static let formMaxWidth: CGFloat = 460
    static let detailsPopoverWidth: CGFloat = 440
    static let detailsPopoverMaxHeight: CGFloat = 220
}
