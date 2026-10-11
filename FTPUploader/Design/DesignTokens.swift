import AppKit
import CoreGraphics

/// Keep the system accent fill, choosing readable text instead of assuming white.
enum WorkbenchAccentContrast {
    static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    static func usesWhiteText(red: Double, green: Double, blue: Double) -> Bool {
        let background = luminance(red: red, green: green, blue: blue)
        return 1.05 / (background + 0.05) >= (background + 0.05) / 0.05
    }

    @MainActor static let foreground = NSColor(name: nil) { appearance in
        var foreground = NSColor.controlTextColor
        appearance.performAsCurrentDrawingAppearance {
            if let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
                foreground = usesWhiteText(red: accent.redComponent, green: accent.greenComponent,
                                          blue: accent.blueComponent) ? .white : .black
            }
        }
        return foreground
    }
}

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
