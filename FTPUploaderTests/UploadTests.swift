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

    func testCancelledUploadNeverSendsStoreAndNextTokenCanUpload() async throws {
        let fixture = try FTPFixture()
        defer { fixture.stop() }
        let file = try sourceFile(data: Data("cancelled".utf8))
        defer { removeSource(file) }
        let client = FTPClient()
        let cancelled = FTPCancellationToken()
        cancelled.cancel(); cancelled.cancel()
        do {
            try await client.upload(endpoint: fixture.endpoint, path: .root, file: file, encoding: .utf8,
                                    cancellation: cancelled) { _, _ in XCTFail("Cancelled progress") }
            XCTFail("Cancelled upload succeeded")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(try fixture.commands().isEmpty)
        try await client.upload(endpoint: fixture.endpoint, path: folder("共享 资料%#"), file: file, encoding: .utf8,
                                cancellation: FTPCancellationToken()) { _, _ in }
        XCTAssertEqual(try fixture.commands().filter { $0["command"] == "STOR" }.count, 1)
    }

    func testCancellationStopsStallAndFinalAcknowledgementWithinTwoSeconds() async throws {
        for name in ["超时", "等待确认"] {
            let fixture = try FTPFixture(delay: 10)
            defer { fixture.stop() }
            let file = try sourceFile(data: Data(repeating: 42, count: 16 * 1024 * 1024))
            defer { removeSource(file) }
            let token = FTPCancellationToken()
            let record = ProgressRecord()
            let task = Task {
                try await FTPClient().upload(endpoint: fixture.endpoint, path: folder(name), file: file,
                                             encoding: .utf8, cancellation: token) { record.update($0, $1) }
            }
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if name == "等待确认" ? record.full : (try fixture.commands().contains { $0["command"] == "STOR" }) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            if name == "等待确认" { XCTAssertTrue(record.full) }
            let start = Date()
            token.cancel()
            do { try await task.value; XCTFail("Cancelled upload succeeded") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 2, name)
            let timing = XCTAttachment(string: "Cancellation latency for \(name): \(elapsed) seconds")
            timing.name = "cancellation-" + name
            timing.lifetime = .keepAlways
            add(timing)
            XCTAssertEqual(try fixture.commands().filter { $0["command"] == "STOR" }.count, 1)
            XCTAssertTrue(Set(try fixture.commands().compactMap { $0["command"] }).isDisjoint(with: ["DELE", "RNFR", "RNTO", "MKD", "APPE", "REST"]))
        }
    }

    func testTargetChecksAreReadOnlyForNewFileFileDirectoryDenialAndCancellation() async throws {
        for scenario in ["normal", "deny-list", "slow-list"] {
            let fixture = try FTPFixture(scenario: scenario, delay: 10)
            defer { fixture.stop() }
            let client = FTPClient()
            let token = FTPCancellationToken()
            if scenario == "normal" {
                let path = try folder("共享 资料%#")
                let new = try await client.checkUploadTarget(endpoint: fixture.endpoint, path: path, name: "new.txt", encoding: .utf8, credentials: .anonymous, cancellation: token)
                XCTAssertNil(new)
                let file = try await client.checkUploadTarget(endpoint: fixture.endpoint, path: path, name: "已提交.txt", encoding: .utf8, credentials: .anonymous, cancellation: token)
                XCTAssertEqual(file?.isDirectory, false)
                let directory = try await client.checkUploadTarget(endpoint: fixture.endpoint, path: path, name: "项目文件", encoding: .utf8, credentials: .anonymous, cancellation: token)
                XCTAssertEqual(directory?.isDirectory, true)
            } else {
                let operation = Task {
                    try await client.checkUploadTarget(endpoint: fixture.endpoint, path: .root, name: "new.txt", encoding: .utf8, credentials: .anonymous, cancellation: token)
                }
                if scenario == "slow-list" {
                    let deadline = Date().addingTimeInterval(3)
                    while !(try fixture.commands().contains { $0["command"] == "MLSD" }) && Date() < deadline {
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    token.cancel()
                }
                do { _ = try await operation.value; XCTFail("Check unexpectedly succeeded") }
                catch { if scenario == "slow-list" { XCTAssertTrue(error is CancellationError) } }
            }
            XCTAssertFalse(try fixture.commands().contains { $0["command"] == "STOR" })
        }
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
    func testSFTPBinaryEmptyDenialDisconnectAndCloseFailure() async throws {
        let credentials = try FTPCredentials.account(username: "member", password: "fixture-pass:@ ")
        for scenario in ["normal", "reject-close", "disconnect"] {
            let fixture = try SFTPFixture(scenario: scenario); defer { fixture.stop() }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+"/hosts.json")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let trust = HostTrustStore(url: url); try trust.trust(fixture.identity)
            let client = FTPClient(responseTimeout: 3, trust: trust)
            let bytes = Data((0..<65536).map { UInt8($0 % 256) })
            let file = try sourceFile(data: bytes); defer { removeSource(file) }
            if scenario == "normal" {
                for data in [bytes, Data()] {
                    let local = try sourceFile(name: UUID().uuidString+" 中文 %#.bin", data: data); defer { removeSource(local) }
                    try await client.upload(endpoint: fixture.endpoint, path: .root, file: local, encoding: .utf8, credentials: credentials) { _,_ in }
                    XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(local.lastPathComponent)), data)
                }
                let protected = try sourceFile(name: "已提交.txt", data: bytes); defer { removeSource(protected) }
                let path = try folder("中文 空格%#")
                let existing = try await client.checkUploadTarget(endpoint: fixture.endpoint, path: path, name: protected.lastPathComponent,
                                                                 encoding: .utf8, credentials: credentials, cancellation: FTPCancellationToken())
                XCTAssertNotNil(existing)
                do { try await client.upload(endpoint: fixture.endpoint, path: path, file: protected, encoding: .utf8, credentials: credentials) { _,_ in }; XCTFail("Permission rejection accepted") }
                catch { XCTAssertTrue(error.localizedDescription.contains("SFTP 3")) }
                XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("中文 空格%#/已提交.txt")), Data("protected\n".utf8))
            } else {
                do { try await client.upload(endpoint: fixture.endpoint, path: .root, file: file, encoding: .utf8, credentials: credentials) { _,_ in }; XCTFail("Unconfirmed upload succeeded") }
                catch { XCTAssertFalse(error.localizedDescription.contains("fixture-pass:@ ")); XCTAssertFalse(error.localizedDescription.contains("FTP 226")) }
            }
        }
    }

    func testSFTPCancelsStalledWriteAndFinalCloseWithoutDeleting() async throws {
        for scenario in ["slow-upload", "delay-close"] {
            let fixture = try SFTPFixture(scenario: scenario, delay: 10); defer { fixture.stop() }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+"/hosts.json")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let trust = HostTrustStore(url: url); try trust.trust(fixture.identity)
            let client = FTPClient(trust: trust)
            let file = try sourceFile(data: Data(repeating: 17, count: scenario == "delay-close" ? 1024 : 1024*1024)); defer { removeSource(file) }
            let token = FTPCancellationToken()
            let credentials = try FTPCredentials.account(username: "member", password: "fixture-pass:@ ")
            let operation = Task { try await client.upload(endpoint: fixture.endpoint, path: .root, file: file, encoding: .utf8,
                                     credentials: credentials, cancellation: token) { _,_ in } }
            try await Task.sleep(nanoseconds: 300_000_000)
            let started = Date(); token.cancel()
            do { try await operation.value; XCTFail("Cancelled SFTP upload succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(file.lastPathComponent).path))
        }
    }

}

