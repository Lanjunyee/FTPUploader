import SwiftUI

/// Presentation requests belong to the current window, not the transfer model.
@MainActor
final class TransferCommandBus: ObservableObject {
    enum Request: String, Equatable {
        case chooseBatch, showTransfers, downloadSelectedItems, chooseFile
        case showPath, showSelectedFileName, showTarget, showResult
        case showDirectoryError, showUploadError, openSelectedFolder
        case showFilter, showDirectoryInfo, toggleSites
    }
    @Published var request: Request?
    @Published private(set) var canOpenSelectedFolder = false
    @Published var canDownloadSelection = false
    @Published var downloadSelectionTitle = "下载所选项目…"
    @Published var canShowDirectoryInfo = false

    func send(_ request: Request) { self.request = request }
    func setOpenAvailability(_ available: Bool) {
        if canOpenSelectedFolder != available { canOpenSelectedFolder = available }
    }
    func clear(_ handled: Request) {
        if request == handled { request = nil }
    }
}

struct WorkbenchIconMenu<Items: View>: View {
    let title: String
    let symbol: String
    let help: String
    var enabled = true
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu(content: items) {
            Label(title, systemImage: symbol).accessibilityLabel(title)
        }
        .labelStyle(.iconOnly).help(help).disabled(!enabled)
        .accessibilityRepresentation {
            Menu(title, content: items).help(help).disabled(!enabled)
        }
    }
}

/// Shared native icon control, including its event-time availability guard.
struct WorkbenchIconButton: View {
    let title: String
    let symbol: String
    let help: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button { if enabled { action() } } label: { Label(title, systemImage: symbol) }
            .labelStyle(.iconOnly)
            .help(help)
            .accessibilityLabel(title)
            .disabled(!enabled)
    }
}
