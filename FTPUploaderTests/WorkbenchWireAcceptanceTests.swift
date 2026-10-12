import XCTest

/// Real FTP + production AppModel. Complements native presenter evidence; does not
/// claim that model calls alone prove a clickable window or default Return action.
@MainActor
final class WorkbenchWireAcceptanceTests: XCTestCase {
    private func wait(_ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while try !condition() {
            guard Date() < deadline else { throw POSIXError(.ETIMEDOUT) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-wire-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func connected(_ fixture: FTPFixture, path: String = "/") async throws -> AppModel {
        let base = try folder()
        let model = AppModel(client: FTPClient(), history: TransferHistory(url: base.appendingPathComponent("history.json")))
        model.address = "ftp://127.0.0.1:\(fixture.info.port)" + path
        model.connect(); try await wait { model.hasDirectory && !model.isBusy }
        return model
    }
    private func count(_ fixture: FTPFixture, _ command: String) throws -> Int {
        try fixture.commands().filter { $0["command"] == command }.count
    }
    private func evidence(_ fixture: FTPFixture, name: String, facts: [String: Any]) throws {
        let commands = try fixture.commands()
        XCTAssertFalse(commands.contains { ["DELE", "RMD", "RNFR", "RNTO", "SITE", "APPE", "REST"].contains($0["command"] ?? "") })
        var result = facts; result["commands"] = commands
        result["scope"] = "real disposable FTP / production AppModel; native presenters verified separately"
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testRealSingleRoundTripAndOverwriteCancellationWithoutSecondWrite() async throws {
        let fixture = try FTPFixture(delay: 0.1); defer { fixture.stop() }
        let model = try await connected(fixture), base = try folder()
        let source = base.appendingPathComponent("单文件 中文%#.bin"), target = base.appendingPathComponent("download.bin")
        let bytes = Data((0..<65536).map { UInt8($0 % 256) }); try bytes.write(to: source)
        let before = try fixture.commands().count
        model.selectFile(source)
        XCTAssertEqual(try fixture.commands().count, before)
        model.upload(); try await wait { model.uploadState == .succeeded && !model.isBusy }
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(source.lastPathComponent)), bytes)
        let entry = try XCTUnwrap(model.entries.first { $0.name == source.lastPathComponent })
        model.download(entry, to: target); try await wait { model.downloadState == .succeeded && !model.isBusy }
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(try count(fixture, "STOR"), 1); XCTAssertEqual(try count(fixture, "RETR"), 1)
        model.upload(); try await wait { model.overwriteRequestID != nil }
        model.cancelOverwrite(try XCTUnwrap(model.overwriteRequestID))
        XCTAssertEqual(model.uploadState, .cancelled)
        XCTAssertEqual(try count(fixture, "STOR"), 1)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(source.lastPathComponent)), bytes)
        try evidence(fixture, name: "workbench-single-round-trip", facts: ["bytes_equal": true, "bytes": bytes.count, "stor": 1, "retr": 1, "overwrite_cancel_preserved_target": true])
    }

