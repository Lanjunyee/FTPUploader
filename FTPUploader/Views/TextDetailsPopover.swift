import AppKit
import SwiftUI

/// The single shared "read the full text and copy it" popover.
/// Replaces the three near-identical copies that lived in the connection,
/// directory and upload views.
@MainActor
struct TextDetailsPopover: View {
    let title: String
    let text: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            Text(title).font(.headline)
            ScrollView {
                Text(text).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Metrics.detailsPopoverMaxHeight)
            HStack {
                Button("复制") { copyToPasteboard() }
                    .keyboardShortcut("c", modifiers: .command)
                    .help("复制全文（⌘C）")
                Spacer()
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(Metrics.spacing16)
        .frame(width: Metrics.detailsPopoverWidth)
    }

    private func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