private final class DownloadBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ bytes: Data) { lock.lock(); storage.append(bytes); lock.unlock() }
}

final class DownloadTransportTests: XCTestCase {
    private func remote(_ name: String) throws -> RemotePath { try RemotePath.root.appending(name: name, bytes: Data(name.utf8)) }
    private var ca: String { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/tls-fixtures/ca.pem").path }

    func testFTPAndBothFTPSStreamBinaryEmptyAndRequireFinalResponse() async throws {
        for transport in [FileTransport.ftp, .ftpsExplicit, .ftpsImplicit] {
            let fixture = try FTPFixture(transport: transport); defer { fixture.stop() }
            let client = FTPClient(caFile: ca)
            for payload in [Data(), Data((0..<65536).map { UInt8($0 % 256) })] {
                let name = "binary %#.bin"
                try payload.write(to: fixture.root.appendingPathComponent(name))
                let bytes = DownloadBytes()
                try await client.download(endpoint: fixture.endpoint, path: remote(name), credentials: .anonymous,
                                          cancellation: FTPCancellationToken(), receive: bytes.append) { _, _ in }
                XCTAssertEqual(bytes.data, payload)
            }
            for name in ["denied.bin", "disconnect.bin", "reject.bin"] {
                try Data(repeating: 23, count: 65536).write(to: fixture.root.appendingPathComponent(name))
                let bytes = DownloadBytes()
                do {
                    try await client.download(endpoint: fixture.endpoint, path: remote(name), credentials: .anonymous,
                                              cancellation: FTPCancellationToken(), receive: bytes.append) { _, _ in }
                    XCTFail("Expected \(name) failure for \(transport)")
                } catch { }
                if name == "reject.bin" { XCTAssertEqual(bytes.data.count, 65536) }
                if name == "denied.bin" { XCTAssertTrue(bytes.data.isEmpty) }
            }
        }
    }

    func testSFTPStreamsBinaryEmptyAndRejectsPermissionsDisconnectAndClose() async throws {
        for scenario in ["normal", "reject-close"] {
            let fixture = try SFTPFixture(scenario: scenario); defer { fixture.stop() }
            let trust = HostTrustStore(url: fixture.root.appendingPathComponent(".trust.json"))
            try trust.trust(fixture.identity)
            let client = FTPClient(trust: trust)
            let credentials = try FTPCredentials.account(username: "member", password: "fixture-pass:@ ")
            for payload in [Data(), Data(repeating: 173, count: 65536)] {
                try payload.write(to: fixture.root.appendingPathComponent("binary.bin"))
                let bytes = DownloadBytes()
                do {
                    try await client.download(endpoint: fixture.endpoint, path: remote("binary.bin"), credentials: credentials,
                                              cancellation: FTPCancellationToken(), receive: bytes.append) { _, _ in }
                    if scenario == "reject-close" { XCTFail("Must wait for successful close") }
                } catch { if scenario == "normal" { throw error } }
                XCTAssertEqual(bytes.data, payload)
            }
            for name in ["denied.bin", "disconnect.bin"] {
                try Data(repeating: 10, count: 65536).write(to: fixture.root.appendingPathComponent(name))
                do {
                    try await client.download(endpoint: fixture.endpoint, path: remote(name), credentials: credentials,
                                              cancellation: FTPCancellationToken(), receive: { _ in }) { _, _ in }
                    XCTFail("Expected failure")
                } catch { }
            }
        }
    }

    func testDownloadCancellationAndLocalWriteFailure() async throws {
        let fixture = try FTPFixture(delay: 10); defer { fixture.stop() }
        try Data(repeating: 31, count: 65536).write(to: fixture.root.appendingPathComponent("slow.bin"))
        let client = FTPClient(); let token = FTPCancellationToken(); let bytes = DownloadBytes()
        let task = Task { try await client.download(endpoint: fixture.endpoint, path: remote("slow.bin"), credentials: .anonymous,
                                                    cancellation: token, receive: bytes.append) { _, _ in } }
        while bytes.data.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        let start = Date(); token.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        do {
            try await client.download(endpoint: fixture.endpoint, path: remote("slow.bin"), credentials: .anonymous,
                                      cancellation: FTPCancellationToken(), receive: { _ in throw FTPError.localFile("磁盘已满") }) { _, _ in }
            XCTFail("Expected local failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("磁盘已满")) }
    }
}

extension DownloadTransportTests {
    func testSFTPAndFTPSCancelDuringFinalAcknowledgement() async throws {
        for transport in [FileTransport.ftpsExplicit, .ftpsImplicit, .sftp] {
            let ftp = transport == .sftp ? nil : try FTPFixture(delay: 10, transport: transport)
            let ssh = transport == .sftp ? try SFTPFixture(scenario: "delay-close", delay: 10) : nil
            defer { ftp?.stop(); ssh?.stop() }
            let root = ftp?.root ?? ssh!.root
            let endpoint = ftp?.endpoint ?? ssh!.endpoint
            let trust = HostTrustStore(url: root.appendingPathComponent(".trust.json"))
            if let ssh { try trust.trust(ssh.identity) }
            let client = FTPClient(caFile: ca, trust: trust)
            let credentials = transport == .sftp ? try FTPCredentials.account(username: "member", password: "fixture-pass:@ ") : .anonymous
            try Data(repeating: 10, count: 65536).write(to: root.appendingPathComponent("delay.bin"))
            let bytes = DownloadBytes(); let token = FTPCancellationToken()
            let task = Task { try await client.download(endpoint: endpoint, path: remote("delay.bin"), credentials: credentials,
                                                        cancellation: token, receive: bytes.append) { _, _ in } }
            let deadline = Date().addingTimeInterval(3)
            while bytes.data.count < 65536 && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertEqual(bytes.data.count, 65536)
            let started = Date(); token.cancel()
            do { try await task.value; XCTFail("Awaiting acknowledgement is not success") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        }
    }
}

@MainActor
final class BatchTransportMatrixTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition())
    }
    func testAllTransportsSerializeAndPauseForIndependentOverwrite() async throws {
        for transport in FileTransport.allCases {
            let ftp = transport == .sftp ? nil : try FTPFixture(transport: transport)
            let ssh = transport == .sftp ? try SFTPFixture() : nil
            defer { ftp?.stop(); ssh?.stop() }
            let root = ftp?.root ?? ssh!.root
            let endpoint = ftp?.endpoint ?? ssh!.endpoint
            let trust = HostTrustStore(url: root.appendingPathComponent(".trust.json"))
            if let ssh { try trust.trust(ssh.identity) }
            let ca = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/tls-fixtures/ca.pem").path
            let client = FTPClient(caFile: ca, trust: trust)
            let queue = BatchTransferQueue(client: client, executor: TransferExecutor())
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let urls = try ["batch-a.bin", "batch-b.bin", "batch-c.bin"].map { name -> URL in
                let url = folder.appendingPathComponent(name); try Data(name.utf8).write(to: url); return url
            }
            try Data("protected".utf8).write(to: root.appendingPathComponent("batch-b.bin"))
            let credentials = transport == .sftp ? try FTPCredentials.account(username: "member", password: "fixture-pass:@ ") : .anonymous
            try queue.prepare(urls, endpoint: endpoint, path: .root, encoding: .utf8, credentials: credentials)
            let initial = try ftp?.commands() ?? ssh!.commands(); XCTAssertTrue(initial.isEmpty)
            queue.startOrContinue()
            try await wait { queue.overwriteID != nil }
            XCTAssertEqual(queue.items[0].state, .succeeded); XCTAssertEqual(queue.items[2].state, .waiting)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("batch-a.bin")), try Data(contentsOf: urls[0]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("batch-c.bin").path))
            queue.cancelCurrent(); try await wait { queue.state == .paused }
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("batch-b.bin")), Data("protected".utf8))
            queue.skip(); queue.startOrContinue(); try await wait { queue.state == .finished }
            XCTAssertEqual(queue.items[0].state, .succeeded); XCTAssertEqual(queue.items[1].state, .cancelled)
            XCTAssertEqual(queue.items[2].state, .succeeded); XCTAssertFalse(queue.hasCredentials)
            let commands = try ftp?.commands() ?? ssh!.commands()
            let writes = commands.filter { $0["command"] == (transport == .sftp ? "OPEN" : "STOR") }
            XCTAssertEqual(writes.count, 2)
        }
    }
}
