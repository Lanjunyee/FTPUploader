import XCTest

private final class ProgressRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var _full = false
    private var _finished = false
    private var _sent: Int64 = 0
    func update(_ sent: Int64, _ total: Int64) {
        lock.lock()
        _sent = sent
        if sent == total { _full = true }
        lock.unlock()
    }
    func finish() { lock.lock(); _finished = true; lock.unlock() }
    var full: Bool { lock.lock(); defer { lock.unlock() }; return _full }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return _finished }
    var sent: Int64 { lock.lock(); defer { lock.unlock() }; return _sent }
}

final class UploadTests: XCTestCase {
    private func sourceFile(name: String = "资料 %#.pdf", data: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ftp-source-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try data.write(to: file)
        return file
    }
    private func removeSource(_ file: URL) { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    private func folder(_ name: String, encoding: FTPTextEncoding = .utf8) throws -> RemotePath {
        try RemotePath.root.appending(name: name, bytes: encoding.encode(name))
    }

    func testBinaryUnicodeNamesAndZeroBytesReachCorrectDirectory() async throws {
        let data = Data((0..<262144).map { UInt8($0 % 256) })
        let file = try sourceFile(data: data)
        let empty = try sourceFile(name: "空文件.txt", data: Data())
        defer { removeSource(file); removeSource(empty) }
        for scenario in ["normal", "legacy"] {
            let fixture = try FTPFixture(scenario: scenario)
            defer { fixture.stop() }
            let client = FTPClient()
            let listing = try await client.list(endpoint: fixture.endpoint, path: .root)
            let destination = try XCTUnwrap(listing.entries.first { $0.name == "共享 资料%#" })
            let path = try RemotePath.root.appending(name: destination.name, bytes: destination.rawName)
            let record = ProgressRecord()
            try await client.upload(endpoint: fixture.endpoint, path: path, file: file, encoding: listing.encoding) { record.update($0, $1) }
            let received = fixture.root.appendingPathComponent(destination.name).appendingPathComponent(file.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: received), data)
            XCTAssertEqual(record.sent, Int64(data.count))
            try await client.upload(endpoint: fixture.endpoint, path: path, file: empty, encoding: listing.encoding) { _, _ in }
            let zero = fixture.root.appendingPathComponent(destination.name).appendingPathComponent(empty.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: zero).count, 0)
            let stores = try fixture.commands().filter { $0["command"] == "STOR" }
            XCTAssertEqual(stores.count, 2)
            XCTAssertEqual(stores[0]["argument"], file.lastPathComponent)
            XCTAssertEqual(stores[0]["cwd"], "/共享 资料%#")
        }
    }

    func testFullProgressWaitsForDelayedFinalReply() async throws {
        let fixture = try FTPFixture(delay: 1.5)
        defer { fixture.stop() }
        let file = try sourceFile(data: Data("wait for acknowledgement".utf8))
        defer { removeSource(file) }
        let record = ProgressRecord()
        let client = FTPClient()
        let path = try folder("等待确认")
        let operation = Task {
            try await client.upload(endpoint: fixture.endpoint, path: path, file: file, encoding: .utf8) { record.update($0, $1) }
            record.finish()
        }
        let deadline = Date().addingTimeInterval(2)
        while !record.full && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(record.full)
        XCTAssertFalse(record.finished, "Sending all bytes is not a final server confirmation")
        try await operation.value
        XCTAssertTrue(record.finished)
    }

    func testLateRejectionAndMissingFinalReplyCannotReportSuccess() async throws {
        let fixture = try FTPFixture()
        defer { fixture.stop() }
        let file = try sourceFile(data: Data(repeating: 42, count: 65536))
        defer { removeSource(file) }
        for name in ["最终拒绝", "最终断开"] {
            let record = ProgressRecord()
            do {
                try await FTPClient().upload(endpoint: fixture.endpoint, path: folder(name), file: file, encoding: .utf8) { record.update($0, $1) }
                XCTFail("Upload unexpectedly succeeded")
            } catch {
                XCTAssertTrue(record.full)
                if name == "最终拒绝" {
                    XCTAssertEqual((error as? FTPError)?.responseCode, 552)
                    XCTAssertTrue(error.localizedDescription.contains("Rejected after receiving data"))
                } else {
                    XCTAssertTrue(error.localizedDescription.contains("未能确认上传成功"))
                }
            }
        }
    }

    func testPermissionSpaceAndSameNameRejectWithoutMutationOrRetry() async throws {
        let fixture = try FTPFixture()
        defer { fixture.stop() }
        let file = try sourceFile(data: Data("submission".utf8))
        defer { removeSource(file) }
        let client = FTPClient()
        let destinationPath = try folder("共享 资料%#")
        try await client.upload(endpoint: fixture.endpoint, path: destinationPath, file: file, encoding: .utf8) { _, _ in }
        let destination = fixture.root.appendingPathComponent("共享 资料%#").appendingPathComponent(file.lastPathComponent)
        let original = try Data(contentsOf: destination)
        for (name, code) in [("共享 资料%#", 553), ("拒绝写入", 553), ("空间不足", 552)] {
            do {
                try await client.upload(endpoint: fixture.endpoint, path: folder(name), file: file, encoding: .utf8) { _, _ in }
                XCTFail("Protected upload unexpectedly succeeded")
            } catch { XCTAssertEqual((error as? FTPError)?.responseCode, code) }
        }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        let commands = try fixture.commands().map { $0["command"]! }
        XCTAssertEqual(commands.filter { $0 == "STOR" }.count, 4)
        XCTAssertTrue(Set(commands).isDisjoint(with: ["DELE", "RNFR", "RNTO", "SITE", "MKD", "APPE", "REST"]))
    }

    func testInterruptedAndStalledUploadFailAndNewOperationCanSucceed() async throws {
        let fixture = try FTPFixture(delay: 3)
        defer { fixture.stop() }
        let data = Data(repeating: 97, count: 8 * 1024 * 1024)
        let file = try sourceFile(data: data)
        defer { removeSource(file) }
        let client = FTPClient(connectTimeout: 1, responseTimeout: 1, stallTimeout: 1)
        for name in ["中断", "超时"] {
            do {
                try await client.upload(endpoint: fixture.endpoint, path: folder(name), file: file, encoding: .utf8) { _, _ in }
                XCTFail("Faulted upload unexpectedly succeeded")
            } catch { XCTAssertTrue(error.localizedDescription.contains("未能确认上传成功")) }
        }
        let partial = fixture.root.appendingPathComponent("中断").appendingPathComponent(file.lastPathComponent)
        let size = try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertGreaterThan(size, 0)
        XCTAssertLessThan(size, data.count)
        try await client.upload(endpoint: fixture.endpoint, path: folder("共享 资料%#"), file: file, encoding: .utf8) { _, _ in }
        let received = fixture.root.appendingPathComponent("共享 资料%#").appendingPathComponent(file.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: received), data)
    }

    func testMissingLocalFileNeverSendsStore() async throws {
        let fixture = try FTPFixture()
        defer { fixture.stop() }
        let client = FTPClient()
        _ = try await client.list(endpoint: fixture.endpoint, path: .root)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try await client.upload(endpoint: fixture.endpoint, path: .root, file: missing, encoding: .utf8) { _, _ in }
            XCTFail("Missing file uploaded")
        } catch { XCTAssertFalse(try fixture.commands().contains { $0["command"] == "STOR" }) }
    }
}
