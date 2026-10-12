import AppKit
import SwiftUI
import XCTest

@MainActor
final class WorkbenchCommandTests: XCTestCase {
    private struct AXControl {
        let object: NSObject
        let frame: NSRect
        let role: String?
        let label: String?
        let title: String?
        let value: String?
        let enabled: Bool?
    }
    private func elements(_ root: Any) -> [AXControl] {
        var result: [AXControl] = [], visited = Set<ObjectIdentifier>()
        func value(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        func walk(_ node: Any) {
            guard let object = node as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted else { return }
            let selector = NSSelectorFromString("isAccessibilityEnabled")
            var enabled: Bool?
            if object.responds(to: selector) {
                typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
                enabled = unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
            }
            let frameSelector = NSSelectorFromString("accessibilityFrame")
            var frame = NSRect.zero
            if object.responds(to: frameSelector) {
                typealias FrameGetter = @convention(c) (AnyObject, Selector) -> NSRect
                frame = unsafeBitCast(object.method(for: frameSelector), to: FrameGetter.self)(object, frameSelector)
            }
            result.append(AXControl(object: object, frame: frame, role: value(object, "accessibilityRole") as? String,
                                    label: value(object, "accessibilityLabel") as? String,
                                    title: value(object, "accessibilityTitle") as? String,
                                    value: value(object, "accessibilityValue") as? String, enabled: enabled))
            for child in value(object, "accessibilityChildren") as? [Any] ?? [] { walk(child) }
        }
        walk(root)
        return result
    }

    func testHostedIconControlsExposeChineseNamesAndDisabledState() async throws {
        _ = NSApplication.shared
        let setter = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        let getter = NSSelectorFromString("accessibilityAttributeValue:")
        let previous = NSApp.perform(getter, with: "AXEnhancedUserInterface")?.takeUnretainedValue()
        _ = NSApp.perform(setter, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        defer { _ = NSApp.perform(setter, with: previous ?? NSNumber(value: false), with: "AXEnhancedUserInterface") }
        for enabled in [true, false] {
            let content = VStack {
                ForEach(["上一级", "刷新", "下载", "筛选", "队列与记录"], id: \.self) { title in
                    WorkbenchIconButton(title: title, symbol: "circle", help: title, enabled: enabled) {}
                }
                WorkbenchIconMenu(title: "上传", symbol: "doc.badge.arrow.up", help: "上传", enabled: enabled) {
                    Button("选择单个文件…") {}
                }
                WorkbenchIconMenu(title: "更多", symbol: "ellipsis.circle", help: "更多", enabled: enabled) {
                    Button("刷新") {}
                }
            }
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(nanoseconds: 50_000_000)
            host.layoutSubtreeIfNeeded()
            let controls = elements(host)
            for title in ["上一级", "刷新", "上传", "下载", "筛选", "队列与记录", "更多"] {
                let matches = controls.filter {
                    $0.label == title || $0.title == title || $0.value == title
                }
                XCTAssertFalse(matches.isEmpty, "Missing AX name: \(title)")
                XCTAssertTrue(matches.contains { $0.enabled == enabled }, "Wrong availability: \(title)")
            }
        }
    }

    func testHostedSummaryKeepsRiskWarningsVisibleWithoutOpeningDetailsAtNarrowWidths() async throws {
        _ = NSApplication.shared
        let setter = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        let getter = NSSelectorFromString("accessibilityAttributeValue:")
        let previous = NSApp.perform(getter, with: "AXEnhancedUserInterface")?.takeUnretainedValue()
        _ = NSApp.perform(setter, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        defer { _ = NSApp.perform(setter, with: previous ?? NSNumber(value: false), with: "AXEnhancedUserInterface") }
        for width in [640.0, 820.0] {
            for phase in [TransferActivity.Phase.finalizing, .overwrite, .paused, .finished, .cancelling, .failed, .succeeded] {
                let warning = phase == .paused ? "批次失败暂停，等待明确处理。" :
                    (phase == .finished ? "已结束，不是全部成功。成功 2，失败 1，阻塞 3。" :
                        TransferActivity.warning(phase: phase, direction: .download, error: "552 rejected", cleanup: "/保存目录/临时文件清理失败")!)
                let activity = TransferActivity(source: .download, direction: .download, phase: phase,
                    name: "长中文文件名 % #.txt", target: "/实际保存目录", warning: warning)
                let host = NSHostingView(rootView: TransferActivitySummary(activity: activity) { Button("核对目标") {} })
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host; window.orderFront(nil)
                try await Task.sleep(nanoseconds: 30_000_000)
                host.layoutSubtreeIfNeeded()
                let controls = elements(host)
                XCTAssertTrue(controls.contains { $0.value == warning || $0.label == warning }, "Hidden risk at \(width): \(phase)")
                XCTAssertTrue(controls.contains { $0.title == "核对目标" || $0.label == "核对目标" }, "Details must remain explicitly reachable")
                window.close()
            }
        }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Hosted window did not reach expected state")
        throw FTPError.localFile("Hosted window wait timed out")
    }
    private func enableAX() -> () -> Void {
        _ = NSApplication.shared
        let setter = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        let getter = NSSelectorFromString("accessibilityAttributeValue:")
        let previous = NSApp.perform(getter, with: "AXEnhancedUserInterface")?.takeUnretainedValue()
        _ = NSApp.perform(setter, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        return { _ = NSApp.perform(setter, with: previous ?? NSNumber(value: false), with: "AXEnhancedUserInterface") }
    }
    private func hostMain(_ model: AppModel, bus: TransferCommandBus, appearance: NSAppearance.Name) -> NSWindow {
        let controller = NSHostingController(rootView: ContentView(model: model).environmentObject(bus))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Metrics.minimumWindowWidth, height: Metrics.minimumWindowHeight),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        return window
    }
    private func press(_ control: AXControl) throws {
        if let button = control.object as? NSButton {
            XCTAssertTrue(button.isEnabled)
            button.performClick(nil)
            return
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(control.object.responds(to: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(control.object.method(for: selector), to: Press.self)(control.object, selector))
    }
    func testMinimumMainWindowLightAndDarkKeepRiskSummaryAndCancellationReachable() async throws {
        let restore = enableAX(); defer { restore() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let url = base.appendingPathComponent("中文 %.txt"); try Data("abcdef".utf8).write(to: url)
            let fake = ControlledFTP(), model = AppModel(client: fake, history: TransferHistory(url: base.appendingPathComponent("history.json")))
            model.address = "example.test"; model.connect(); try await waitFor { fake.browses.count == 1 }
            fake.browses[0].continuation.resume(returning: .init(entries: [], encoding: .utf8)); try await waitFor { model.hasDirectory }
            let bus = TransferCommandBus(), window = hostMain(model, bus: bus, appearance: appearance)
            defer { window.close() }
            model.selectFile(url); model.upload(); try await waitFor { fake.uploads.count == 1 }
            fake.uploads[0].progress(6, 6); try await waitFor { model.uploadState == .awaitingCompletion }
            try await Task.sleep(nanoseconds: 80_000_000); window.contentView?.layoutSubtreeIfNeeded()
            let controls = elements(window.contentView!), warning = try XCTUnwrap(TransferActivityObserver(model: model).activity?.warning)
            let visible = window.convertToScreen(window.contentView!.bounds)
            XCTAssertTrue(controls.contains { ($0.label == warning || $0.value == warning) && $0.frame.intersects(visible) })
            let cancel = try XCTUnwrap(controls.first { ($0.label == "取消当前" || $0.title == "取消当前") && $0.enabled == true })
            XCTAssertTrue(cancel.frame.intersects(visible))
            try press(cancel)
            XCTAssertEqual(model.uploadState, .cancelling)
            fake.uploads[0].continuation.resume(throwing: CancellationError()); try await waitFor { !model.isBusy }
            try await Task.sleep(nanoseconds: 50_000_000); window.contentView?.layoutSubtreeIfNeeded()
            let cancelledWarning = try XCTUnwrap(TransferActivityObserver(model: model).activity?.warning)
            XCTAssertTrue(elements(window.contentView!).contains { ($0.label == cancelledWarning || $0.value == cancelledWarning) && $0.frame.intersects(visible) })
            XCTAssertEqual(fake.uploads.count, 1); XCTAssertEqual(fake.browses.count, 1)
        }
    }
    func testMinimumMainWindowOverwriteDefaultsToCancelInBothAppearances() async throws {
        let restore = enableAX(); defer { restore() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let url = base.appendingPathComponent("existing.txt"); try Data("abc".utf8).write(to: url)
            let fake = ControlledFTP(); fake.autoCheckTargets = false
            let model = AppModel(client: fake, history: TransferHistory(url: base.appendingPathComponent("history.json")))
            model.address = "example.test"; model.connect(); try await waitFor { fake.browses.count == 1 }
            fake.browses[0].continuation.resume(returning: .init(entries: [], encoding: .utf8)); try await waitFor { model.hasDirectory }
            let window = hostMain(model, bus: TransferCommandBus(), appearance: appearance); defer { window.close() }
            model.selectFile(url); model.upload(); try await waitFor { fake.browses.count == 2 }
            fake.browses[1].continuation.resume(returning: .init(entries: [.init(name: url.lastPathComponent, rawName: Data(url.lastPathComponent.utf8), isDirectory: false, size: 3)], encoding: .utf8))
            try await waitFor { model.overwriteRequestID != nil && window.attachedSheet != nil }
            let id = try XCTUnwrap(model.overwriteRequestID), sheet = try XCTUnwrap(window.attachedSheet)
            try await Task.sleep(nanoseconds: 300_000_000); sheet.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(sheet.defaultButtonCell?.title, "取消")
            let cancel = try XCTUnwrap(elements(sheet.contentView!).first {
                $0.role == NSAccessibility.Role.button.rawValue && ($0.label == "取消" || $0.title == "取消")
            })
            XCTAssertTrue(cancel.enabled == true)
            // AppKit exposes an AX proxy for alert buttons. Activate the actual default
            // NSButton, then verify the model effect instead of trusting a proxy return value.
            let defaultButton = try XCTUnwrap(sheet.defaultButtonCell?.controlView as? NSButton)
            XCTAssertTrue(defaultButton.isEnabled)
            defaultButton.performClick(nil); try await waitFor { !model.isBusy }
            model.confirmOverwrite(id)
            XCTAssertEqual(model.uploadState, .cancelled); XCTAssertTrue(fake.uploads.isEmpty)
        }
    }
    func testMainWindowDetailsDismissWhenSameNameSelectionObjectChangesInBothAppearances() async throws {
        let restore = enableAX(); defer { restore() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let url = base.appendingPathComponent("same-name.txt"); try Data("abc".utf8).write(to: url)
            let fake = ControlledFTP(), model = AppModel(client: fake, history: TransferHistory(url: base.appendingPathComponent("history.json")))
            model.address = "example.test"; model.connect(); try await waitFor { fake.browses.count == 1 }
            fake.browses[0].continuation.resume(returning: .init(entries: [], encoding: .utf8)); try await waitFor { model.hasDirectory }
            let bus = TransferCommandBus(), window = hostMain(model, bus: bus, appearance: appearance); defer { window.close() }
            model.selectFile(url); try await Task.sleep(nanoseconds: 80_000_000)
            let original = try XCTUnwrap(model.selectedFile), target = try XCTUnwrap(model.pendingTarget)
            func popoverControls() -> [AXControl] {
                NSApp.windows.filter { $0.isVisible && $0 !== window }.flatMap { $0.contentView.map { elements($0) } ?? [] }
            }
            bus.send(.showTarget)
            try await waitFor { popoverControls().contains { $0.value == "完整上传目标" || $0.label == "完整上传目标" } }
            let details = popoverControls()
            XCTAssertTrue(details.contains { $0.value == target || $0.label == target })
            for title in ["复制", "关闭"] {
                XCTAssertTrue(details.contains { ($0.title == title || $0.label == title) && $0.enabled == true })
            }
            model.selectFile(url)
            XCTAssertFalse(model.selectedFile === original); XCTAssertEqual(model.pendingTarget, target)
            try await waitFor { !popoverControls().contains { $0.value == "完整上传目标" || $0.label == "完整上传目标" } }
            XCTAssertEqual(fake.browses.count, 1); XCTAssertTrue(fake.uploads.isEmpty)
        }
    }
    func testNativeFilterDelegatePublishesContinuousInputAndConsumesOnlyLocalCommands() {
        var query = "", escaped: [String] = []
        let fieldView = DirectoryFilterField(query: Binding(get: { query }, set: { query = $0 }),
                                            focusRequest: UUID(), onEscape: { escaped.append($0) })
        let delegate = fieldView.makeCoordinator()
        let field = NSTextField(), editor = NSTextView()
        field.stringValue = "中文 %.TXT#"
        delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(query, "中文 %.TXT#")
        editor.string = "最新输入"
        XCTAssertTrue(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(query, "最新输入")
        XCTAssertTrue(escaped.isEmpty)
        XCTAssertTrue(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        editor.string = ""
        XCTAssertTrue(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(escaped, ["最新输入", ""])
        XCTAssertFalse(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
    }

    func testPresentationRequestsStayDistinctAndOnlyMatchingReceiverClears() {
        let bus = TransferCommandBus()
        for request in [TransferCommandBus.Request.chooseFile, .chooseBatch, .showFilter,
                        .showDirectoryInfo, .showTransfers, .toggleSites, .openSelectedFolder, .downloadSelectedItems] {
            bus.send(request)
            XCTAssertEqual(bus.request, request)
            bus.clear(.showUploadError)
            XCTAssertEqual(bus.request, request)
            bus.clear(request)
            XCTAssertNil(bus.request)
        }
        bus.setOpenAvailability(true)
        XCTAssertTrue(bus.canOpenSelectedFolder)
        bus.setOpenAvailability(false)
        XCTAssertFalse(bus.canOpenSelectedFolder)
    }
}
