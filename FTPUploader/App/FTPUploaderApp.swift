import SwiftUI

/// Carries menu-command requests to the views that own the presentation state
/// (popovers, the file importer). Keeps that state out of `AppModel`, which stays a
/// transfer model only.
@MainActor
final class TransferCommandBus: ObservableObject {
    enum Request: String, Equatable {
        case chooseFile
        case showPath, showSelectedFileName, showTarget, showResult
        case showDirectoryError, showUploadError
        case openSelectedFolder
    }

    @Published var request: Request?
    /// Mirrors whether the directory table currently has an openable folder
    /// selected, so the menu command cannot fire without a valid target.
    @Published private(set) var canOpenSelectedFolder = false

    func send(_ request: Request) { self.request = request }

    func setOpenAvailability(_ available: Bool) {
        if canOpenSelectedFolder != available { canOpenSelectedFolder = available }
    }

    /// Called by the receiving view once it has handled the request.
    func clear(_ handled: Request) {
        if request == handled { request = nil }
    }
}

@main
struct FTPUploaderApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var bus = TransferCommandBus()

    var body: some Scene {
        Window("FTP 文件传输", id: "main") {
            ContentView(model: model)
                .environmentObject(bus)
        }
        .defaultSize(width: Metrics.defaultWindowWidth, height: Metrics.defaultWindowHeight)
        .windowResizability(.contentMinSize)
        .commands { TransferCommands(model: model, bus: bus) }

        Settings {
            SiteManagementView(model: model)
        }
    }
}

/// The transfer menu. Shortcuts live here only: the matching view buttons keep their
/// help text but no longer own a key equivalent, so nothing fires twice.
struct TransferCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var bus: TransferCommandBus

    var body: some Commands {
        CommandMenu("传输") {
            Button("上一级") { model.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!canGoUp)
            Button("刷新") { model.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!canRefresh)
            Divider()
            Button("打开所选文件夹") { bus.send(.openSelectedFolder) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!bus.canOpenSelectedFolder)
            Divider()
            Button("选择文件…") { bus.send(.chooseFile) }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!model.canChooseFile)
            Button("上传到当前目录") { model.upload() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(!model.canUpload)
            Divider()
            Button("查看完整路径") { bus.send(.showPath) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!model.hasDirectory)
            Button("查看所选文件完整名称") { bus.send(.showSelectedFileName) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(model.selectedFile == nil)
            Button("查看完整目标") { bus.send(.showTarget) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(activeTarget == nil)
            Button("查看本次结果目标") { bus.send(.showResult) }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                .disabled(model.uploadTarget == nil)
            Divider()
            Button("查看目录错误详情") { bus.send(.showDirectoryError) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.directoryError == nil)
            Button("查看上传错误详情") { bus.send(.showUploadError) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(uploadError == nil)
        }
    }

    private var canGoUp: Bool {
        model.hasDirectory && model.path.parent != nil && !model.isBusy
    }

    private var canRefresh: Bool {
        model.endpoint != nil && !model.isBusy
    }

    private var activeTarget: String? {
        model.isUploading ? (model.uploadTarget ?? model.pendingTarget) : model.pendingTarget
    }

    private var uploadError: String? {
        if let error = model.selectionError { return error }
        if case .failed(let error) = model.uploadState { return error }
        return nil
    }
}
