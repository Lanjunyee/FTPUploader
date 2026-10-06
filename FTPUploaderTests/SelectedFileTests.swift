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
