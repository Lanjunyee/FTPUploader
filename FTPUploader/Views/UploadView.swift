import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Window-owned commands and prompts survive when the activity bar is hidden.
@MainActor
struct UploadPresentationOwner: ViewModifier {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var bus: TransferCommandBus
    @State private var showFilePicker = false
    @State private var detail: Detail?

    private struct Detail: Identifiable {
        let id: String
        let title: String
        let text: String
    }

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.data],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if urls.count == 1 { model.selectFile(urls[0]) }
                case .failure(let error): model.fileSelectionFailed(error)
                }
            }
            .popover(item: $detail) { item in
                TextDetailsPopover(title: item.title, text: item.text) { detail = nil }
            }
            .alert("覆盖同名文件？", isPresented: Binding(
                get: { model.overwriteRequestID != nil },
                set: { presented in
                    if !presented, let id = model.overwriteRequestID { model.cancelOverwrite(id) }
                })) {
                    if let id = model.overwriteRequestID {
                        Button("取消", role: .cancel) { model.cancelOverwrite(id) }
                            .keyboardShortcut(.defaultAction)
                        Button("仅本次覆盖", role: .destructive) { model.confirmOverwrite(id) }
                    }
                } message: {
                    Text("目标：\(model.overwriteTarget ?? "")\n目标已有同名普通文件。仅授权本次上传；检查无法防止服务器并发变化，服务器仍可能拒绝写入。")
                }
            .onChange(of: bus.request) { request in handle(request) }
            .onChange(of: model.pendingTarget) { _ in detail = nil }
            .onChange(of: model.selectedFile?.name) { _ in detail = nil }
            .onChange(of: model.selectionError) { _ in detail = nil }
            .onChange(of: model.uploadState) { state in
                detail = nil
                announce(state)
            }
    }

    private func handle(_ request: TransferCommandBus.Request?) {
        switch request {
        case .chooseFile:
            guard model.canChooseFile else { bus.clear(.chooseFile); return }
            showFilePicker = true
        case .showSelectedFileName:
            if let file = model.selectedFile {
                detail = Detail(id: "file", title: "所选文件", text: file.name)
            }
        case .showTarget:
            if let target = model.isUploading ? (model.uploadTarget ?? model.pendingTarget) : model.pendingTarget {
                detail = Detail(id: "target", title: "完整上传目标", text: target)
            }
        case .showResult:
            if let target = model.uploadTarget {
                detail = Detail(id: "result", title: "本次上传结果的目标", text: target)
            }
        case .showUploadError:
            if let error = model.selectionError {
                detail = Detail(id: "error", title: "文件选择错误", text: error)
            } else if case .failed(let error) = model.uploadState {
                detail = Detail(id: "error", title: "错误详情", text: error)
            }
        default: return
        }
        if let request { bus.clear(request) }
    }

    private func announce(_ state: UploadState) {
        let message: String
        switch state {
        case .checkingTarget: message = "正在检查上传目标"
        case .awaitingOverwrite: message = "目标存在同名文件，等待本次覆盖确认"
        case .uploading: message = "正在上传"
        case .awaitingCompletion: message = "等待服务器确认"
        case .cancelling: message = "正在取消，等待资源释放"
        case .cancelled: message = "上传已取消，远程可能存在部分或完整文件，请核对目标。"
        case .succeeded: message = "上传成功"
        case .failed: message = "未能确认上传成功，远程可能存在部分文件，请核对后再操作。"
        case .idle: return
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// Keep Finder's original URL so the existing selection code can use the
/// sandbox access granted by the drag. Receiving a drop never starts an upload.
@MainActor
struct FileDropTarget: ViewModifier {
    @ObservedObject var model: AppModel
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted && model.canChooseFile {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                guard model.canChooseFile else { return false }
                return model.receiveFileDrop(loaders: providers.map { provider in
                    {
                        try await withCheckedThrowingContinuation { continuation in
                            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                                if let error {
                                    continuation.resume(throwing: error)
                                } else if let url = item as? URL {
                                    continuation.resume(returning: url)
                                } else if let data = item as? Data,
                                          let url = URL(dataRepresentation: data, relativeTo: nil) {
                                    continuation.resume(returning: url)
                                } else {
                                    continuation.resume(throwing: FTPError.localFile("无法读取拖入的文件。"))
                                }
                            }
                        }
                    }
                })
            }
    }
}
