import AppKit
import SwiftUI
import XCTest

@MainActor
final class KeyboardPlanScrollViewTests: XCTestCase {
    private final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }
    private func scroll(height: CGFloat = 1600) -> (NSScrollView, PlanScrollKeyView) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 400, height: height))
        let keys = PlanScrollKeyView(frame: NSRect(x: 0, y: 0, width: 400, height: height))
        keys.active = true
        document.addSubview(keys)
        scroll.documentView = document
        scroll.layoutSubtreeIfNeeded()
        return (scroll, keys)
    }
    private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                        timestamp: 0, windowNumber: 0, context: nil, characters: "",
                        charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }
    func testArrowPageAndBoundaryKeysScrollWithoutOvershooting() {
        let (view, keys) = scroll()
        XCTAssertTrue(keys.handleKey(key(125)))
        XCTAssertEqual(view.contentView.bounds.minY, 40, accuracy: 1)
        XCTAssertTrue(keys.handleKey(key(121)))
        XCTAssertGreaterThan(view.contentView.bounds.minY, 40)
        keys.handleKey(key(116))
        XCTAssertEqual(view.contentView.bounds.minY, 40, accuracy: 1)
        keys.handleKey(key(119))
        XCTAssertEqual(view.contentView.bounds.minY, 1400, accuracy: 1)
        keys.handleKey(key(125))
        XCTAssertEqual(view.contentView.bounds.minY, 1400, accuracy: 1)
        keys.handleKey(key(115))
        keys.handleKey(key(126))
        XCTAssertEqual(view.contentView.bounds.minY, 0, accuracy: 1)
        keys.handleKey(key(125, modifiers: .command))
        XCTAssertEqual(view.contentView.bounds.minY, 1400, accuracy: 1)
        keys.handleKey(key(126, modifiers: .command))
        XCTAssertEqual(view.contentView.bounds.minY, 0, accuracy: 1)
    }
    func testShortDocumentAndEscapeDoNotWriteOrScrollBeyondContent() {
        let (view, keys) = scroll(height: 100)
        var cancellations = 0
        keys.onCancel = { cancellations += 1 }
        keys.handleKey(key(121)); keys.handleKey(key(119))
        XCTAssertEqual(view.contentView.bounds.minY, 0, accuracy: 1)
        XCTAssertTrue(keys.handleKey(key(53)))
        XCTAssertEqual(cancellations, 1)
    }
    func testTabTraversalCanEnterAndLeaveListAndRootControlsInBothDirections() {
        typealias Preview = TransferPlanPreviewContent
        let roots = [UUID(), UUID()]
        var focus: Preview.Control = .list
        focus = Preview.traversal(from: focus, forward: true, roots: roots, canStart: true)
        XCTAssertEqual(focus, .root(roots[0]))
        focus = Preview.traversal(from: focus, forward: true, roots: roots, canStart: true)
        XCTAssertEqual(focus, .root(roots[1]))
        XCTAssertEqual(Preview.traversal(from: focus, forward: true, roots: roots, canStart: true), .start)
        focus = Preview.traversal(from: focus, forward: false, roots: roots, canStart: true)
        XCTAssertEqual(focus, .root(roots[0]))
        focus = Preview.traversal(from: focus, forward: false, roots: roots, canStart: true)
        XCTAssertEqual(focus, .list)
        XCTAssertEqual(Preview.traversal(from: focus, forward: false, roots: roots, canStart: true), .policy)
        XCTAssertEqual(Preview.traversal(from: .list, forward: true, roots: [], canStart: true), .start)
        XCTAssertEqual(Preview.traversal(from: .root(roots[1]), forward: true, roots: roots, canStart: false), .cancel)
    }
    func testKeysAreScopedToFocusedListAndDoNotStealOtherControlKeys() {
        let (scroll, keys) = scroll()
        var traversal: [Bool] = []
        keys.onTraverse = { traversal.append($0) }
        XCTAssertFalse(keys.acceptsFirstResponder) // the marker is not another Tab stop
        keys.active = false
        XCTAssertFalse(keys.handleKey(key(125)))
        XCTAssertFalse(keys.handleKey(key(48)))
        XCTAssertEqual(scroll.contentView.bounds.minY, 0)
        keys.active = true
        XCTAssertTrue(keys.handleKey(key(48)))
        XCTAssertTrue(keys.handleKey(key(48, modifiers: .shift)))
        XCTAssertEqual(traversal, [true, false])
        keys.canScroll = false // root buttons still traverse but retain arrow/Space handling
        XCTAssertFalse(keys.handleKey(key(125)))
        XCTAssertFalse(keys.handleKey(key(49)))
        XCTAssertFalse(keys.handleKey(key(125, modifiers: .option)))
        XCTAssertTrue(keys.handleKey(key(48)))
    }
    func testLongPathTakesItsFullWrappedHeightInsteadOfTruncating() {
        func height(_ text: String) -> CGFloat {
            let host = NSHostingView(rootView: PlanPathText(text: text).frame(width: 300))
            host.sizingOptions = [.intrinsicContentSize]
            return host.fittingSize.height
        }
        let short = height("来源：/资料.txt")
        let long = height("来源：/" + Array(repeating: "很长的中文目录名称与空格 资料%#/", count: 20).joined() + "最后的文件名.txt")
        XCTAssertGreaterThan(short, 0)
        XCTAssertGreaterThan(long, short * 8)
    }
    private func findKeys(_ root: NSView) -> PlanScrollKeyView? {
        if let keys = root as? PlanScrollKeyView { return keys }
        return root.subviews.lazy.compactMap { self.findKeys($0) }.first
    }
    private func host<Content: View>(_ content: Content, size: NSSize) -> (NSWindow, NSHostingView<Content>) {
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }
    func testSwiftUIScrollDocumentWrapsPathsAndReachesBothBoundaries() async throws {
        let preview = KeyboardPlanScrollView(active: true, onCancel: {}) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(0..<20) { index in
                    PlanPathText(text: "来源：/长中文项目/第一层/第二层/第三层/很长的中文文件名称_完整路径_\(index).txt")
                }
            }.padding(8)
        }
        let (window, host) = host(preview, size: NSSize(width: 400, height: 200))
        defer { window.close() }
        try await Task.sleep(nanoseconds: 30_000_000)
        host.layoutSubtreeIfNeeded()
        guard let keys = findKeys(host), let scroll = keys.enclosingScrollView,
              let document = scroll.documentView else { return XCTFail("Missing same-tree SwiftUI scroll document") }
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
        XCTAssertTrue(keys.handleKey(key(119)))
        let bottom = document.isFlipped ? scroll.contentView.bounds.maxY : scroll.contentView.bounds.minY
        XCTAssertEqual(bottom, document.isFlipped ? document.bounds.maxY : document.bounds.minY, accuracy: 1)
        XCTAssertTrue(keys.handleKey(key(115)))
        let top = document.isFlipped ? scroll.contentView.bounds.minY : scroll.contentView.bounds.maxY
        XCTAssertEqual(top, document.isFlipped ? document.bounds.minY : document.bounds.maxY, accuracy: 1)
    }
    private func plan() -> TransferPlan {
        let paths = ["长中文项目_资料与代码_保持完整名称", "单独资料.txt"].map {
            RemotePath(components: [.init(name: $0, bytes: Data($0.utf8))])
        }
        let roots = paths.enumerated().map { index, path in
            TransferPlan.Root(source: .remote(path, .utf8), kind: index == 0 ? .directory : .regularFile)
        }
        let nodes = zip(roots, paths).map { root, path in
            TransferPlan.Node(rootID: root.id, kind: root.kind, source: root.source,
                target: .local(URL(fileURLWithPath: "/destination/" + path.display)), relativePath: path.components,
                size: 6, snapshot: .remote(kind: root.kind, size: 6))
        }
        return TransferPlan(direction: .download, roots: roots, nodes: nodes)
    }
    @MainActor private final class Navigation: ObservableObject { @Published var target: UUID? }
    private struct NavigationHarness<Content: View>: View {
        @ObservedObject var navigation: Navigation
        let content: Content
        var body: some View {
            ScrollViewReader { proxy in
                content.onChange(of: navigation.target) { id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
    private struct AccessibilitySnapshot {
        let object: NSObject
        let role: String?
        let label: String?
        let value: String?
        let frame: NSRect
    }
    private func accessibilityNodes(_ root: Any) -> [AccessibilitySnapshot] {
        var result: [AccessibilitySnapshot] = [], visited = Set<ObjectIdentifier>()
        func value(_ node: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector) else { return nil }
            return node.perform(selector)?.takeUnretainedValue()
        }
        func walk(_ node: Any) {
            guard let object = node as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted else { return }
            // SwiftUI AccessibilityNode implements the standard selectors but
            // does not formally adopt NSAccessibilityProtocol on this SDK.
            let selector = NSSelectorFromString("accessibilityFrame")
            var frame = NSRect.zero
            if object.responds(to: selector) {
                typealias FrameGetter = @convention(c) (AnyObject, Selector) -> NSRect
                frame = unsafeBitCast(object.method(for: selector), to: FrameGetter.self)(object, selector)
            }
            result.append(.init(object: object, role: value(object, "accessibilityRole") as? String,
                                label: value(object, "accessibilityLabel") as? String,
                                value: value(object, "accessibilityValue") as? String, frame: frame))
            for child in value(object, "accessibilityChildren") as? [Any] ?? [] { walk(child) }
        }
        walk(root)
        return result
    }
    func testQueueItemTitlesDistinguishDirectionDirectoryReuseAndDependencyReasons() {
        var parent = BatchTransferQueue.Item(id: UUID(), url: URL(fileURLWithPath: "/tmp/tree"), name: "tree", target: "/保存目录/tree", snapshot: nil)
        parent.kind = .directory; parent.direction = .download; parent.state = .running
        XCTAssertEqual(parent.statusTitle, "正在核对/创建本地目录")
        parent.direction = .upload; XCTAssertEqual(parent.statusTitle, "正在核对/创建远程目录")
        parent.state = .succeeded; parent.reusedDirectory = true
        XCTAssertEqual(parent.statusTitle, "成功 · 已有目录复用")
        var file = BatchTransferQueue.Item(id: UUID(), url: URL(fileURLWithPath: "/tmp/tree/file"), name: "file", target: "/保存目录/tree/file", snapshot: nil)
        file.direction = .download; file.parentID = parent.id; file.state = .running
        XCTAssertEqual(file.directionTitle, "↓ 下载"); XCTAssertEqual(file.kindTitle, "文件")
        XCTAssertEqual(file.statusTitle, "正在下载")
        XCTAssertTrue(file.dependencyDescription(in: [parent, file])?.contains(parent.target) == true)
        file.direction = .upload; XCTAssertEqual(file.statusTitle, "正在上传")
        for reason in [TransferTaskResult.DependencyReason.failedAncestor, .skippedAncestor, .cancelledAncestor] {
            file.state = .blocked(parentID: parent.id, reason: reason)
            XCTAssertEqual(file.statusTitle, "依赖阻塞：" + reason.title)
        }
    }
    func testActualDownloadQueueExposesDirectionKindsAndCancelAtMinimumSize() async throws {
        _ = NSApplication.shared
        let setter = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        let getter = NSSelectorFromString("accessibilityAttributeValue:")
        let previous = NSApp.perform(getter, with: "AXEnhancedUserInterface")?.takeUnretainedValue()
        _ = NSApp.perform(setter, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        defer { _ = NSApp.perform(setter, with: previous ?? NSNumber(value: false), with: "AXEnhancedUserInterface") }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("queue-view-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let model = AppModel(history: TransferHistory(url: base.appendingPathComponent("history.json")))
        defer { model.batch.cancelAll(); try? FileManager.default.removeItem(at: base) }
        let initial = plan()
        let nodes = initial.nodes.map { node in
            TransferPlan.Node(rootID: node.rootID, kind: node.kind, source: node.source,
                target: .local(node.relativePath.reduce(base) { $0.appendingPathComponent($1.name) }),
                relativePath: node.relativePath, size: node.kind == .directory ? nil : node.size,
                snapshot: .remote(kind: node.kind, size: node.kind == .directory ? nil : node.size))
        }
        let download = TransferPlan(direction: .download, roots: initial.roots, nodes: nodes)
        try model.batch.prepare(plan: download, endpoint: FTPEndpoint(address: "ftp://example.test"),
            remoteRoot: RemotePath(), encoding: .utf8, credentials: .anonymous, destination: LocalDestinationRoot(url: base))
        let (window, host) = host(TransferPanel(model: model), size: NSSize(width: 580, height: 420))
        defer { window.close() }
        try await Task.sleep(nanoseconds: 30_000_000)
        host.layoutSubtreeIfNeeded()
        let before = accessibilityNodes(host)
        let keys = try XCTUnwrap(findKeys(host))
        keys.active = true
        XCTAssertTrue(keys.handleKey(key(119)))
        host.layoutSubtreeIfNeeded()
        let after = accessibilityNodes(host)
        let labels = (before + after).flatMap { [$0.label, $0.value].compactMap { $0 } }.joined(separator: "\n")
        XCTAssertTrue(labels.contains("下载队列"), labels); XCTAssertFalse(labels.contains("上传队列"), labels)
        XCTAssertTrue(labels.contains("↓ 下载 · 目录"), labels); XCTAssertTrue(labels.contains("↓ 下载 · 文件"), labels)
        let cancel = try XCTUnwrap(after.first { $0.role == NSAccessibility.Role.button.rawValue && $0.label == "取消全部" })
        let visible = window.convertToScreen(host.convert(host.bounds, to: nil))
        XCTAssertGreaterThan(cancel.frame.width, 0)
        XCTAssertGreaterThanOrEqual(cancel.frame.minY, visible.minY - 1)
        XCTAssertLessThanOrEqual(cancel.frame.maxY, visible.maxY + 1)
        XCTAssertTrue(keys.handleKey(key(115)))
    }
    func testLargeActualQueueReachesFirstMiddleLastWithoutImplicitNetworkRequests() async throws {
        _ = NSApplication.shared
        let setter = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        let getter = NSSelectorFromString("accessibilityAttributeValue:")
        let previous = NSApp.perform(getter, with: "AXEnhancedUserInterface")?.takeUnretainedValue()
        _ = NSApp.perform(setter, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        defer { _ = NSApp.perform(setter, with: previous ?? NSNumber(value: false), with: "AXEnhancedUserInterface") }
        for count in [1_000, 10_000] {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let fake = ControlledFTP(), model = AppModel(client: fake, history: TransferHistory(url: base.appendingPathComponent("history.json")))
            let original = try TransferScaleInput.plan(nodeCount: count, depth: 8)
            let nodes = original.nodes.map { node in
                TransferPlan.Node(id: node.id, rootID: node.rootID, kind: node.kind, source: node.source,
                    target: .local(node.relativePath.reduce(base) { $0.appendingPathComponent($1.name) }),
                    relativePath: node.relativePath, parentID: node.parentID, size: node.size, snapshot: node.snapshot)
            }
            let plan = TransferPlan(direction: .download, roots: original.roots, nodes: nodes)
            try model.batch.prepare(plan: plan, endpoint: FTPEndpoint(address: "ftp://example.test"),
                remoteRoot: RemotePath(), encoding: .utf8, credentials: .anonymous, destination: LocalDestinationRoot(url: base))
            defer { model.batch.cancelAll() }
            let navigation = Navigation()
            let (window, hosting) = host(NavigationHarness(navigation: navigation, content: TransferPanel(model: model)), size: NSSize(width: 580, height: 420))
            defer { window.close() }
            try await Task.sleep(nanoseconds: 50_000_000); hosting.layoutSubtreeIfNeeded()
            for index in [0, count / 2, count - 1] {
                navigation.target = nodes[index].id
                try await Task.sleep(nanoseconds: 80_000_000); hosting.layoutSubtreeIfNeeded()
                let keys = try XCTUnwrap(findKeys(hosting)), scroll = try XCTUnwrap(keys.enclosingScrollView)
                let viewport = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
                let target = model.batch.items[index].target
                let matches = accessibilityNodes(hosting).filter { ($0.label ?? $0.value ?? "").contains(target) }
                XCTAssertTrue(matches.contains { $0.frame.intersects(viewport) },
                    "Queue node \(index) of \(count) must remain reachable and visible: matches=\(matches.map(\.frame)), viewport=\(viewport), clip=\(scroll.contentView.bounds), document=\(scroll.documentView?.bounds ?? .zero)")
            }
            XCTAssertEqual(model.batch.items.map(\.id), nodes.map(\.id))
            XCTAssertTrue(fake.browses.isEmpty); XCTAssertTrue(fake.uploads.isEmpty); XCTAssertTrue(fake.downloads.isEmpty)
            let button = try XCTUnwrap(accessibilityNodes(hosting).first { $0.role == NSAccessibility.Role.button.rawValue && $0.label == "取消全部" })
            let visible = window.convertToScreen(hosting.convert(hosting.bounds, to: nil))
            XCTAssertGreaterThan(button.frame.width, 0); XCTAssertGreaterThanOrEqual(button.frame.minY, visible.minY - 1)
            XCTAssertLessThanOrEqual(button.frame.maxY, visible.maxY + 1)
            let selector = NSSelectorFromString("accessibilityPerformPress")
            XCTAssertTrue(button.object.responds(to: selector))
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            XCTAssertTrue(unsafeBitCast(button.object.method(for: selector), to: Press.self)(button.object, selector))
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertFalse(model.batch.isExecuting)
            XCTAssertTrue(model.batch.items.allSatisfy { $0.state == .cancelled })
            XCTAssertTrue(fake.browses.isEmpty); XCTAssertTrue(fake.uploads.isEmpty); XCTAssertTrue(fake.downloads.isEmpty)
        }
    }
    func testLargeActualPreviewReachesFirstMiddleLastAndActivatesFooterWithoutTruncation() async throws {
        _ = NSApplication.shared
        let setter = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        let getter = NSSelectorFromString("accessibilityAttributeValue:")
        let previous = NSApp.perform(getter, with: "AXEnhancedUserInterface")?.takeUnretainedValue()
        _ = NSApp.perform(setter, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        defer { _ = NSApp.perform(setter, with: previous ?? NSNumber(value: false), with: "AXEnhancedUserInterface") }
        for count in [1_000, 10_000] {
            let plan = try TransferScaleInput.plan(nodeCount: count, depth: 8), navigation = Navigation()
            var starts = 0, cancels = 0, locationCalls = 0
            let preview = TransferPlanPreviewContent(plan: plan, canRemoveRoots: false,
                location: { value in
                    locationCalls += 1
                    switch value { case .remote(let path, _): return path.display; case .local(let url): return url.path }
                }, issueTitle: { _ in "阻断" }, onRemove: { _ in }, onConfirm: { _ in starts += 1 }, onCancel: { cancels += 1 })
                .padding(16)
            let (window, hosting) = host(NavigationHarness(navigation: navigation, content: preview), size: NSSize(width: 580, height: 420))
            defer { window.close() }
            try await Task.sleep(nanoseconds: 50_000_000); hosting.layoutSubtreeIfNeeded()
            XCTAssertLessThan(locationCalls, count, "Initial layout must not format every node's paths")
            for index in [0, count / 2, count - 1] {
                navigation.target = plan.nodes[index].id
                try await Task.sleep(nanoseconds: 80_000_000); hosting.layoutSubtreeIfNeeded()
                let expected = plan.nodes[index].relativePath.map(\.name).joined(separator: "/")
                let keys = try XCTUnwrap(findKeys(hosting)), scroll = try XCTUnwrap(keys.enclosingScrollView)
                let viewport = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
                XCTAssertTrue(accessibilityNodes(hosting).contains { ($0.label ?? $0.value ?? "").contains(expected) && $0.frame.intersects(viewport) },
                    "Requested node \(index) of \(count) must be in the visible viewport, not merely in AX data")
            }
            let nodes = accessibilityNodes(hosting)
            for title in ["确认开始本计划", "取消计划"] {
                let button = try XCTUnwrap(nodes.first { $0.role == NSAccessibility.Role.button.rawValue && $0.label == title })
                let visible = window.convertToScreen(hosting.convert(hosting.bounds, to: nil))
                XCTAssertGreaterThan(button.frame.width, 0); XCTAssertGreaterThanOrEqual(button.frame.minY, visible.minY - 1)
                XCTAssertLessThanOrEqual(button.frame.maxY, visible.maxY + 1)
                let selector = NSSelectorFromString("accessibilityPerformPress")
                XCTAssertTrue(button.object.responds(to: selector))
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                let press = unsafeBitCast(button.object.method(for: selector), to: Press.self)
                XCTAssertTrue(press(button.object, selector))
            }
            XCTAssertEqual(starts, 1); XCTAssertEqual(cancels, 1)
            XCTAssertEqual(plan.nodes.count, count, "Layout never truncates the actual plan")
        }
    }
    func testActualPreviewExposesBothRootButtonsAndFooterAtMinimumSize() async throws {
        // Enable AX rendering only in this test process, not system VoiceOver.
        _ = NSApplication.shared
        let setter = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        let getter = NSSelectorFromString("accessibilityAttributeValue:")
        XCTAssertTrue(NSApp.responds(to: setter))
        let previous = NSApp.responds(to: getter) ? NSApp.perform(getter, with: "AXEnhancedUserInterface")?.takeUnretainedValue() : nil
        _ = NSApp.perform(setter, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        defer { _ = NSApp.perform(setter, with: previous ?? NSNumber(value: false), with: "AXEnhancedUserInterface") }
        let preview = TransferPlanPreviewContent(plan: plan(), canRemoveRoots: true,
            location: { value in
                switch value {
                case .remote(let path, _): return "/来源/" + path.display
                case .local(let url): return url.path
                }
            }, issueTitle: { _ in "阻断" }, onRemove: { _ in }, onConfirm: { _ in }, onCancel: {})
            .padding(16)
        let (window, host) = host(preview, size: NSSize(width: 580, height: 420))
        defer { window.close() }
        try await Task.sleep(nanoseconds: 30_000_000)
        host.layoutSubtreeIfNeeded()
        let nodes = accessibilityNodes(host)
        let buttons = nodes.filter { $0.role == NSAccessibility.Role.button.rawValue }
        let removals = buttons.filter { ($0.label ?? "").hasPrefix("移除 ") }
        XCTAssertEqual(removals.count, 2, "Both real preview root controls must remain exposed")
        let starts = buttons.filter { $0.label == "确认开始本计划" }
        let cancels = buttons.filter { $0.label == "取消计划" }
        XCTAssertEqual(starts.count, 1); XCTAssertEqual(cancels.count, 1)
        let visible = window.convertToScreen(host.convert(host.bounds, to: nil))
        for button in removals + starts + cancels {
            let frame = button.frame
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThanOrEqual(frame.minX, visible.minX - 1)
            XCTAssertLessThanOrEqual(frame.maxX, visible.maxX + 1)
        }
        for button in starts + cancels {
            let frame = button.frame
            XCTAssertGreaterThanOrEqual(frame.minY, visible.minY - 1)
            XCTAssertLessThanOrEqual(frame.maxY, visible.maxY + 1)
        }
        XCTAssertNotNil(findKeys(host)?.enclosingScrollView)
    }
}
