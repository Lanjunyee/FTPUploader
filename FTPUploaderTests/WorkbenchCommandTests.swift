import AppKit
import SwiftUI
import XCTest

@MainActor
final class WorkbenchCommandTests: XCTestCase {
    private struct AXControl {
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
            result.append(AXControl(role: value(object, "accessibilityRole") as? String,
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
