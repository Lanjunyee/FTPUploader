import XCTest

final class LocalRootAccessTests: XCTestCase {
    private final class Counter {
        var starts: [URL] = []
        var stops: [URL] = []
        var scope: LocalSecurityScope {
            LocalSecurityScope(start: { self.starts.append($0); return true }, stop: { self.stops.append($0) })
        }
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    @MainActor
    func testRootsRetainScopeThroughoutEveryPhaseAndCancelCleanup() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = url.appendingPathComponent("source")
        try Data([1]).write(to: source)
        for cancelPhase in [TransferBatchPhase.scanning, .preview, .paused, .running, .finished] {
            let counter = Counter()
            var roots: [LocalRootAccess] = [try LocalSourceRoot(url: source, scope: counter.scope),
                                           try LocalDestinationRoot(url: url, scope: counter.scope)]
            let state = TransferBatchState()
            XCTAssertEqual(counter.starts, [source, url])
            if cancelPhase != .scanning { XCTAssertTrue(state.scanned()) }
            if cancelPhase != .scanning && cancelPhase != .preview { XCTAssertTrue(state.start()) }
            if cancelPhase == .paused { XCTAssertTrue(state.pause()) }
            for root in roots { try root.validateIdentity() }
            XCTAssertTrue(counter.stops.isEmpty)
            if cancelPhase == .finished { XCTAssertTrue(state.complete()) }
            else {
                XCTAssertTrue(state.cancel())
                XCTAssertTrue(state.phase.isLocked)
                XCTAssertTrue(counter.stops.isEmpty)
                for root in roots { try root.validateIdentity() }
                XCTAssertTrue(state.backendStopped())
            }
            roots.removeAll()
            XCTAssertEqual(Set(counter.stops), Set([source, url]))
            XCTAssertEqual(counter.stops.count, 2)
        }
    }
    func testOnlySelectedRootsAreAuthorizedAndExplicitReleaseIsIdempotent() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let counter = Counter()
        let root = try LocalSourceRoot(url: url, scope: counter.scope)
        XCTAssertEqual(root.identity.kind, .directory)
        XCTAssertEqual(counter.starts, [url])
        root.endAccess(); root.endAccess()
        XCTAssertEqual(counter.stops, [url])
        XCTAssertThrowsError(try root.validateIdentity())
        XCTAssertEqual(Set(Mirror(reflecting: root).superclassMirror!.children.compactMap(\.label)),
                       ["url", "identity", "scope", "hasScope", "lock", "storage", "users", "closing"])
    }
    func testFailedInitializationBalancesScopeAndDoesNotFollowRootLink() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("file")
        try Data().write(to: file)
        let link = url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        for invalid in [link, url.appendingPathComponent("missing"), file] {
            let counter = Counter()
            XCTAssertThrowsError(try LocalDestinationRoot(url: invalid, scope: counter.scope))
            XCTAssertEqual(counter.starts, [invalid])
            XCTAssertEqual(counter.stops, [invalid])
        }
        let counter = Counter()
        XCTAssertThrowsError(try LocalSourceRoot(url: link, scope: counter.scope))
        XCTAssertEqual(counter.stops, [link])
    }
    func testRootReplacementDoesNotChangeAnchoredIdentity() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let selected = url.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        let root = try LocalDestinationRoot(url: selected)
        let original = root.identity
        try FileManager.default.moveItem(at: selected, to: url.appendingPathComponent("original"))
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        XCTAssertThrowsError(try root.validateIdentity())
        XCTAssertEqual(root.identity, original)
    }
    func testActiveLeasesDeferReleaseWithoutBlockingAndRejectNewUsers() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let counter = Counter()
        let root = try LocalSourceRoot(url: url, scope: counter.scope)
        var first: LocalRootAccess.Lease? = try root.lease()
        var second: LocalRootAccess.Lease? = try root.lease()
        let fd = first!.descriptor
        XCTAssertEqual(second!.descriptor, fd)
        root.endAccess(); root.endAccess()
        XCTAssertTrue(counter.stops.isEmpty)
        XCTAssertThrowsError(try root.lease())
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            root.endAccess()
            XCTAssertGreaterThanOrEqual(fcntl(fd, F_GETFD), 0)
        }
        first = nil
        XCTAssertTrue(counter.stops.isEmpty)
        XCTAssertGreaterThanOrEqual(fcntl(fd, F_GETFD), 0)
        second = nil
        XCTAssertEqual(counter.stops, [url])
        XCTAssertEqual(root.descriptor, -1)
        XCTAssertEqual(fcntl(fd, F_GETFD), -1)
    }

    func testUnscopedAccessIsNotStoppedAndNoBookmarkIsCreated() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        var stops = 0
        let root = try LocalDestinationRoot(url: url, scope: LocalSecurityScope(start: { _ in false }, stop: { _ in stops += 1 }))
        try root.validateIdentity()
        root.endAccess()
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.path), [])
    }
}
