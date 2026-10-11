import XCTest
import Darwin

@MainActor
final class LocalDestinationServiceTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testExplicitDirectoryCreationReuseAndNoImplicitParents() throws {
        let url = try folder(), root = try LocalDestinationRoot(url: url)
        let service = try LocalDestinationService(root: root)
        XCTAssertEqual(try service.createDirectory(["目录 中文%#"]), .created)
        var created = stat()
        XCTAssertEqual(lstat(url.appendingPathComponent("目录 中文%#").path, &created), 0)
        XCTAssertEqual(created.st_mode & 0o700, 0o700)
        XCTAssertEqual(created.st_mode & S_ISVTX, 0)
        XCTAssertEqual(try service.createDirectory(["目录 中文%#"]), .reused)
        XCTAssertEqual(try service.createDirectory(["目录 中文%#", "empty"]), .created)
        XCTAssertThrowsError(try service.createDirectory(["missing", "child"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("missing").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("目录 中文%#/empty").path))
    }
    func testIllegalNamesFilesAndLinksAreRejectedWithoutOutsideWrites() throws {
        let url = try folder(), outside = try folder()
        try Data("protected".utf8).write(to: outside.appendingPathComponent("protected"))
        let service = try LocalDestinationService(root: LocalDestinationRoot(url: url))
        for name in ["", ".", "..", "a/b", "a:b", "a\u{0}", "a\n", String(repeating: "a", count: 256)] {
            XCTAssertThrowsError(try service.createDirectory([name]))
        }
        try Data([1]).write(to: url.appendingPathComponent("file"))
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertThrowsError(try service.createDirectory(["file"]))
        XCTAssertThrowsError(try service.createDirectory(["link"]))
        XCTAssertThrowsError(try service.createDirectory(["link", "escaped"]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["protected"])
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("protected")), Data("protected".utf8))
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("file")), Data([1]))
    }
    func testPreparedAncestorReplacementWithDirectoryOrFileFails() throws {
        for directory in [false, true] {
            let url = try folder(), parent = url.appendingPathComponent("parent")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            let service = try LocalDestinationService(root: LocalDestinationRoot(url: url))
            try service.prepareDirectory(["parent"])
            try FileManager.default.moveItem(at: parent, to: url.appendingPathComponent("original"))
            if directory { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false) }
            else { try Data([7]).write(to: parent) }
            XCTAssertThrowsError(try service.createDirectory(["parent", "child"]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("original/child").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("child").path))
        }
    }
    func testAncestorReplacedByOutsideLinkBetweenOpeningAndMutation() throws {
        let url = try folder(), outside = try folder(), parent = url.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try Data([3]).write(to: outside.appendingPathComponent("protected"))
        let service = try LocalDestinationService(root: LocalDestinationRoot(url: url), beforeMutation: {
            try FileManager.default.moveItem(at: parent, to: url.appendingPathComponent("original"))
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        })
        try service.prepareDirectory(["parent"])
        XCTAssertThrowsError(try service.createDirectory(["parent", "escaped"]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["protected"])
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("protected")), Data([3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("original/escaped").path))
    }
    func testRootReplacementBetweenOpeningAndMutationDoesNotWriteThroughLink() throws {
        let parent = try folder(), outside = try folder(), selected = parent.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        try Data([4]).write(to: outside.appendingPathComponent("protected"))
        let root = try LocalDestinationRoot(url: selected)
        let service = try LocalDestinationService(root: root, beforeMutation: {
            try FileManager.default.moveItem(at: selected, to: parent.appendingPathComponent("original"))
            try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: outside)
        })
        XCTAssertThrowsError(try service.createDirectory(["escaped"]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["protected"])
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("protected")), Data([4]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("original/escaped").path))
    }
    func testRealAncestorOfRootReplacementFailsWithoutChangingNewTree() throws {
        let container = try folder(), parent = container.appendingPathComponent("parent")
        let selected = parent.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let service = try LocalDestinationService(root: LocalDestinationRoot(url: selected))
        try FileManager.default.moveItem(at: parent, to: container.appendingPathComponent("original"))
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        XCTAssertThrowsError(try service.createDirectory(["child"]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: selected.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: container.appendingPathComponent("original/selected").path), [])
    }

    func testAnchoredDownloadsKeepStructureAndCommitOnlyAfterClose() throws {
        let url = try folder(), service = try LocalDestinationService(root: LocalDestinationRoot(url: url))
        XCTAssertThrowsError(try service.download(["missing", "file"]))
        _ = try service.createDirectory(["目录 中文%#"])
        for (name, bytes) in [("empty", Data()), ("binary", Data([0, 255, 10, 128]))] {
            let sink = try service.download(["目录 中文%#", name])
            try sink.receive(bytes)
            XCTAssertThrowsError(try sink.commit())
            XCTAssertFalse(FileManager.default.fileExists(atPath: sink.destination.path))
            try sink.closeFile(); try sink.commit(); try sink.cleanUp()
            XCTAssertEqual(try Data(contentsOf: sink.destination), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: sink.temporary.deletingLastPathComponent().path))
        }
    }

    func testAnchoredExistingTargetRequiresExactAuthorization() throws {
        let url = try folder(), target = url.appendingPathComponent("file")
        try Data("old".utf8).write(to: target)
        let service = try LocalDestinationService(root: LocalDestinationRoot(url: url))
        XCTAssertThrowsError(try service.download(["file"]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.path), ["file"])
        let sink = try service.download(["file"], authorizedIdentity: LocalDownload.identity(target))
        try sink.receive(Data("new".utf8)); try sink.closeFile()
        XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8))
        try sink.commit(); try sink.cleanUp()
        XCTAssertEqual(try Data(contentsOf: target), Data("new".utf8))
    }

    func testAnchoredDiskAndCloseFailuresLatchAgainstCommit() throws {
        for diskFull in [false, true] {
            let url = try folder(), target = url.appendingPathComponent("file")
            try Data("old".utf8).write(to: target)
            let service = try LocalDestinationService(root: LocalDestinationRoot(url: url))
            let sink = try service.download(["file"], authorizedIdentity: LocalDownload.identity(target),
                write: { handle, bytes in
                    if diskFull { try handle.write(contentsOf: Data([1])); throw POSIXError(.ENOSPC) }
                    try handle.write(contentsOf: bytes)
                }, close: { handle in
                    if !diskFull { throw POSIXError(.EIO) }
                    try handle.close()
                })
            if diskFull { XCTAssertThrowsError(try sink.receive(Data([2]))); try sink.closeFile() }
            else { try sink.receive(Data([2])); XCTAssertThrowsError(try sink.closeFile()) }
            XCTAssertThrowsError(try sink.commit()); try sink.cleanUp()
            XCTAssertThrowsError(try sink.commit())
            XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8))
        }
    }

    func testAnchoredDetectedChangesRequireNewIdentityEachTime() throws {
        let url = try folder(), target = url.appendingPathComponent("file")
        let service = try LocalDestinationService(root: LocalDestinationRoot(url: url))
        let sink = try service.download(["file"])
        try sink.receive(Data("download".utf8)); try sink.closeFile()
        try Data("first".utf8).write(to: target)
        XCTAssertThrowsError(try sink.commit()) { XCTAssertTrue($0 is LocalDownload.CommitError) }
        let shown = try sink.currentTargetIdentity()
        try Data("second-longer".utf8).write(to: target)
        sink.authorizeTarget(shown)
        XCTAssertThrowsError(try sink.commit()) { XCTAssertTrue($0 is LocalDownload.CommitError) }
        XCTAssertEqual(try Data(contentsOf: target), Data("second-longer".utf8))
        try sink.authorizeCurrentTarget(); try sink.commit(); try sink.cleanUp()
        XCTAssertEqual(try Data(contentsOf: target), Data("download".utf8))
    }

    func testAnchoredExclusiveRenameProtectsAfterLastCheckRace() throws {
        let url = try folder(), target = url.appendingPathComponent("file")
        let service = try LocalDestinationService(root: LocalDestinationRoot(url: url))
        var operations = LocalDownload.Anchor.Operations(), calls = 0
        let realMove = operations.move
        operations.move = { fromFD, from, toFD, to, flags in
            calls += 1; XCTAssertNotEqual(flags & UInt32(RENAME_EXCL), 0)
            try Data("race".utf8).write(to: target)
            try realMove(fromFD, from, toFD, to, flags)
        }
        let sink = try service.download(["file"], operations: operations)
        try sink.receive(Data("download".utf8)); try sink.closeFile()
        XCTAssertThrowsError(try sink.commit()) { XCTAssertTrue($0 is LocalDownload.CommitError) }
        XCTAssertEqual(calls, 1); XCTAssertEqual(try Data(contentsOf: target), Data("race".utf8))
        try sink.cleanUp()
    }

    func testAnchoredUnsupportedPrimitiveFailsWithoutFallback() throws {
        for existing in [false, true] {
            let url = try folder(), target = url.appendingPathComponent("file")
            if existing { try Data("old".utf8).write(to: target) }
            let service = try LocalDestinationService(root: LocalDestinationRoot(url: url))
            var operations = LocalDownload.Anchor.Operations(), calls = 0
            operations.move = { _, _, _, _, _ in calls += 1; throw POSIXError(.ENOTSUP) }
            let sink = try service.download(["file"], authorizedIdentity: LocalDownload.identity(target), operations: operations)
            try sink.receive(Data("new".utf8)); try sink.closeFile()
            XCTAssertThrowsError(try sink.commit()); XCTAssertEqual(calls, 1)
            if existing { XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8)) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: target.path)) }
            try sink.cleanUp()
        }
    }

    func testAnchoredTemporaryReplacementIsNotCommittedOrDeleted() throws {
        let url = try folder(), target = url.appendingPathComponent("file")
        try Data("old".utf8).write(to: target)
        let service = try LocalDestinationService(root: LocalDestinationRoot(url: url))
        let sink = try service.download(["file"], authorizedIdentity: LocalDownload.identity(target))
        try sink.receive(Data("owned".utf8)); try sink.closeFile()
        try FileManager.default.moveItem(at: sink.temporary, to: sink.temporary.deletingLastPathComponent().appendingPathComponent("original"))
        try Data("foreign".utf8).write(to: sink.temporary)
        XCTAssertThrowsError(try sink.commit()); XCTAssertThrowsError(try sink.cleanUp())
        XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: sink.temporary), Data("foreign".utf8))
    }

    func testAnchoredCleanupFailureReportsPathAndPreservesTarget() throws {
        let url = try folder(), target = url.appendingPathComponent("file")
        try Data("old".utf8).write(to: target)
        let service = try LocalDestinationService(root: LocalDestinationRoot(url: url))
        var operations = LocalDownload.Anchor.Operations()
        operations.remove = { _, _, _ in throw POSIXError(.EACCES) }
        let sink = try service.download(["file"], authorizedIdentity: LocalDownload.identity(target), operations: operations)
        try sink.receive(Data("partial".utf8))
        XCTAssertThrowsError(try sink.cleanUp()) { XCTAssertTrue($0.localizedDescription.contains(sink.temporary.path)) }
        XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sink.temporary.path))
    }

    func testAnchoredRootOrParentReplacementFailsCommitAndCleansOnlyOwnedResources() throws {
        for replaceRoot in [false, true] {
            let container = try folder(), outside = try folder(), rootURL = container.appendingPathComponent("root")
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
            let service = try LocalDestinationService(root: LocalDestinationRoot(url: rootURL))
            _ = try service.createDirectory(["parent"])
            let sink = try service.download(["parent", "file"])
            try sink.receive(Data("partial".utf8)); try sink.closeFile()
            try Data("protected".utf8).write(to: outside.appendingPathComponent("file"))
            let moved = replaceRoot ? rootURL : rootURL.appendingPathComponent("parent")
            let original = container.appendingPathComponent("original")
            try FileManager.default.moveItem(at: moved, to: original)
            try FileManager.default.createSymbolicLink(at: moved, withDestinationURL: outside)
            XCTAssertThrowsError(try sink.commit()); try sink.cleanUp()
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["file"])
            XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("file")), Data("protected".utf8))
            let originalParent = replaceRoot ? original.appendingPathComponent("parent") : original
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: originalParent.path), [])
        }
    }
}
