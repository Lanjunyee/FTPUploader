import AppKit
import SwiftUI

/// Keep the document in the parent's SwiftUI tree. The background NSView only
/// observes this window's keys while the list (or its root buttons) has focus.
@MainActor
struct KeyboardPlanScrollView<Content: View>: View {
    var active = false
    var canScroll = true
    var onCancel: () -> Void
    var onTraverse: ((Bool) -> Void)? = nil
    var accessibilityName = "完整传输计划清单"
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            content().background(PlanKeyCapture(active: active, canScroll: canScroll,
                                                onCancel: onCancel, onTraverse: onTraverse))
        }
        .focusable()
        .accessibilityLabel(accessibilityName)
        .accessibilityHint("上下方向键滚动，Page Up/Down 翻页，Home/End 到达首尾；Tab 离开清单。")
        .overlay(RoundedRectangle(cornerRadius: 3)
            .stroke(active && canScroll ? Color.accentColor : .clear, lineWidth: 2)
            .allowsHitTesting(false))
        .padding(2)
    }
}

/// Every path consumes its full wrapped height, never a truncation slot.
struct PlanPathText: View {
    let text: String
    var body: some View {
        Text(text).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private struct PlanKeyCapture: NSViewRepresentable {
    let active: Bool
    let canScroll: Bool
    let onCancel: () -> Void
    let onTraverse: ((Bool) -> Void)?
    func makeNSView(context: Context) -> PlanScrollKeyView {
        let view = PlanScrollKeyView()
        configure(view)
        return view
    }
    func updateNSView(_ view: PlanScrollKeyView, context: Context) { configure(view) }
    private func configure(_ view: PlanScrollKeyView) {
        view.active = active; view.canScroll = canScroll
        view.onCancel = onCancel; view.onTraverse = onTraverse
    }
    static func dismantleNSView(_ view: PlanScrollKeyView, coordinator: ()) { view.stopMonitoring() }
}

@MainActor
final class PlanScrollKeyView: NSView {
    var active = false
    var canScroll = true
    var onCancel: (() -> Void)?
    var onTraverse: ((Bool) -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window,
                  event.window === window || NSApp.keyWindow === window else { return event }
            return self.handleKey(event) ? nil : event
        }
    }
    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
    /// Return true only for list navigation. Other controls and windows keep
    /// their native key handling; no global monitor or accessibility permission.
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        guard active else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift, let onTraverse {
            onTraverse(modifiers.isEmpty)
            return true
        }
        if event.keyCode == 53, modifiers.isEmpty, let onCancel { onCancel(); return true }
        guard canScroll,
              modifiers.isEmpty || (modifiers == .command && [125, 126].contains(event.keyCode)),
              let scroll = enclosingScrollView, let document = scroll.documentView else { return false }
        let visible = scroll.contentView.bounds
        let minimum = document.bounds.minY
        let maximum = max(minimum, document.bounds.maxY - visible.height)
        let top = document.isFlipped ? minimum : maximum
        let bottom = document.isFlipped ? maximum : minimum
        let sign: CGFloat = document.isFlipped ? 1 : -1
        let page = max(1, visible.height - 24)
        var y = visible.origin.y
        switch event.keyCode {
        case 125: y = modifiers == .command ? bottom : y + sign * 40
        case 126: y = modifiers == .command ? top : y - sign * 40
        case 121: y += sign * page
        case 116: y -= sign * page
        case 115: y = top
        case 119: y = bottom
        default: return false
        }
        scroll.contentView.scroll(to: NSPoint(x: visible.origin.x, y: min(maximum, max(minimum, y))))
        scroll.reflectScrolledClipView(scroll.contentView)
        return true
    }
}
