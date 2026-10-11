import AppKit
import SwiftUI

/// Native field-editor commands stay local to this field and its owning window.
@MainActor
struct DirectoryFilterField: NSViewRepresentable {
    @Binding var query: String
    let focusRequest: UUID
    let onEscape: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "文件名（仅已加载项目）"
        field.isEditable = true
        field.isContinuous = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = .preferredFont(forTextStyle: .callout)
        field.setAccessibilityLabel("当前目录文件名筛选")
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if field.stringValue != query {
            field.stringValue = query
            field.currentEditor()?.string = query
        }
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window, window.isKeyWindow,
                      window.attachedSheet == nil else { return }
                window.makeFirstResponder(field)
            }
        }
    }
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        field.delegate = nil
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DirectoryFilterField
        var focusRequest: UUID?
        init(_ parent: DirectoryFilterField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.query = field.currentEditor()?.string ?? field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.query = textView.string
                return true // Consume Return; never invoke the window default action.
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape(textView.string)
                return true
            }
            return false
        }
    }
}
