import XCTest

final class SelectedFileTests: XCTestCase {
    func testUnreadableFileAndDirectoryAreRejected() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ftp-permission-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("file.txt")
        try Data("permission test".utf8).write(to: file)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: folder)
        }
        XCTAssertThrowsError(try SelectedLocalFile(url: folder))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        XCTAssertThrowsError(try SelectedLocalFile(url: file))
    }

    func testFileIsRevalidatedBeforeUpload() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ftp-selected-" + UUID().uuidString)
        try Data().write(to: file)
        let selected = try SelectedLocalFile(url: file)
        XCTAssertEqual(selected.size, 0)
        selected.endAccess()
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try selected.beginAccessAndValidate())
    }
}

final class VerifiedUploadSourceTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testReplacementBeforeDescriptorVerificationRejectsLinkFileAndAncestorChanges() async throws {
        for replacement in ["link", "file", "ancestor"] {
            let container = try folder(), parent = container.appendingPathComponent("parent")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            let url = parent.appendingPathComponent("file")
            try Data("approved".utf8).write(to: url)
            let selected = try SelectedLocalFile(url: url)
            let expected = try await selected.snapshot()
            if replacement == "ancestor" {
                try FileManager.default.moveItem(at: parent, to: container.appendingPathComponent("original"))
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
                try Data("foreign".utf8).write(to: url)
            } else {
                try FileManager.default.moveItem(at: url, to: parent.appendingPathComponent("original"))
                if replacement == "link" {
                    let foreign = container.appendingPathComponent("foreign")
                    try Data("foreign".utf8).write(to: foreign)
                    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: foreign)
                } else { try Data("foreign".utf8).write(to: url) }
            }
            do { _ = try await selected.verifiedSource(matching: expected, cancellation: FTPCancellationToken()); XCTFail("Accepted replacement") }
            catch { XCTAssertTrue(error is FTPError) }
            selected.endAccess()
        }
    }
    func testSameInodeModificationAndCancellationRejectBeforeSending() async throws {
        let url = try folder().appendingPathComponent("file")
        try Data("approved".utf8).write(to: url)
        let selected = try SelectedLocalFile(url: url), token = FTPCancellationToken()
        let expected = try await selected.snapshot()
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data("changed!".utf8)); try handle.close()
        do { _ = try await selected.verifiedSource(matching: expected, cancellation: token); XCTFail("Accepted content change") }
        catch { XCTAssertTrue(error is FTPError) }
        let current = try await selected.snapshot()
        token.cancel()
        do { _ = try await selected.verifiedSource(matching: current, cancellation: token); XCTFail("Accepted cancelled verification") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

final class LocalScannerTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testNestedEmptyHiddenAndPackageContentsAreNotFiltered() async throws {
        let url = try folder()
        let nested = url.appendingPathComponent("项目.app/嵌套/空目录")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([0, 255]).write(to: url.appendingPathComponent(".hidden"))
        try Data().write(to: nested.deletingLastPathComponent().appendingPathComponent("零字节"))
        let root = try LocalSourceRoot(url: url)
        let plan = try await LocalTransferScanner().scan(roots: [root], destination: .root, encoding: .utf8, cancellation: FTPCancellationToken())
        XCTAssertTrue(plan.canStart)
        XCTAssertEqual(plan.nodes.count, 6)
        XCTAssertEqual(plan.nodes.filter { $0.kind == .directory }.count, 4)
        XCTAssertEqual(plan.nodes.filter { $0.kind == .regularFile }.count, 2)
        XCTAssertTrue(plan.nodes.contains { $0.relativePath.last?.name == ".hidden" })
        XCTAssertTrue(plan.nodes.contains { $0.relativePath.last?.name == "空目录" })
        XCTAssertTrue(plan.nodes.allSatisfy { $0.relativePath.first?.name == url.lastPathComponent })
        XCTAssertTrue(root.descriptor >= 0)
    }
    func testUnreadableAndLinkedItemsBlockRatherThanDisappear() async throws {
        let url = try folder()
        let file = url.appendingPathComponent("unreadable")
        try Data([1]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let outside = try folder()
        try Data([9]).write(to: outside.appendingPathComponent("must-not-read"))
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("link"), withDestinationURL: outside)
        let plan = try await LocalTransferScanner().scan(roots: [LocalSourceRoot(url: url)], destination: .root, encoding: .utf8, cancellation: FTPCancellationToken())
        XCTAssertFalse(plan.canStart)
        XCTAssertTrue(plan.issues.contains { $0.reason == .unreadable && $0.path.hasSuffix("unreadable") })
        XCTAssertTrue(plan.issues.contains { $0.reason == .unsupportedType && $0.path.hasSuffix("link") })
        XCTAssertFalse(plan.nodes.contains { $0.relativePath.contains { $0.name == "must-not-read" } })
    }
    func testSnapshotDetectsContentChangesAndRejectsLinks() async throws {
        let url = try folder()
        let file = url.appendingPathComponent("file")
        try Data("first".utf8).write(to: file)
        let selected = try SelectedLocalFile(url: file)
        let before = try await selected.snapshot()
        try Data("other".utf8).write(to: file)
        let after = try await selected.snapshot()
        XCTAssertNotEqual(before.digest, after.digest)
        XCTAssertNotEqual(before, after)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: url)
        do { _ = try await selected.snapshot(); XCTFail("Link followed") } catch { XCTAssertTrue(error is FTPError) }
    }
    func testScannerNodeAndDepthLimitsAtBoundaryAndOneBeyond() async throws {
        let url = try folder()
        for i in 0..<9_999 {
            try Data().write(to: url.appendingPathComponent(String(format: "%05d", i)))
        }
        let root = try LocalSourceRoot(url: url)
        let scanner = LocalTransferScanner()
        let exact = try await scanner.scan(roots: [root], destination: .root, encoding: .utf8, cancellation: FTPCancellationToken())
        XCTAssertEqual(exact.nodes.count, 10_000); XCTAssertTrue(exact.canStart)
        try Data().write(to: url.appendingPathComponent("extra"))
        let over = try await scanner.scan(roots: [root], destination: .root, encoding: .utf8, cancellation: FTPCancellationToken())
        XCTAssertEqual(over.nodes.count, 10_000); XCTAssertFalse(over.canStart)
        XCTAssertTrue(over.issues.contains { $0.reason == .nodeLimit })

        let tree = try folder()
        var leaf = tree
        for _ in 1..<64 {
            leaf = leaf.appendingPathComponent("d")
            try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: false)
        }
        let deepRoot = try LocalSourceRoot(url: tree)
        let deep = try await scanner.scan(roots: [deepRoot], destination: .root, encoding: .utf8, cancellation: FTPCancellationToken())
        XCTAssertEqual(deep.nodes.count, 64); XCTAssertTrue(deep.canStart)
        try FileManager.default.createDirectory(at: leaf.appendingPathComponent("extra"), withIntermediateDirectories: false)
        let tooDeep = try await scanner.scan(roots: [deepRoot], destination: .root, encoding: .utf8, cancellation: FTPCancellationToken())
        XCTAssertFalse(tooDeep.canStart); XCTAssertTrue(tooDeep.issues.contains { $0.reason == .depthLimit })
    }

    func testRemoveOverlappingRootAndRescanRebuildsDependenciesAndRejectsLoop() async throws {
        let url = try folder()
        let child = url.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let parentRoot = try LocalSourceRoot(url: url), childRoot = try LocalSourceRoot(url: child)
        let scanner = LocalTransferScanner()
        let overlap = try await scanner.scan(roots: [parentRoot, childRoot], destination: .root, encoding: .utf8, cancellation: FTPCancellationToken())
        XCTAssertFalse(overlap.canStart)
        XCTAssertTrue(overlap.issues.contains { $0.reason == .overlappingRoots })
        let clean = try await scanner.scan(roots: [parentRoot], destination: .root, encoding: .utf8, cancellation: FTPCancellationToken())
        XCTAssertTrue(clean.canStart); XCTAssertEqual(clean.nodes.count, 2)
        XCTAssertEqual(clean.nodes[1].parentID, clean.nodes[0].id)
        XCTAssertNotEqual(clean.nodes[0].id, overlap.nodes[0].id)
        try FileManager.default.createSymbolicLink(at: child.appendingPathComponent("loop"), withDestinationURL: url)
        let loop = try await scanner.scan(roots: [parentRoot], destination: .root, encoding: .utf8, cancellation: FTPCancellationToken())
        XCTAssertFalse(loop.canStart)
        XCTAssertTrue(loop.issues.contains { $0.reason == .unsupportedType && $0.path.hasSuffix("loop") })
        XCTAssertEqual(loop.nodes.count, 2)
    }

    func testMutationAndCancellationDuringStreamingHashAreDetected() throws {
        let url = try folder().appendingPathComponent("file")
        try Data(repeating: 1, count: 2 * 1024 * 1024).write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let token = FTPCancellationToken()
        XCTAssertThrowsError(try SelectedLocalFile.snapshot(descriptor: handle.fileDescriptor, cancellation: token, didRead: { _ in token.cancel() })) {
            XCTAssertTrue($0 is CancellationError)
        }
        var changed = false
        XCTAssertThrowsError(try SelectedLocalFile.snapshot(descriptor: handle.fileDescriptor, cancellation: FTPCancellationToken(), didRead: { _ in
            if !changed {
                changed = true
                let writer = try! FileHandle(forWritingTo: url)
                try! writer.truncate(atOffset: 0); try! writer.close()
            }
        })) { XCTAssertTrue($0.localizedDescription.contains("变化")) }
    }

    @MainActor
    func testHashIsOffMainThreadAndCanBeCancelledWithoutPartialPlan() async throws {
        let url = try folder()
        let file = url.appendingPathComponent("large")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 256 * 1024 * 1024); try handle.close()
        let root = try LocalSourceRoot(url: url)
        let token = FTPCancellationToken()
        let task = Task { try await LocalTransferScanner().scan(roots: [root], destination: .root, encoding: .utf8, cancellation: token) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let began = Date()
        token.cancel()
        do { _ = try await task.value; XCTFail("Cancelled scan produced a plan") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(began), 2)
        try root.validateIdentity()
    }
}

