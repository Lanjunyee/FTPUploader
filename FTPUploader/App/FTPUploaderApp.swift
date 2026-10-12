import SwiftUI
import AppKit

@MainActor
final class HistoryApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var history: TransferHistory?
    private let termination = HistoryTerminationCoordinator()
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let history else { return .terminateNow }
        termination.requestExit(history: history, onFailure: { error in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "传输记录尚未保存"
            alert.informativeText = error.localizedDescription + "\n传输结果未改变。可取消退出后重试本机保存；仍然退出会丢失待保存记录。"
            alert.addButton(withTitle: "取消退出")
            alert.addButton(withTitle: "仍然退出")
            return alert.runModal() == .alertSecondButtonReturn
        }, reply: { sender.reply(toApplicationShouldTerminate: $0) })
        return .terminateLater
    }
}

@main
@MainActor
struct FTPUploaderApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var bus = TransferCommandBus()
    @NSApplicationDelegateAdaptor(HistoryApplicationDelegate.self) private var delegate

    var body: some Scene {
        Window("FTP 文件传输", id: "main") {
            ContentView(model: model)
                .environmentObject(bus)
                .onAppear { delegate.history = model.history }
        }
        .defaultSize(width: Metrics.defaultWindowWidth, height: Metrics.defaultWindowHeight)
        .windowResizability(.contentMinSize)
        .commands { TransferCommands(model: model, bus: bus) }

        Settings {
            SiteManagementView(model: model)
                .onAppear { delegate.history = model.history }
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
            Button("展开／收起站点栏") { bus.send(.toggleSites) }
            Button("筛选当前目录…") { bus.send(.showFilter) }
                .keyboardShortcut("f", modifiers: .command).disabled(!model.hasDirectory)
            Button("文件信息／完整名称") { bus.send(.showDirectoryInfo) }
                .keyboardShortcut("i", modifiers: .command).disabled(!bus.canShowDirectoryInfo)
            Button("打开所选文件夹") { bus.send(.openSelectedFolder) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!bus.canOpenSelectedFolder)
            Button(bus.downloadSelectionTitle) { bus.send(.downloadSelectedItems) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!bus.canDownloadSelection)
            Divider()
            Button("选择文件…") { bus.send(.chooseFile) }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!model.canChooseFile)
            Button("上传文件/文件夹…") { bus.send(.chooseBatch) }
                .keyboardShortcut("b", modifiers: [.command, .shift]).disabled(!model.canPrepareCollection)
            Button("队列与记录…") { bus.send(.showTransfers) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("取消全部队列任务") { model.cancelAllTransfers() }
                .disabled(!model.canCancelAllTransfers)
            Button("重试原批次失败项…") { _ = model.prepareCollectionRetry() }
                .disabled(!model.canPrepareCollectionRetry())
            Button("上传到当前目录") { model.upload() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(!model.canUpload)
            let cancellationID = model.cancellationID
            Button("取消当前操作") {
                if let cancellationID { model.cancelOperation(id: cancellationID) }
            }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.canCancel)
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