    func testRealChangedDownloadTargetRequiresFreshDecisionAndKeepsChangedBytes() async throws {
        let fixture = try FTPFixture(delay: 1); defer { fixture.stop() }
        let bytes = Data(repeating: 42, count: 65536)
        try bytes.write(to: fixture.root.appendingPathComponent("delay.bin"))
        let model = try await connected(fixture), target = try folder().appendingPathComponent("target.bin")
        XCTAssertNotNil(model.entries.first { $0.name == "delay.bin" })
        let root = try LocalDestinationRoot(url: target.deletingLastPathComponent())
        defer { root.endAccess() }
        let sink = try LocalDestinationService(root: root).download([target.lastPathComponent])
        let job = TransferJob(direction: .download, endpoint: fixture.endpoint,
            path: try RemotePath.root.appending(name: "delay.bin", bytes: Data("delay.bin".utf8)),
            encoding: .utf8, credentials: .anonymous, localURL: target)
        let runner = FileTransferRunner(client: FTPClient(), executor: TransferExecutor())
        var decisions: [CheckedContinuation<Bool, Error>] = []
        var identities: [LocalDownload.Identity?] = []
        let running = Task {
            try await runner.runDownload(job, sink: sink, confirmTarget: { _, identity in
                identities.append(identity)
                return try await withCheckedThrowingContinuation { decisions.append($0) }
            }, progress: { _, _ in })
        }
        try await wait { try self.count(fixture, "RETR") == 1 }
        try Data("first target".utf8).write(to: target)
        try await wait { decisions.count == 1 }
        try Data("changed again, longer".utf8).write(to: target)
        decisions[0].resume(returning: true)
        try await wait { decisions.count == 2 }
        XCTAssertNotEqual(identities[0], identities[1])
        XCTAssertEqual(try Data(contentsOf: target), Data("changed again, longer".utf8))
        decisions[1].resume(returning: false)
        do { _ = try await running.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(job.outcome, .cancelled)
        XCTAssertEqual(try count(fixture, "RETR"), 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["target.bin"])
        XCTAssertEqual(try Data(contentsOf: target), Data("changed again, longer".utf8))
        try evidence(fixture, name: "workbench-changed-download-target", facts: ["retr": 1, "fresh_decision_required": true, "changed_target_preserved": true, "temporary_files_removed": true])
    }

    func testRealPausedBatchFilterDoesNotChangePlanAndRetryIsExplicit() async throws {
        let fixture = try FTPFixture(delay: 1); defer { fixture.stop() }
        let model = try await connected(fixture, path: "/等待确认"), base = try folder()
        let first = base.appendingPathComponent("a-success.bin"), second = base.appendingPathComponent("b-changed.bin")
        let tail = base.appendingPathComponent("z-waiting.bin")
        try Data([1, 2, 3]).write(to: first); try Data([4]).write(to: second); try Data([5]).write(to: tail)
        XCTAssertTrue(model.prepareUploadCollection([first, second, tail]))
        try await wait { model.collectionScan.phase == .preview }
        let plan = try XCTUnwrap(model.collectionScan.plan)
        XCTAssertEqual(try count(fixture, "STOR"), 0)
        XCTAssertTrue(model.confirmCollection(plan.id))
        try await wait { model.batch.items.first?.state == .awaitingCompletion }
        try Data([9, 8, 7, 6]).write(to: second)
        try await wait { model.batch.state == .paused }
        let original = model.batch.taskResults, failed = try XCTUnwrap(model.batch.items.first { if case .failed = $0.state { return true }; return false })
        let commandsBeforeFilter = try fixture.commands().count
        for query in ["no-match", "中文", "", "%#"] { _ = DirectoryFiltering.filtered(model.entries, query: query) }
        XCTAssertEqual(try fixture.commands().count, commandsBeforeFilter)
        XCTAssertEqual(model.batch.collectionPlanID, plan.id); XCTAssertEqual(model.batch.taskResults, original)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(try count(fixture, "STOR"), 1, "Paused failure must not retry automatically")
        XCTAssertTrue(model.prepareCollectionRetry(itemID: failed.id))
        try await wait { model.collectionScan.phase == .preview }
        let retry = try XCTUnwrap(model.collectionScan.plan)
        XCTAssertEqual(retry.nodes.count, 1); XCTAssertNotEqual(retry.id, plan.id)
        XCTAssertEqual(try count(fixture, "STOR"), 1, "Retry preview is not authorization")
        XCTAssertTrue(model.confirmCollection(retry.id))
        try await wait { model.retryBatch.state == .finished }
        XCTAssertTrue(model.retryBatch.summary?.allSuccessful == true)
        XCTAssertEqual(model.batch.taskResults, original); XCTAssertEqual(model.batch.state, .paused)
        model.continueQueue(model.batch); try await wait { !model.isBusy }
        let remote = fixture.root.appendingPathComponent("等待确认")
        XCTAssertEqual(try Data(contentsOf: remote.appendingPathComponent(first.lastPathComponent)), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: remote.appendingPathComponent(second.lastPathComponent)), Data([9, 8, 7, 6]))
        XCTAssertEqual(try Data(contentsOf: remote.appendingPathComponent(tail.lastPathComponent)), Data([5]))
        XCTAssertEqual(try count(fixture, "STOR"), 3)
        XCTAssertFalse(model.sessionSummary?.allSuccessful ?? true, "Independent retry must not rewrite original failure")
        try evidence(fixture, name: "workbench-explicit-retry", facts: ["stor": 3, "original_failed_result_preserved": true, "retry_nodes": 1, "bytes_equal": true, "filter_added_requests": 0])
    }
}