final class LocalDownloadTests: XCTestCase {
    private func target() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("download.bin")
    }
    func testExistingTargetRequiresConfirmationAndCancelPreservesContent() throws {
        let url = try target(); let old = Data("old".utf8); try old.write(to: url)
        XCTAssertThrowsError(try LocalDownload(destination: url))
        let download = try LocalDownload(destination: url, authorizedIdentity: LocalDownload.identity(url))
        try download.receive(Data("partial".utf8)); try download.cleanUp()
        XCTAssertEqual(try Data(contentsOf: url), old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.temporary.path))
    }
    func testNewTargetRaceRequiresNewConfirmation() throws {
        let url = try target(); let download = try LocalDownload(destination: url)
        try download.receive(Data("new".utf8)); try download.closeFile()
        try Data("raced".utf8).write(to: url)
        XCTAssertThrowsError(try download.commit()) { XCTAssertTrue($0 is LocalDownload.CommitError) }
        XCTAssertEqual(try Data(contentsOf: url), Data("raced".utf8))
        try download.authorizeCurrentTarget(); try download.commit()
        XCTAssertEqual(try Data(contentsOf: url), Data("new".utf8))
    }
    func testExclusiveMoveProtectsRaceDuringCommit() throws {
        let url = try target()
        let download = try LocalDownload(destination: url, rename: { _, target, replace in
            XCTAssertFalse(replace)
            try Data("race".utf8).write(to: URL(fileURLWithPath: target))
            throw POSIXError(.EEXIST)
        })
        try download.closeFile()
        XCTAssertThrowsError(try download.commit())
        XCTAssertEqual(try Data(contentsOf: url), Data("race".utf8))
    }
    func testDiskFullCloseAndCommitFailuresPreserveOriginal() throws {
        for phase in 0..<3 {
            let url = try target(); let old = Data("original".utf8); try old.write(to: url)
            let download = try LocalDownload(destination: url, authorizedIdentity: LocalDownload.identity(url),
                write: { handle, bytes in if phase == 0 { throw POSIXError(.ENOSPC) }; try handle.write(contentsOf: bytes) },
                close: { handle in if phase == 1 { throw POSIXError(.EIO) }; try handle.close() },
                rename: { _, _, _ in throw POSIXError(.EACCES) })
            XCTAssertThrowsError(try { try download.receive(Data("new".utf8)); try download.closeFile(); try download.commit() }())
            try download.cleanUp(); XCTAssertEqual(try Data(contentsOf: url), old)
        }
    }
    func testSymlinkAndFolderRejectedAndSuccessfulEmptyCommit() throws {
        let url = try target(); let original = url.deletingLastPathComponent().appendingPathComponent("original")
        try Data("safe".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: original)
        XCTAssertThrowsError(try LocalDownload(destination: url)); XCTAssertEqual(try Data(contentsOf: original), Data("safe".utf8))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try LocalDownload(destination: url))
        try FileManager.default.removeItem(at: url)
        let download = try LocalDownload(destination: url); try download.closeFile(); try download.commit()
        XCTAssertEqual(try Data(contentsOf: url), Data())
    }
}
