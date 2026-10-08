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
