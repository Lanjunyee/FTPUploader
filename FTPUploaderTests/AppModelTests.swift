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

@MainActor
private func isolatedHistory() -> TransferHistory {
    TransferHistory(url: FileManager.default.temporaryDirectory.appendingPathComponent("transfer-test-" + UUID().uuidString).appendingPathComponent("history.json"))
}

@MainActor
private final class ControlledFTP: FTPServing {
    struct BrowseRequest {
        let endpoint: FTPEndpoint
        let path: RemotePath
        let credentials: FTPCredentials
        let cancellation: FTPCancellationToken
        let continuation: CheckedContinuation<DirectoryListing, Error>
    }
    struct UploadRequest {
        let name: String
        let endpoint: FTPEndpoint
        let path: RemotePath
        let credentials: FTPCredentials
        let cancellation: FTPCancellationToken
        let progress: (Int64, Int64) -> Void
        let continuation: CheckedContinuation<Void, Error>
    }
    struct DownloadRequest {
        let path: RemotePath
        let credentials: FTPCredentials
        let cancellation: FTPCancellationToken
        let receive: (Data) throws -> Void
        let progress: (Int64, Int64) -> Void
        let continuation: CheckedContinuation<Void, Error>
    }
    struct DirectoryRequest {
        let path: RemotePath
        let credentials: FTPCredentials
        let cancellation: FTPCancellationToken
        let continuation: CheckedContinuation<Void, Error>
    }
    var directories: [DirectoryRequest] = []
    func createDirectory(endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding,
                         credentials: FTPCredentials, cancellation: FTPCancellationToken) async throws {
        try await withCheckedThrowingContinuation {
            directories.append(.init(path: path, credentials: credentials, cancellation: cancellation, continuation: $0))
        }
    }
    var downloads: [DownloadRequest] = []
    func download(endpoint: FTPEndpoint, path: RemotePath, credentials: FTPCredentials, cancellation: FTPCancellationToken,
                  receive: @escaping (Data) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws {
        try await withCheckedThrowingContinuation {
            downloads.append(DownloadRequest(path: path, credentials: credentials, cancellation: cancellation,
                                              receive: receive, progress: progress, continuation: $0))
        }
    }
    var browses: [BrowseRequest] = []
    var uploads: [UploadRequest] = []
    var uploadSources: [SelectedLocalFile.VerifiedSource] = []
    func upload(endpoint: FTPEndpoint, path: RemotePath, source: SelectedLocalFile.VerifiedSource,
                encoding: FTPTextEncoding, credentials: FTPCredentials, cancellation: FTPCancellationToken,
                progress: @escaping (Int64, Int64) -> Void) async throws {
        try source.validateDescriptor()
        uploadSources.append(source)
        defer { uploadSources.removeAll { $0 === source } }
        try await upload(endpoint: endpoint, path: path, file: source.url, encoding: encoding,
                         credentials: credentials, cancellation: cancellation, progress: progress)
    }
    var autoCheckTargets = true

    func checkUploadTarget(endpoint: FTPEndpoint, path: RemotePath, name: String, encoding: FTPTextEncoding,
                           credentials: FTPCredentials, cancellation: FTPCancellationToken) async throws -> RemoteEntry? {
        if autoCheckTargets { return nil }
        let listing = try await list(endpoint: endpoint, path: path, encoding: encoding, credentials: credentials, cancellation: cancellation)
        try cancellation.checkCancellation()
        let bytes = try encoding.encode(name)
        return listing.entries.first { $0.rawName == bytes }
    }
    func list(endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding?, credentials: FTPCredentials, cancellation: FTPCancellationToken) async throws -> DirectoryListing {
        return try await withCheckedThrowingContinuation {
            browses.append(BrowseRequest(endpoint: endpoint, path: path, credentials: credentials, cancellation: cancellation, continuation: $0))
        }
    }
    func upload(endpoint: FTPEndpoint, path: RemotePath, file: URL, encoding: FTPTextEncoding, credentials: FTPCredentials, cancellation: FTPCancellationToken,
                progress: @escaping (Int64, Int64) -> Void) async throws {
        try await withCheckedThrowingContinuation {
            uploads.append(UploadRequest(name: file.lastPathComponent, endpoint: endpoint, path: path, credentials: credentials, cancellation: cancellation, progress: progress, continuation: $0))
        }
    }
}

private final class InMemorySites: SiteStoring {
    var sites: [FTPSite]
    init(_ sites: [FTPSite] = []) { self.sites = sites }
    func load() throws -> [FTPSite] { sites }
    func save(_ sites: [FTPSite]) throws { self.sites = sites }
}

@MainActor
private final class DelayedPasswords: PasswordStoring {
    var reads: [(UUID, CheckedContinuation<String?, Error>)] = []
    func password(for site: FTPSite) async throws -> String? {
        try await withCheckedThrowingContinuation { reads.append((site.id, $0)) }
    }
    func save(_ password: String, for site: FTPSite) async throws {}
    func remove(id: UUID) async throws {}
}

@MainActor
final class SiteStateTests: XCTestCase {
    private func settle(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition())
    }

    private func site(username: String, remember: Bool = false) throws -> FTPSite {
        var d = SiteDraft(); d.host = "same.example"; d.loginMode = .account
        d.username = username; d.rememberPassword = remember
        return try d.configuration()
    }

    func testSelectedSiteDoesNotConnectAndLateDirectoryIsIgnored() async throws {
        let first = try site(username: "first"); let second = try site(username: "second")
        let fake = ControlledFTP()
        let model = AppModel(client: fake, sites: SiteManager(store: InMemorySites([first, second]), passwords: DelayedPasswords()), history: isolatedHistory())
        model.selectSite(first.id)
        XCTAssertTrue(fake.browses.isEmpty)
        model.password = "one"; model.connect()
        try await settle { fake.browses.count == 1 }
        XCTAssertEqual(fake.browses[0].credentials.username, "first")
        model.cancelOperation()
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await settle { !model.isDirectoryLoading }
        model.selectSite(second.id)
        XCTAssertFalse(model.hasDirectory); XCTAssertFalse(model.canUpload)
        XCTAssertNil(model.password)
        model.password = "two"; model.connect()
        try await settle { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await settle { model.hasDirectory }
        XCTAssertEqual(model.connectionIdentity, "FTP（不加密） · 账户：second")
        model.refresh()
        try await settle { fake.browses.count == 3 }
        XCTAssertEqual(fake.browses[2].credentials.password, "two")
        fake.browses[2].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await settle { !model.isDirectoryLoading }
        model.username = "third"
        XCTAssertFalse(model.hasDirectory); XCTAssertNil(model.password)
    }

    func testLatePasswordCannotOverwriteAnotherSiteOrManualInput() async throws {
        let first = try site(username: "first", remember: true)
        let second = try site(username: "second", remember: true)
        let passwords = DelayedPasswords()
        let model = AppModel(client: ControlledFTP(), sites: SiteManager(store: InMemorySites([first, second]), passwords: passwords), history: isolatedHistory())
        model.selectSite(first.id)
        try await settle { passwords.reads.count == 1 }
        model.selectSite(second.id)
        try await settle { passwords.reads.count == 2 }
        passwords.reads[1].1.resume(returning: "second-password")
        try await settle { !model.isPasswordLoading }
        passwords.reads[0].1.resume(returning: "first-password")
        await Task.yield()
        XCTAssertEqual(model.password, "second-password")
        model.selectSite(first.id)
        try await settle { passwords.reads.count == 3 }
        model.password = "manual"
        passwords.reads[2].1.resume(returning: "saved")
        await Task.yield()
        XCTAssertEqual(model.password, "manual")
        model.selectSite(first.id)
        try await settle { passwords.reads.count == 4 }
        model.transport = .sftp; model.authenticationMethod = .privateKey
        model.passphrase = "session phrase"
        passwords.reads[3].1.resume(returning: "late-password")
        await Task.yield()
        XCTAssertNil(model.password); XCTAssertEqual(model.authenticationMethod, .privateKey)
        XCTAssertEqual(model.passphrase, "session phrase")
    }

    func testAccountUploadSnapshotAndAllMutationEntrypointsAreLocked() async throws {
        let first = try site(username: "first")
        let fake = ControlledFTP()
        let manager = SiteManager(store: InMemorySites([first]), passwords: DelayedPasswords())
        let model = AppModel(client: fake, sites: manager, history: isolatedHistory())
        model.selectSite(first.id); model.password = "one"; model.connect()
        try await settle { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await settle { model.hasDirectory }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("bytes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        model.selectFile(file); model.upload(); model.upload()
        model.selectSite(nil); model.username = "other"; model.password = "other"; model.address = "other.example"
        model.loginMode = .anonymous
        let saved = await model.saveSite(SiteDraft(site: first)); XCTAssertFalse(saved)
        let deleted = await model.deleteSite(first); XCTAssertFalse(deleted)
        try await settle { fake.uploads.count == 1 }
        XCTAssertEqual(model.selectedSiteID, first.id); XCTAssertEqual(model.username, "first")
        XCTAssertEqual(model.password, "one"); XCTAssertEqual(model.loginMode, .account)
        XCTAssertEqual(fake.uploads[0].credentials.password, "one")
        fake.uploads[0].continuation.resume()
        try await settle { fake.browses.count == 2 }
        XCTAssertEqual(fake.browses[1].credentials.username, "first")
        fake.browses[1].continuation.resume(throwing: FTPError.incompatibleListing)
        try await settle { !model.isDirectoryLoading }
        XCTAssertEqual(model.uploadState, .succeeded)
    }

    func testSaveAndDeleteCurrentSiteNeverIssueNetworkCommands() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, sites: SiteManager(store: InMemorySites(), passwords: DelayedPasswords()), history: isolatedHistory())
        var draft = SiteDraft(); draft.host = "example.test"
        XCTAssertTrue(model.sites.sites.isEmpty)
        let saved = await model.saveSite(draft); XCTAssertTrue(saved)
        XCTAssertTrue(fake.browses.isEmpty)
        XCTAssertEqual(model.address, model.sites.sites[0].address)
        let deleted = await model.deleteSite(model.sites.sites[0]); XCTAssertTrue(deleted)
        XCTAssertTrue(model.sites.sites.isEmpty); XCTAssertNil(model.selectedSiteID)
        XCTAssertFalse(model.hasDirectory); XCTAssertTrue(fake.browses.isEmpty); XCTAssertTrue(fake.uploads.isEmpty)
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    private let destination = RemoteEntry(name: "共享", rawName: Data("共享".utf8), isDirectory: true, size: nil)

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition(), "State did not settle")
    }

    private func connect(_ model: AppModel, _ fake: ControlledFTP) async throws {
        model.address = "first.example"
        model.connect()
        try await waitUntil { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [destination], encoding: .utf8))
        try await waitUntil { model.hasDirectory }
    }

    func testActivityBarIsAbsentUntilExplicitSelectionAndKeepsResultTargetsFixed() async throws {
        let fake = ControlledFTP(), model = AppModel(client: ControlledFTP(), history: isolatedHistory())
        XCTAssertNil(TransferActivityObserver(model: model).activity)
        let connected = AppModel(client: fake, history: isolatedHistory())
        let observer = TransferActivityObserver(model: connected)
        try await connect(connected, fake)
        XCTAssertNil(observer.activity, "Connected idle must not invent a transfer bar")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("payload".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        connected.selectFile(file)
        XCTAssertEqual(observer.activity?.source, .pending)
        XCTAssertTrue(connected.canUpload)
        XCTAssertTrue(fake.uploads.isEmpty, "Selecting must not start a transfer")
        let target = try XCTUnwrap(connected.pendingTarget)
        connected.upload()
        try await waitUntil { fake.uploads.count == 1 }
        fake.uploads[0].continuation.resume()
        try await waitUntil { connected.uploadState == .succeeded && fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: DirectoryListing(entries: [destination], encoding: .utf8))
        try await waitUntil { !connected.isDirectoryLoading }
        XCTAssertEqual(observer.activity?.phase, .succeeded)
        XCTAssertEqual(TransferActivityLayout.targets(for: try XCTUnwrap(observer.activity)).count, 1)
        connected.enter(destination)
        try await waitUntil { fake.browses.count == 3 }
        fake.browses[2].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { !connected.isDirectoryLoading }
        let pending = try XCTUnwrap(observer.activity)
        XCTAssertEqual(pending.source, .pending)
        XCTAssertTrue(pending.targetDiffers)
        XCTAssertEqual(pending.previousTarget, target)
        XCTAssertEqual(pending.target, connected.pendingTarget)
        XCTAssertEqual(connected.uploadTarget, target)
        XCTAssertEqual(fake.uploads.count, 1, "Navigation must not re-upload")
    }

    func testActivityObserverForwardsActualQueueWithoutAppModelNotifications() async throws {
        let fake = ControlledFTP(), model = AppModel(client: ControlledFTP(), history: isolatedHistory())
        let observer = TransferActivityObserver(model: model)
        let queue = BatchTransferQueue(client: fake, executor: TransferExecutor())
        observer.observe(queue)
        var observed = 0, modelNotifications = 0
        let observation = observer.objectWillChange.sink { observed += 1 }
        let modelObservation = model.objectWillChange.sink { modelNotifications += 1 }
        defer { observation.cancel(); modelObservation.cancel() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("payload".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try queue.prepare([file], endpoint: FTPEndpoint(address: "example.test"), path: .root, encoding: .utf8, credentials: .anonymous)
        try await waitUntil { queue.state == .preview }
        XCTAssertGreaterThan(observed, 0)
        XCTAssertEqual(modelNotifications, 0, "Queue observation must not depend on AppModel forwarding")
        XCTAssertTrue(fake.browses.isEmpty); XCTAssertTrue(fake.uploads.isEmpty)
        XCTAssertNil(observer.activity)
        queue.cancelAll()
    }

    func testActivityReadsActualQueuePhasesAndKeepsFailedResultNonSuccessful() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        // A model-owned queue prepared directly to isolate presentation from connection commands.
        let queue = model.batch
        let observer = TransferActivityObserver(model: model)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("payload".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try queue.prepare([file], endpoint: FTPEndpoint(address: "example.test"), path: .root, encoding: .utf8, credentials: .anonymous)
        try await waitUntil { queue.state == .preview }
        XCTAssertEqual(observer.activity?.phase, .preview)
        XCTAssertEqual(observer.activity?.source, .queue(queue.id))
        XCTAssertEqual(observer.activity?.summary?.fileCount, 1)
        queue.startOrContinue()
        try await waitUntil { fake.uploads.count == 1 }
        XCTAssertEqual(observer.activity?.phase, .executing)
        fake.uploads[0].progress(7, 7)
        try await waitUntil { observer.activity?.phase == .finalizing }
        XCTAssertLessThan(try XCTUnwrap(observer.activity?.contentFraction), 1)
        fake.uploads[0].continuation.resume(throwing: FTPError.localFile("模拟失败"))
        try await waitUntil { queue.state == .paused }
        XCTAssertEqual(observer.activity?.phase, .paused)
        XCTAssertEqual(observer.activity?.summary?.failed, 1)
        XCTAssertNotNil(observer.activity?.warning)
        queue.cancelAll()
        XCTAssertEqual(observer.activity?.phase, .finished)
        XCTAssertFalse(try XCTUnwrap(observer.activity?.summary?.allSuccessful))
        XCTAssertNotNil(observer.activity?.warning)
        XCTAssertTrue(fake.browses.isEmpty); XCTAssertEqual(fake.uploads.count, 1)
        XCTAssertEqual(model.uploadState, .idle); XCTAssertEqual(model.downloadState, .idle)
        XCTAssertNil(model.selectedFile)
    }

    func testRefreshAndNavigationFailureKeepConsistentTarget() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        try await connect(model, fake)
        model.enter(destination)
        XCTAssertTrue(model.isDirectoryLoading)
        XCTAssertFalse(model.canChooseFile)
        try await waitUntil { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(throwing: FTPError.transport(code: 9, response: 550, message: "Denied", upload: false))
        try await waitUntil { !model.isDirectoryLoading }
        XCTAssertEqual(model.path, .root)
        XCTAssertEqual(model.entries, [destination])
        XCTAssertNotNil(model.directoryError)
        XCTAssertTrue(model.canChooseFile)
        model.refresh()
        XCTAssertFalse(model.canChooseFile)
        try await waitUntil { fake.browses.count == 3 }
        fake.browses[2].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { !model.isDirectoryLoading }
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testOldServerResultCannotReplaceNewConnection() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        model.address = "old.example"; model.connect()
        try await waitUntil { fake.browses.count == 1 }
        model.cancelOperation()
        model.address = "new.example"; model.connect()
        XCTAssertEqual(model.address, "old.example")
        XCTAssertTrue(model.isBusy)
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [destination], encoding: .utf8))
        try await waitUntil { !model.isBusy }
        XCTAssertTrue(model.directoryCancelled); XCTAssertFalse(model.hasDirectory)
        model.address = "new.example"; model.connect()
        try await waitUntil { fake.browses.count == 2 }
        fake.browses[0].cancellation.cancel()
        XCTAssertFalse(fake.browses[1].cancellation.isCancelled)
        fake.browses[1].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { model.hasDirectory }
        XCTAssertEqual(model.endpoint?.host, "new.example")
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testRepeatedConnectWhileLoadingIssuesOneRequestAndRetriesAfter() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        model.address = "first.example"
        model.connect()
        try await waitUntil { fake.browses.count == 1 }
        XCTAssertFalse(model.canConnect, "Connecting must be unavailable while the directory is loading")
        model.connect()
        model.connect()
        await Task.yield()
        XCTAssertEqual(fake.browses.count, 1, "Repeat submits must not issue another request")
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { model.hasDirectory }
        XCTAssertTrue(model.canConnect, "A finished request restores connecting")
        model.connect()
        try await waitUntil { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(throwing: FTPError.transport(code: 9, response: 550, message: "Denied", upload: false))
        try await waitUntil { !model.isDirectoryLoading }
        XCTAssertTrue(model.canConnect, "A failed request also restores connecting")
        model.connect()
        try await waitUntil { fake.browses.count == 3 }
        fake.browses[2].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { !model.isDirectoryLoading }
    }

    func testReconnectIsRejectedWhileLoadingWithoutTouchingTheDraft() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        model.address = "first.example"
        model.connect()
        try await waitUntil { fake.browses.count == 1 }
        XCTAssertFalse(model.reconnect(to: "second.example"))
        XCTAssertEqual(model.address, "first.example")
        await Task.yield()
        XCTAssertEqual(fake.browses.count, 1)
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { model.hasDirectory }
        XCTAssertTrue(model.reconnect(to: "second.example"))
        try await waitUntil { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { model.hasDirectory && model.endpoint?.host == "second.example" }
    }

    func testIdentityChangeRequiresANewPasswordWithoutClaimingFirstEmptyInput() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        model.address = "first.example"
        model.loginMode = .account
        XCTAssertFalse(model.identityChangedNotice, "An empty first form must not claim a cleared password")
        model.username = "member"
        model.password = "top-secret"
        XCTAssertFalse(model.identityChangedNotice)
        model.username = "other"
        XCTAssertNil(model.password, "The old password must not be reused for a new identity")
        XCTAssertTrue(model.identityChangedNotice)
        model.username = "otherx"
        XCTAssertTrue(model.identityChangedNotice, "Typing each character must not clear the requirement")
        model.password = "second"
        XCTAssertFalse(model.identityChangedNotice)
        model.address = "second.example"
        XCTAssertTrue(model.identityChangedNotice)
        model.password = ""
        XCTAssertFalse(model.identityChangedNotice, "An explicit empty password satisfies the prompt")
    }

    func testLocalFieldFailureDoesNotReachNetworkOrLookLikeDirectoryError() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        model.address = "ftp://host:70000"
        model.connect()
        await Task.yield()
        XCTAssertTrue(fake.browses.isEmpty)
        XCTAssertFalse(model.hasDirectory)
        XCTAssertNil(model.directoryError, "A local field problem must not read as a directory failure")
        XCTAssertEqual(model.fieldIssue?.field, .address)
        XCTAssertTrue(model.fieldIssue?.message.contains("端口") == true)
        model.address = "first.example"
        XCTAssertNil(model.fieldIssue, "Editing the field clears its stale reason")
        model.connect()
        try await waitUntil { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { model.hasDirectory }
        XCTAssertNil(model.fieldIssue)
    }

    func testMissingAccountFieldsReportTheirFieldAndCorrectingConnects() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        model.address = "first.example"
        model.loginMode = .account
        model.connect()
        await Task.yield()
        XCTAssertTrue(fake.browses.isEmpty)
        XCTAssertEqual(model.fieldIssue?.field, .username)
        XCTAssertNil(model.directoryError)
        model.username = "member"
        XCTAssertNil(model.fieldIssue)
        model.connect()
        await Task.yield()
        XCTAssertTrue(fake.browses.isEmpty)
        XCTAssertEqual(model.fieldIssue?.field, .password)
        model.password = "secret"
        model.connect()
        try await waitUntil { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { model.hasDirectory }
        XCTAssertNil(model.fieldIssue)
    }

    func testServerRejectionStaysADirectoryErrorWithRedactedDetail() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        model.address = "first.example"
        model.loginMode = .account
        model.username = "member"; model.password = "secret"
        model.connect()
        try await waitUntil { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(throwing: FTPError.transport(code: 9, response: 530, message: "bad secret", upload: false, mode: .account))
        try await waitUntil { !model.isDirectoryLoading }
        XCTAssertNil(model.fieldIssue)
        let detail = try XCTUnwrap(model.directoryError)
        XCTAssertTrue(detail.contains("530"))
        XCTAssertFalse(detail.contains("secret"))
    }

    func testInvalidReconnectKeepsDirectoryDraftAndPopoverState() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        try await connect(model, fake)
        let location = model.currentLocation
        XCTAssertFalse(model.reconnect(to: "sftp://elsewhere"))
        XCTAssertEqual(model.currentLocation, location)
        XCTAssertTrue(model.hasDirectory)
        XCTAssertEqual(model.fieldIssue?.field, .address)
        XCTAssertNil(model.directoryError)
        XCTAssertTrue(fake.browses.isEmpty == false)
        let browses = fake.browses.count
        XCTAssertTrue(model.reconnect(to: "other.example"))
        try await waitUntil { fake.browses.count == browses + 1 }
        XCTAssertFalse(model.hasDirectory, "A new address invalidates the old directory until it loads")
        fake.browses[browses].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { model.hasDirectory }
    }

    func testUploadIsSingleAndWaitsForFinalConfirmation() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        try await connect(model, fake)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("example".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        model.selectFile(file)
        model.upload()
        model.upload()
        model.goUp()
        model.address = "other.example"
        model.connect()
        try await waitUntil { fake.uploads.count == 1 }
        XCTAssertEqual(fake.uploads[0].endpoint.host, "first.example")
        XCTAssertFalse(model.canChooseFile)
        fake.uploads[0].progress(7, 7)
        try await waitUntil { model.uploadState == .awaitingCompletion }
        XCTAssertNotEqual(model.uploadState, .succeeded)
        fake.uploads[0].continuation.resume(throwing: FTPError.transport(code: 18, response: 552, message: "Rejected", upload: true))
        try await waitUntil { !model.isUploading }
        if case .failed = model.uploadState {} else { XCTFail("Expected failed state") }
        XCTAssertTrue(model.canUpload)
        model.upload()
        try await waitUntil { fake.uploads.count == 2 }
        XCTAssertEqual(model.sent, 0)
        fake.uploads[1].continuation.resume()
        try await waitUntil { model.uploadState == .succeeded && fake.browses.count == 2 }
        fake.browses[1].continuation.resume(throwing: FTPError.incompatibleListing)
        try await waitUntil { !model.isDirectoryLoading }
        XCTAssertEqual(model.uploadState, .succeeded, "Refresh must not undo confirmed success")
        let activity = try XCTUnwrap(TransferActivityObserver(model: model).activity)
        XCTAssertEqual(activity.phase, .succeeded)
        XCTAssertNil(activity.warning, "Directory refresh failure belongs to the directory, not the successful transfer")
        XCTAssertNotNil(model.directoryError)
        fake.uploads[0].progress(0, 7)
        await Task.yield()
        XCTAssertEqual(model.uploadState, .succeeded)
    }

    func testCancelBeforeSuccessIgnoresLateProgressAndReleasesAccessAfterStop() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        try await connect(model, fake)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("bytes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        model.selectFile(file); model.upload()
        try await waitUntil { fake.uploads.count == 1 }
        let selected = try XCTUnwrap(model.selectedFile)
        XCTAssertTrue(selected.isAccessActive)
        model.cancelOperation(); model.cancelOperation()
        XCTAssertEqual(model.uploadState, .cancelling)
        XCTAssertTrue(model.isBusy); XCTAssertFalse(model.canChooseFile)
        XCTAssertTrue(fake.uploads[0].cancellation.isCancelled)
        fake.uploads[0].progress(5, 5)
        await Task.yield()
        XCTAssertEqual(model.uploadState, .cancelling); XCTAssertEqual(model.sent, 0)
        XCTAssertTrue(selected.isAccessActive)
        fake.uploads[0].continuation.resume()
        try await waitUntil { model.uploadState == .cancelled }
        XCTAssertFalse(selected.isAccessActive)
        XCTAssertTrue(model.canUpload)
        XCTAssertEqual(fake.browses.count, 1, "Cancelled success must not refresh")
        model.upload()
        try await waitUntil { fake.uploads.count == 2 }
        fake.uploads[0].progress(5, 5)
        fake.uploads[0].cancellation.cancel()
        await Task.yield()
        XCTAssertEqual(model.sent, 0)
        XCTAssertFalse(fake.uploads[1].cancellation.isCancelled)
        fake.uploads[1].continuation.resume(throwing: CancellationError())
        try await waitUntil { !model.isBusy }
        XCTAssertFalse(selected.isAccessActive)
    }

    func testCommittedSuccessSurvivesLaterCancelAndDirectoryCancelKeepsTarget() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        try await connect(model, fake)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("bytes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        model.selectFile(file); model.upload()
        try await waitUntil { fake.uploads.count == 1 }
        fake.uploads[0].continuation.resume()
        try await waitUntil { model.uploadState == .succeeded && fake.browses.count == 2 }
        model.cancelOperation()
        XCTAssertEqual(model.uploadState, .succeeded)
        XCTAssertTrue(model.isDirectoryCancelling)
        XCTAssertFalse(fake.uploads[0].cancellation.isCancelled)
        fake.browses[1].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { !model.isBusy }
        XCTAssertEqual(model.entries, [destination]); XCTAssertEqual(model.path, .root)
        XCTAssertTrue(model.directoryCancelled)
        model.cancelOperation()
        XCTAssertEqual(model.uploadState, .succeeded)
    }

    func testPreflightFailureDirectoryAndCancelledCheckNeverUpload() async throws {
        for result in ["directory", "file", "denied", "cancelled", "new"] {
            let fake = ControlledFTP(); fake.autoCheckTargets = false
            let model = AppModel(client: fake, history: isolatedHistory())
            try await connect(model, fake)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("bytes".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            model.selectFile(file); model.upload()
            try await waitUntil { fake.browses.count == 2 }
            XCTAssertEqual(model.uploadState, .checkingTarget)
            if result == "denied" { fake.browses[1].continuation.resume(throwing: FTPError.incompatibleListing) }
            else {
                if result == "cancelled" { model.cancelOperation() }
                let entry = RemoteEntry(name: file.lastPathComponent, rawName: Data(file.lastPathComponent.utf8), isDirectory: result == "directory", size: 5)
                fake.browses[1].continuation.resume(returning: DirectoryListing(entries: result == "new" ? [] : [entry], encoding: .utf8))
            }
            if result == "new" {
                try await waitUntil { fake.uploads.count == 1 }
                fake.uploads[0].continuation.resume(throwing: FTPError.incompatibleListing)
            }
            try await waitUntil { !model.isUploading }
            if result != "new" { XCTAssertTrue(fake.uploads.isEmpty) }
            if result == "file" { XCTAssertEqual(model.uploadState, .awaitingOverwrite); XCTAssertNotNil(model.overwriteTarget) }
            if result == "directory", case .failed(let message) = model.uploadState { XCTAssertTrue(message.contains("同名目录")) }
            if result == "cancelled" { XCTAssertEqual(model.uploadState, .cancelled) }
            XCTAssertFalse(try XCTUnwrap(model.selectedFile).isAccessActive)
        }
    }

    func testOverwriteCancelDefaultAndConfirmedServerRejection() async throws {
        let fake = ControlledFTP(); fake.autoCheckTargets = false
        let model = AppModel(client: fake, history: isolatedHistory())
        try await connect(model, fake)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("bytes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let entry = RemoteEntry(name: file.lastPathComponent, rawName: Data(file.lastPathComponent.utf8), isDirectory: false, size: 5)
        for attempt in 0..<2 {
            model.selectFile(file); model.upload()
            try await waitUntil { fake.browses.count == attempt + 2 }
            fake.browses[attempt + 1].continuation.resume(returning: DirectoryListing(entries: [entry], encoding: .utf8))
            try await waitUntil { model.overwriteRequestID != nil }
            let id = try XCTUnwrap(model.overwriteRequestID)
            XCTAssertFalse(model.canUpload); XCTAssertFalse(try XCTUnwrap(model.selectedFile).isAccessActive)
            if attempt == 0 {
                model.cancelOverwrite(id)
                XCTAssertEqual(model.uploadState, .cancelled); XCTAssertTrue(fake.uploads.isEmpty)
                XCTAssertEqual(model.history.records.count, 1); XCTAssertEqual(model.history.records.first?.result, "取消")
            } else {
                model.confirmOverwrite(id); model.confirmOverwrite(id)
                try await waitUntil { fake.uploads.count == 1 }
                fake.uploads[0].continuation.resume(throwing: FTPError.transport(code: 25, response: 553, message: "Protected", upload: true))
                try await waitUntil { !model.isUploading }
                if case .failed(let reason) = model.uploadState { XCTAssertTrue(reason.contains("553")) }
                else { XCTFail("Server rejection must fail") }
                XCTAssertEqual(fake.browses.count, 3, "No automatic retry")
                XCTAssertEqual(model.history.records.count, 2); XCTAssertEqual(model.history.records.first?.result, "失败")
            }
        }
    }

    func testOverwriteAuthorizationInvalidatesOnConfigurationPathSelectionOrContentChange() async throws {
        for change in ["server", "identity", "path", "selection", "content"] {
            let fake = ControlledFTP(); fake.autoCheckTargets = false
            let model = AppModel(client: fake, history: isolatedHistory())
            try await connect(model, fake)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("bytes".utf8).write(to: file); try Data("other".utf8).write(to: other)
            defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: other) }
            model.selectFile(file); model.upload()
            try await waitUntil { fake.browses.count == 2 }
            let entry = RemoteEntry(name: file.lastPathComponent, rawName: Data(file.lastPathComponent.utf8), isDirectory: false, size: 5)
            fake.browses[1].continuation.resume(returning: DirectoryListing(entries: [entry], encoding: .utf8))
            try await waitUntil { model.overwriteRequestID != nil }
            let id = try XCTUnwrap(model.overwriteRequestID)
            switch change {
            case "server": model.address = "new.example"
            case "identity": model.loginMode = .account
            case "path": model.enter(destination)
            case "selection": model.selectFile(other)
            default:
                // Same length and restored mtime still changes the content digest.
                let original = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]!
                try Data("BYTES".utf8).write(to: file)
                try FileManager.default.setAttributes([.modificationDate: original], ofItemAtPath: file.path)
            }
            model.confirmOverwrite(id)
            if change == "path" || change == "content" {
                try await waitUntil { fake.browses.count == 3 }
                if change == "content" {
                    XCTAssertTrue(fake.uploads.isEmpty)
                    fake.browses[2].continuation.resume(returning: DirectoryListing(entries: [entry], encoding: .utf8))
                    try await waitUntil { model.overwriteRequestID != nil }
                    XCTAssertNotEqual(model.overwriteRequestID, id)
                    model.confirmOverwrite(id)
                    XCTAssertTrue(fake.uploads.isEmpty)
                    model.cancelOverwrite(try XCTUnwrap(model.overwriteRequestID))
                } else {
                    fake.browses[2].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
                    try await waitUntil { !model.isBusy }
                }
            }
            XCTAssertTrue(fake.uploads.isEmpty, change)
        }
    }

    func testInitialResolutionCancelNeverEnablesRootAsTargetAndLocksPolicy() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        model.address = "first.example/共享"; model.connect()
        try await waitUntil { fake.browses.count == 1 }
        XCTAssertEqual(fake.browses[0].path, .root)
        model.encodingPolicy = .gb18030
        XCTAssertEqual(model.encodingPolicy, .automatic)
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [destination], encoding: .utf8))
        try await waitUntil { fake.browses.count == 2 }
        XCTAssertFalse(model.hasDirectory); XCTAssertFalse(model.canUpload)
        model.cancelOperation()
        fake.browses[1].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { !model.isBusy }
        XCTAssertTrue(model.directoryCancelled); XCTAssertFalse(model.hasDirectory)
        XCTAssertEqual(model.path, .root); XCTAssertNil(model.endpoint)
    }

    func testSavedEncodingPolicyDirectPathAndDraftPreserveUserText() async throws {
        var draft = SiteDraft(); draft.host = "legacy.example"; draft.initialDirectory = "/共享"
        draft.encodingPolicy = .gb18030
        let site = try draft.configuration()
        XCTAssertEqual(site.initialDirectory, "/共享/")
        let fake = ControlledFTP()
        let model = AppModel(client: fake, sites: SiteManager(store: InMemorySites([site]), passwords: DelayedPasswords()), history: isolatedHistory())
        model.selectSite(site.id)
        XCTAssertEqual(model.encodingPolicy, .gb18030); XCTAssertTrue(fake.browses.isEmpty)
        XCTAssertEqual(model.siteDraft().initialDirectory, "/共享")
        XCTAssertEqual(model.siteDraft().encodingPolicy, .gb18030)
        model.connect()
        try await waitUntil { fake.browses.count == 1 }
        XCTAssertEqual(fake.browses[0].path.components.first?.bytes, try FTPTextEncoding.gb18030.encode("共享"))
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [], encoding: .gb18030))
        try await waitUntil { model.hasDirectory }
        XCTAssertEqual(model.path.display, "/共享")
        model.encodingPolicy = .utf8
        XCTAssertFalse(model.hasDirectory)
    }

    func testCompleteTransferControlFlowAcrossBothEncodings() async throws {
        for scenario in ["normal", "legacy"] {
            let fixture = try FTPFixture(scenario: scenario)
            defer { fixture.stop() }
            let model = AppModel(client: FTPClient(), history: isolatedHistory())
            model.address = fixture.endpoint.display + "/中文 空格%25/第二层"
            model.connect()
            try await waitUntil { model.hasDirectory && !model.isBusy }
            XCTAssertEqual(model.path.display, "/中文 空格%/第二层")
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("资料 %#.txt")
            let bytes = Data("complete transfer control pipeline".utf8)
            try bytes.write(to: file)
            model.selectFile(file); model.upload()
            try await waitUntil { model.uploadState == .succeeded && !model.isBusy }
            XCTAssertFalse(try XCTUnwrap(model.selectedFile).isAccessActive)
            XCTAssertTrue(model.entries.contains { $0.name == file.lastPathComponent })
            let remote = fixture.root.appendingPathComponent("中文 空格%").appendingPathComponent("第二层").appendingPathComponent(file.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: remote), bytes)
            model.upload()
            try await waitUntil { model.overwriteRequestID != nil }
            model.cancelOverwrite(try XCTUnwrap(model.overwriteRequestID))
            XCTAssertEqual(try fixture.commands().filter { $0["command"] == "STOR" }.count, 1)
            model.upload()
            try await waitUntil { model.overwriteRequestID != nil }
            model.confirmOverwrite(try XCTUnwrap(model.overwriteRequestID))
            try await waitUntil { !model.isUploading }
            if case .failed(let reason) = model.uploadState { XCTAssertTrue(reason.contains("553")) }
            else { XCTFail("Protected file overwrite must fail") }
            XCTAssertEqual(try Data(contentsOf: remote), bytes)
            let commands = try fixture.commands()
            XCTAssertEqual(commands.filter { $0["command"] == "STOR" }.count, 2)
            XCTAssertTrue(Set(commands.compactMap { $0["command"] }).isDisjoint(with: ["DELE", "RNFR", "RNTO", "SITE", "MKD", "APPE", "REST"]))
            let attachment = XCTAttachment(string: try String(contentsOfFile: fixture.info.log))
            attachment.name = "complete-flow-" + scenario
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testStaleCancelIDCannotStopNewOperationAndReconnectCancelKeepsValidDirectory() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        try await connect(model, fake)
        let previousPath = model.path
        model.refresh()
        let oldID = try XCTUnwrap(model.cancellationID)
        try await waitUntil { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: DirectoryListing(entries: [destination], encoding: .utf8))
        try await waitUntil { !model.isBusy }
        model.connect()
        let newID = try XCTUnwrap(model.cancellationID)
        try await waitUntil { fake.browses.count == 3 }
        XCTAssertNotEqual(oldID, newID)
        model.cancelOperation(id: oldID)
        XCTAssertFalse(model.isDirectoryCancelling)
        XCTAssertFalse(fake.browses[2].cancellation.isCancelled)
        model.cancelOperation(id: newID)
        fake.browses[2].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { !model.isBusy }
        XCTAssertTrue(model.hasDirectory)
        XCTAssertEqual(model.path, previousPath); XCTAssertEqual(model.entries, [destination])
        XCTAssertTrue(model.directoryCancelled)
    }

    func testDirectoriesAndUnreadableFilesDoNotUpload() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        try await connect(model, fake)
        model.selectFile(FileManager.default.temporaryDirectory)
        XCTAssertNil(model.selectedFile)
        XCTAssertNotNil(model.selectionError)
        model.upload()
        XCTAssertTrue(fake.uploads.isEmpty)
        model.selectFile(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertNil(model.selectedFile)
        XCTAssertNotNil(model.selectionError)
    }

    func testDropSelectsOneFileWithoutStartingUpload() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("drop".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertFalse(model.selectDroppedFiles([file]), "An unconnected app rejects drops")
        XCTAssertNil(model.selectedFile)
        XCTAssertNil(model.selectionError)
        try await connect(model, fake)
        XCTAssertTrue(model.selectDroppedFiles([file]))
        XCTAssertEqual(model.selectedFile?.url, file)
        XCTAssertEqual(model.selectedFile?.size, 4)
        XCTAssertEqual(model.pendingTarget, "ftp://first.example/" + file.lastPathComponent)
        XCTAssertEqual(model.uploadState, .idle)
        XCTAssertNil(model.uploadTarget)
        XCTAssertTrue(fake.uploads.isEmpty)
    }

    func testInvalidDropsDoNotStartUploadOrChangeResult() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        try await connect(model, fake)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("drop".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        model.selectFile(file)
        model.upload()
        try await waitUntil { fake.uploads.count == 1 }
        fake.uploads[0].continuation.resume(throwing: FTPError.incompatibleListing)
        try await waitUntil { !model.isUploading }
        let state = model.uploadState
        let target = model.uploadTarget
        let pending = model.pendingTarget
        XCTAssertFalse(model.selectDroppedFiles([file, file]))
        XCTAssertEqual(model.selectionError, "拖入项目为空、重复或超过批次上限。")
        XCTAssertEqual(model.selectedFile?.url, file)
        XCTAssertEqual(model.pendingTarget, pending)
        XCTAssertEqual(model.uploadState, state)
        XCTAssertEqual(model.uploadTarget, target)
        XCTAssertFalse(model.selectDroppedFiles([URL(string: "https://example.test/not-local")!]))
        XCTAssertEqual(model.selectedFile?.url, file, "An invalid drop must preserve the previous valid selection")
        XCTAssertNotNil(model.selectionError)
        XCTAssertEqual(model.uploadState, state)
        XCTAssertEqual(model.uploadTarget, target)
        XCTAssertEqual(fake.uploads.count, 1)
    }

    func testBusyDropsPreserveFileTargetAndUploadState() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        try await connect(model, fake)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("drop".utf8).write(to: file)
        try Data("other".utf8).write(to: other)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: other)
        }
        model.selectFile(file)
        let pending = model.pendingTarget
        model.refresh()
        XCTAssertFalse(model.selectDroppedFiles([other]))
        XCTAssertEqual(model.selectedFile?.url, file)
        XCTAssertEqual(model.pendingTarget, pending)
        XCTAssertEqual(model.uploadState, .idle)
        XCTAssertNil(model.selectionError)
        try await waitUntil { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: DirectoryListing(entries: [destination], encoding: .utf8))
        try await waitUntil { !model.isDirectoryLoading }
        model.upload()
        try await waitUntil { fake.uploads.count == 1 }
        let target = model.uploadTarget
        for state in [UploadState.uploading, .awaitingCompletion] {
            if state == .awaitingCompletion {
                fake.uploads[0].progress(4, 4)
                try await waitUntil { model.uploadState == .awaitingCompletion }
            }
            XCTAssertFalse(model.selectDroppedFiles([other]))
            XCTAssertFalse(model.selectDroppedFiles([file, other]))
            XCTAssertEqual(model.selectedFile?.url, file)
            XCTAssertEqual(model.pendingTarget, pending)
            XCTAssertEqual(model.uploadTarget, target)
            XCTAssertEqual(model.uploadState, state)
            XCTAssertNil(model.selectionError)
        }
        fake.uploads[0].continuation.resume(throwing: FTPError.incompatibleListing)
        try await waitUntil { !model.isUploading }
    }
    func testFourProtocolBrowseUploadOverwriteAndCancelMatrix() async throws {
        func settled(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertTrue(condition(), "Protocol matrix state did not settle")
        }
        for (transport, useKey) in FileTransport.allCases.map({ ($0, false) }) + [(.sftp, true)] {
            let ftp = transport == .sftp ? nil : try FTPFixture(transport: transport)
            let ssh = transport == .sftp ? try SFTPFixture(keyAuth: useKey) : nil
            defer { ftp?.stop(); ssh?.stop() }
            let endpoint = ftp?.endpoint ?? ssh!.endpoint
            let root = ftp?.root ?? ssh!.root
            let trustURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+"/hosts.json")
            defer { try? FileManager.default.removeItem(at: trustURL.deletingLastPathComponent()) }
            let trust = HostTrustStore(url: trustURL)
            if let ssh { try trust.trust(ssh.identity) }
            let ca = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/tls-fixtures/ca.pem").path
            let model = AppModel(client: FTPClient(caFile: ca, trust: trust), sites: SiteManager(store: InMemorySites(), passwords: DelayedPasswords()), history: isolatedHistory())
            model.transport = transport; model.address = endpoint.display
            model.loginMode = .account; model.username = "member"
            if useKey {
                model.authenticationMethod = .privateKey
                model.choosePrivateKey(root.appendingPathComponent(".keys/openssh-rsa"))
            } else { model.password = "fixture-pass:@ " }
            model.connect(); try await settled { !model.isDirectoryLoading }
            XCTAssertTrue(model.hasDirectory, model.directoryError ?? "No directory")
            XCTAssertEqual(model.endpoint?.transport, transport)
            XCTAssertTrue(model.connectionIdentity.contains(transport.title))
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("矩阵 %#.bin")
            let bytes = Data((0..<4096).map { UInt8($0 % 256) }); try bytes.write(to: file)
            model.selectFile(file); model.upload()
            try await settled { !model.isBusy }
            XCTAssertEqual(model.uploadState, .succeeded)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(file.lastPathComponent)), bytes)
            model.upload(); try await settled { model.uploadState == .awaitingOverwrite }
            let cancelledID = try XCTUnwrap(model.overwriteRequestID)
            model.cancelOverwrite(cancelledID)
            XCTAssertEqual(model.uploadState, .cancelled)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(file.lastPathComponent)), bytes)
            model.upload(); try await settled { model.uploadState == .awaitingOverwrite }
            model.confirmOverwrite(try XCTUnwrap(model.overwriteRequestID))
            try await settled { !model.isBusy }
            if transport == .sftp { XCTAssertEqual(model.uploadState, .succeeded) }
            else { if case .failed(let reason) = model.uploadState { XCTAssertTrue(reason.contains("553")) } else { XCTFail("Server overwrite refusal ignored") } }
            let wait = try XCTUnwrap(model.entries.first { $0.name == "等待确认" })
            model.enter(wait); try await settled { !model.isDirectoryLoading }
            model.selectFile(file); model.upload()
            try await settled { model.uploadState == .awaitingCompletion }
            let started = Date(); model.cancelOperation()
            XCTAssertEqual(model.uploadState, .cancelling)
            try await settled { !model.isBusy }
            XCTAssertEqual(model.uploadState, .cancelled)
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("等待确认").appendingPathComponent(file.lastPathComponent).path))
        }
    }

    func testPrivateKeySessionSnapshotLockingAndChangedSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = root.appendingPathComponent("key")
        try Data("-----BEGIN RSA PRIVATE KEY-----\nfixture-key".utf8).write(to: key)
        let fake = ControlledFTP(); let model = AppModel(client: fake, history: isolatedHistory())
        model.transport = .sftp; model.address = "sftp://example.test"; model.username = "member"
        model.authenticationMethod = .privateKey; model.choosePrivateKey(key); model.passphrase = "phrase"
        model.connect(); try await waitUntil { fake.browses.count == 1 }
        let material = try XCTUnwrap(fake.browses[0].credentials.privateKey)
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { model.hasDirectory }
        try Data("-----BEGIN RSA PRIVATE KEY-----\nreplacement".utf8).write(to: key)
        model.refresh(); try await waitUntil { fake.browses.count == 2 }
        XCTAssertTrue(fake.browses[1].credentials.privateKey === material)
        model.passphrase = "new" // Locked until the directory request finishes.
        XCTAssertEqual(model.passphrase, "phrase")
        fake.browses[1].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { !model.isBusy }
        model.connect()
        XCTAssertEqual(model.fieldIssue?.field, .privateKey)
        XCTAssertNil(model.passphrase)
        XCTAssertEqual(fake.browses.count, 2)
        model.choosePrivateKey(key); model.passphrase = "new"
        model.username = "other"
        XCTAssertNil(model.passphrase); XCTAssertFalse(model.hasDirectory)
        model.choosePrivateKey(key); model.passphrase = "phrase"; model.connect()
        try await waitUntil { fake.browses.count == 3 }
        weak var failedMaterial = fake.browses[2].credentials.privateKey
        fake.browses[2].continuation.resume(throwing: FieldIssue(field: .passphrase, message: "解锁失败"))
        try await waitUntil { !model.isBusy }
        fake.browses.removeAll()
        XCTAssertNil(model.passphrase); XCTAssertNil(failedMaterial)
    }

    func testEncryptedKeyTrustRetryPreservesPhraseAndIdentitySwitchClearsIt() async throws {
        let fixture = try SFTPFixture(keyAuth: true); defer { fixture.stop() }
        let store = HostTrustStore(url: fixture.root.appendingPathComponent(".model-hosts.json"))
        let model = AppModel(client: FTPClient(trust: store), history: isolatedHistory())
        model.transport = .sftp; model.address = fixture.endpoint.display; model.username = "member"
        model.authenticationMethod = .privateKey
        model.choosePrivateKey(fixture.root.appendingPathComponent(".keys/openssh-ed25519-encrypted"))
        model.passphrase = " 密钥口令:@ "; model.connect()
        try await waitUntil { model.hostTrustRequest != nil }
        XCTAssertEqual(model.passphrase, " 密钥口令:@ ")
        XCTAssertFalse(try fixture.commands().contains { $0["command"] == "AUTH_KEY" })
        model.acceptHostTrust(try XCTUnwrap(model.hostTrustRequest?.id))
        try await waitUntil { model.hasDirectory }
        XCTAssertEqual(model.passphrase, " 密钥口令:@ ")
        model.authenticationMethod = .password
        XCTAssertNil(model.passphrase); XCTAssertFalse(model.hasDirectory)
    }

}

@MainActor
final class TransferJobTests: XCTestCase {
    private func job(token: FTPCancellationToken = FTPCancellationToken()) throws -> TransferJob {
        TransferJob(direction: .upload, endpoint: try FTPEndpoint(address: "ftp://example.test:2121/fixed"),
                    path: .root, encoding: .utf8, credentials: try .account(username: "fixed", password: "secret"),
                    localURL: URL(fileURLWithPath: "/tmp/fixed.bin"), cancellation: token)
    }

    func testCancelledJobNeverStartsAndTerminalCannotBeRewritten() async throws {
        let executor = TransferExecutor(); let token = FTPCancellationToken(); token.cancel()
        let request = try job(token: token); var called = false
        do { try await executor.execute(request) { called = true }; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(called); XCTAssertEqual(request.outcome, .cancelled)
        XCTAssertFalse(request.finish(.succeeded)); XCTAssertNil(executor.activeJob)
        XCTAssertEqual(request.endpoint.port, 2121); XCTAssertEqual(request.credentials.username, "fixed")
        XCTAssertEqual(request.localURL.lastPathComponent, "fixed.bin")
    }

    func testConcurrentExecutionRefusedUntilBackendStops() async throws {
        let executor = TransferExecutor(); let first = try job(); let second = try job()
        var continuation: CheckedContinuation<Void, Never>?
        let running = Task { try await executor.execute(first) {
            await withCheckedContinuation { continuation = $0 }
        } }
        while continuation == nil { await Task.yield() }
        XCTAssertTrue(executor.activeJob === first)
        do { try await executor.execute(second) { XCTFail("Parallel operation") }; XCTFail("Expected busy") }
        catch { XCTAssertNil(second.outcome) }
        first.cancellation.cancel()
        XCTAssertTrue(executor.activeJob === first)
        continuation?.resume()
        do { try await running.value; XCTFail("Expected cancellation") } catch { }
        XCTAssertEqual(first.outcome, .cancelled); XCTAssertNil(executor.activeJob)
        try await executor.execute(second) {}
        XCTAssertEqual(second.outcome, .succeeded)
        do { try await executor.execute(second) { XCTFail("Terminal replay") }; XCTFail("Expected terminal refusal") }
        catch { XCTAssertEqual(second.outcome, .succeeded) }
    }

    func testFailureRedactsSecretAndReleasesExecutor() async throws {
        let executor = TransferExecutor(); let request = try job()
        do { try await executor.execute(request) { throw FTPError.localFile("secret refused") }; XCTFail("Expected failure") }
        catch { }
        guard case .failed(let message) = request.outcome else { return XCTFail("Expected failed outcome") }
        XCTAssertFalse(message.contains("secret")); XCTAssertNil(executor.activeJob)
    }
}

@MainActor
final class DownloadModelTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition())
    }
    func testDownloadPickerContextRejectsUnsupportedBusyAndStaleSelectionsWithoutRequests() async throws {
        let fake = ControlledFTP(), model = AppModel(client: fake, history: isolatedHistory())
        let file = RemoteEntry(name: "file", rawName: Data("file".utf8), kind: .regularFile, size: 0)
        let folder = RemoteEntry(name: "folder", rawName: Data("folder".utf8), kind: .directory, size: nil)
        let link = RemoteEntry(name: "link", rawName: Data("link".utf8), kind: .symbolicLink, size: nil)
        let entries = [file, folder, link]
        model.address = "example.test"; model.connect()
        try await wait { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: .init(entries: entries, encoding: .utf8))
        try await wait { model.hasDirectory }
        XCTAssertNil(model.captureDownloadSelection([]))
        XCTAssertNil(model.captureDownloadSelection([link]))
        XCTAssertNil(model.captureDownloadSelection([file, link]))
        XCTAssertNil(model.captureDownloadSelection([file, file]))
        let single = try XCTUnwrap(model.captureDownloadSelection([file]))
        let mixed = try XCTUnwrap(model.captureDownloadSelection([folder, file]))
        XCTAssertTrue(model.isCurrentDownloadSelection(single)); XCTAssertTrue(model.isCurrentDownloadSelection(mixed))
        for column in DirectorySortColumn.allCases {
            _ = RemoteDirectorySelection.selected(in: DirectorySorting.sorted(entries, by: column, ascending: true), ids: [file.id, folder.id])
        }
        XCTAssertEqual(fake.browses.count, 1); XCTAssertTrue(fake.downloads.isEmpty)
        XCTAssertTrue(fake.directories.isEmpty); XCTAssertNil(model.collectionScan.plan)
        model.refresh()
        XCTAssertNil(model.captureDownloadSelection([file]))
        XCTAssertFalse(model.isCurrentDownloadSelection(single))
        try await wait { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: .init(entries: entries, encoding: .utf8))
        try await wait { !model.isBusy }
        XCTAssertFalse(model.isCurrentDownloadSelection(single)); XCTAssertFalse(model.isCurrentDownloadSelection(mixed))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        model.downloadSelection(single, to: destination)
        model.downloadSelection(mixed, to: destination)
        XCTAssertTrue(fake.downloads.isEmpty); XCTAssertTrue(fake.directories.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(model.collectionScan.phase, .finished); XCTAssertTrue(model.history.records.isEmpty)
    }

    func testMixedDownloadPickerOnlyCreatesReadOnlyPreviewAndCancelLeavesDestinationEmpty() async throws {
        let fake = ControlledFTP(), model = AppModel(client: fake, history: isolatedHistory())
        let file = RemoteEntry(name: "file", rawName: Data("file".utf8), kind: .regularFile, size: 0)
        let folder = RemoteEntry(name: "folder", rawName: Data("folder".utf8), kind: .directory, size: nil)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: destination) }
        model.address = "example.test"; model.connect()
        try await wait { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: .init(entries: [file, folder], encoding: .utf8))
        try await wait { model.hasDirectory }
        let context = try XCTUnwrap(model.captureDownloadSelection([folder, file]))
        // Cancelling the system picker means never passing its context back.
        await Task.yield()
        XCTAssertEqual(fake.browses.count, 1); XCTAssertFalse(model.isBusy)
        model.downloadSelection(context, to: destination)
        try await wait { fake.browses.count == 2 }
        XCTAssertEqual(fake.browses[1].path.display, "/folder")
        fake.browses[1].continuation.resume(returning: .init(entries: [], encoding: .utf8))
        try await wait { model.collectionScan.phase == .preview }
        let plan = try XCTUnwrap(model.collectionScan.plan)
        XCTAssertEqual(plan.direction, .download); XCTAssertEqual(plan.roots.count, 2)
        XCTAssertEqual(plan.nodes.count, 2); XCTAssertTrue(plan.canStart)
        XCTAssertTrue(fake.downloads.isEmpty); XCTAssertTrue(fake.directories.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertTrue(model.history.records.isEmpty)
        model.cancelOperation()
        try await wait { !model.isBusy }
        XCTAssertNil(model.collectionScan.plan)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertTrue(fake.downloads.isEmpty); XCTAssertTrue(model.history.records.isEmpty)
    }

    func testExplicitDownloadLocksTargetAndSuccessWaitsForCommit() async throws {
        let fake = ControlledFTP(); let model = AppModel(client: fake, history: isolatedHistory())
        let entry = RemoteEntry(name: "raw.bin", rawName: Data("raw.bin".utf8), isDirectory: false, size: 3)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        model.address = "example.test"; model.connect()
        try await wait { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [entry], encoding: .utf8))
        try await wait { model.hasDirectory }
        XCTAssertTrue(fake.downloads.isEmpty)
        model.download(RemoteEntry(name: "folder", rawName: Data("folder".utf8), isDirectory: true, size: nil), to: url)
        XCTAssertTrue(fake.downloads.isEmpty)
        model.download(entry, to: url); model.address = "other.test"; model.refresh()
        try await wait { fake.downloads.count == 1 }
        XCTAssertEqual(model.address, "example.test"); XCTAssertEqual(fake.browses.count, 1)
        try fake.downloads[0].receive(Data("new".utf8))
        fake.downloads[0].progress(3, 3)
        try await wait { model.downloadState == .awaitingCompletion }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try Data("race".utf8).write(to: url)
        fake.downloads[0].continuation.resume()
        try await wait { model.downloadConfirmationID != nil }
        XCTAssertEqual(model.downloadState, .awaitingOverwrite); XCTAssertFalse(model.canEditConnection)
        XCTAssertEqual(try Data(contentsOf: url), Data("race".utf8))
        model.cancelOperation()
        try await wait { model.downloadState == .cancelled }
        XCTAssertTrue(model.canEditConnection); XCTAssertEqual(try Data(contentsOf: url), Data("race".utf8))
        model.download(entry, to: url, authorizedIdentity: try LocalDownload.identity(url))
        try await wait { fake.downloads.count == 2 }
        try fake.downloads[1].receive(Data("yes".utf8)); fake.downloads[1].continuation.resume()
        try await wait { model.downloadState == .succeeded }
        XCTAssertEqual(try Data(contentsOf: url), Data("yes".utf8))
        fake.downloads[0].progress(1, 3); await Task.yield()
        XCTAssertEqual(model.downloadState, .succeeded)
    }
}

@MainActor
final class AnchoredDownloadRunnerTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func job(_ sink: LocalDownload) throws -> TransferJob {
        TransferJob(direction: .download, endpoint: try FTPEndpoint(address: "ftp://example.test"),
                    path: try RemotePath.root.appending(name: "file", bytes: Data("file".utf8)),
                    encoding: .utf8, credentials: .anonymous, localURL: sink.destination)
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition())
    }
    func testSharedDownloadWaitsForProtocolAndCommitBeforeSuccess() async throws {
        let url = try folder(), fake = ControlledFTP(), executor = TransferExecutor()
        let service = try LocalDestinationService(root: LocalDestinationRoot(url: url))
        let sink = try service.download(["file"]), request = try job(sink)
        let runner = FileTransferRunner(client: fake, executor: executor)
        let running = Task { try await runner.runDownload(request, sink: sink, progress: { _, _ in }) }
        try await wait { fake.downloads.count == 1 }
        try fake.downloads[0].receive(Data([0, 255, 10]))
        fake.downloads[0].progress(3, 3)
        XCTAssertNil(request.outcome); XCTAssertTrue(executor.activeJob === request)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sink.destination.path))
        fake.downloads[0].continuation.resume()
        let bytes = try await running.value
        XCTAssertEqual(bytes, 3); XCTAssertEqual(request.outcome, .succeeded)
        XCTAssertEqual(try Data(contentsOf: sink.destination), Data([0, 255, 10]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sink.temporary.deletingLastPathComponent().path))
        XCTAssertNil(executor.activeJob)
    }
    func testNetworkFailureAndCancellationPreserveExistingTarget() async throws {
        for cancelled in [false, true] {
            let url = try folder(), target = url.appendingPathComponent("file"), fake = ControlledFTP()
            try Data("old".utf8).write(to: target)
            let service = try LocalDestinationService(root: LocalDestinationRoot(url: url))
            let sink = try service.download(["file"], authorizedIdentity: LocalDownload.identity(target))
            let request = try job(sink), executor = TransferExecutor()
            let runner = FileTransferRunner(client: fake, executor: executor)
            let running = Task { try await runner.runDownload(request, sink: sink, progress: { _, _ in }) }
            try await wait { fake.downloads.count == 1 }
            try fake.downloads[0].receive(Data("partial".utf8))
            if cancelled { request.cancellation.cancel() }
            XCTAssertTrue(executor.activeJob === request)
            fake.downloads[0].continuation.resume(throwing: FTPError.transport(code: 56, response: 0, message: "network failed", upload: false))
            do { _ = try await running.value; XCTFail("Expected failure") } catch { }
            if cancelled { XCTAssertEqual(request.outcome, .cancelled) }
            else { guard case .failed = request.outcome else { return XCTFail("Expected failure") } }
            XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: sink.temporary.deletingLastPathComponent().path))
            XCTAssertNil(executor.activeJob)
        }
    }
    func testCleanupWarningsDoNotRewriteBackendFailureOrCommittedSuccess() async throws {
        for success in [false, true] {
            let url = try folder(), fake = ControlledFTP()
            let service = try LocalDestinationService(root: LocalDestinationRoot(url: url))
            var operations = LocalDownload.Anchor.Operations()
            operations.remove = { _, _, _ in throw POSIXError(.EACCES) }
            let sink = try service.download(["file"], operations: operations), request = try job(sink)
            let runner = FileTransferRunner(client: fake, executor: TransferExecutor())
            var warnings: [Error] = []
            let running = Task { try await runner.runDownload(request, sink: sink,
                cleanupFailure: { warnings.append($0) }, progress: { _, _ in }) }
            try await wait { fake.downloads.count == 1 }
            try fake.downloads[0].receive(Data("new".utf8))
            if success { fake.downloads[0].continuation.resume() }
            else { fake.downloads[0].continuation.resume(throwing: FTPError.transport(code: 56, response: 0, message: "network failed", upload: false)) }
            if success {
                _ = try await running.value
                XCTAssertEqual(request.outcome, .succeeded)
                XCTAssertEqual(try Data(contentsOf: sink.destination), Data("new".utf8))
            } else {
                do { _ = try await running.value; XCTFail("Expected network failure") }
                catch { XCTAssertTrue(error is FTPError); XCTAssertTrue(error.localizedDescription.contains("network failed")) }
                guard case .failed = request.outcome else { return XCTFail("Expected failed outcome") }
                XCTAssertFalse(FileManager.default.fileExists(atPath: sink.destination.path))
            }
            XCTAssertEqual(warnings.count, 1)
            XCTAssertTrue(warnings[0].localizedDescription.contains(sink.temporary.deletingLastPathComponent().path))
        }
    }
    func testTargetChangesDuringConfirmationRequireAnotherDecision() async throws {
        let url = try folder(), fake = ControlledFTP(), executor = TransferExecutor()
        let service = try LocalDestinationService(root: LocalDestinationRoot(url: url))
        let sink = try service.download(["file"]), request = try job(sink)
        let runner = FileTransferRunner(client: fake, executor: executor)
        var decisions: [CheckedContinuation<Bool, Error>] = []
        var shown: [LocalDownload.Identity?] = []
        let running = Task { try await runner.runDownload(request, sink: sink, confirmTarget: { target, identity in
            XCTAssertEqual(target, sink.destination); shown.append(identity)
            return try await withCheckedThrowingContinuation { decisions.append($0) }
        }, progress: { _, _ in }) }
        try await wait { fake.downloads.count == 1 }
        try fake.downloads[0].receive(Data("new".utf8))
        try Data("first".utf8).write(to: sink.destination)
        fake.downloads[0].continuation.resume()
        try await wait { decisions.count == 1 }
        XCTAssertTrue(executor.activeJob === request); XCTAssertNil(request.outcome)
        try Data("second-longer".utf8).write(to: sink.destination)
        decisions[0].resume(returning: true)
        try await wait { decisions.count == 2 }
        XCTAssertNotEqual(shown[0], shown[1])
        XCTAssertEqual(try Data(contentsOf: sink.destination), Data("second-longer".utf8))
        decisions[1].resume(returning: false)
        do { _ = try await running.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(request.outcome, .cancelled); XCTAssertNil(executor.activeJob)
        XCTAssertEqual(try Data(contentsOf: sink.destination), Data("second-longer".utf8))
        XCTAssertEqual(fake.downloads.count, 1)
    }
    func testPartialCollectionKeepsSuccessfulFilesAndDirectories() async throws {
        for cancelled in [false, true] {
            let url = try folder(), fake = ControlledFTP()
            let service = try LocalDestinationService(root: LocalDestinationRoot(url: url))
            _ = try service.createDirectory(["kept"])
            _ = try service.createDirectory(["kept", "empty"])
            let runner = FileTransferRunner(client: fake, executor: TransferExecutor())
            let first = try service.download(["kept", "first"]), firstJob = try job(first)
            let firstRun = Task { try await runner.runDownload(firstJob, sink: first, progress: { _, _ in }) }
            try await wait { fake.downloads.count == 1 }
            try fake.downloads[0].receive(Data("success".utf8)); fake.downloads[0].continuation.resume()
            _ = try await firstRun.value
            let target = url.appendingPathComponent("kept/second")
            try Data("protected".utf8).write(to: target)
            let second = try service.download(["kept", "second"], authorizedIdentity: LocalDownload.identity(target))
            let secondJob = try job(second)
            let secondRun = Task { try await runner.runDownload(secondJob, sink: second, progress: { _, _ in }) }
            try await wait { fake.downloads.count == 2 }
            try fake.downloads[1].receive(Data("partial".utf8))
            if cancelled { secondJob.cancellation.cancel() }
            fake.downloads[1].continuation.resume(throwing: FTPError.transport(code: 56, response: 0, message: "failed", upload: false))
            do { _ = try await secondRun.value; XCTFail("Expected partial failure") } catch { }
            XCTAssertEqual(firstJob.outcome, .succeeded)
            XCTAssertEqual(try Data(contentsOf: first.destination), Data("success".utf8))
            XCTAssertEqual(try Data(contentsOf: target), Data("protected".utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("kept/empty").path), [])
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("kept").path)), ["first", "second", "empty"])
            XCTAssertEqual(fake.downloads.count, 2)
        }
    }

    func testCancellationWhileConfirmationWaitsPreventsCommit() async throws {
        let url = try folder(), fake = ControlledFTP(), executor = TransferExecutor()
        let service = try LocalDestinationService(root: LocalDestinationRoot(url: url))
        let sink = try service.download(["file"]), request = try job(sink)
        let runner = FileTransferRunner(client: fake, executor: executor)
        var decision: CheckedContinuation<Bool, Error>?
        let running = Task { try await runner.runDownload(request, sink: sink, confirmTarget: { _, _ in
            try await withCheckedThrowingContinuation { decision = $0 }
        }, progress: { _, _ in }) }
        try await wait { fake.downloads.count == 1 }
        try fake.downloads[0].receive(Data("new".utf8))
        try Data("race".utf8).write(to: sink.destination)
        fake.downloads[0].continuation.resume()
        try await wait { decision != nil }
        request.cancellation.cancel(); XCTAssertTrue(executor.activeJob === request)
        decision?.resume(returning: true)
        do { _ = try await running.value; XCTFail("Expected cancellation") } catch { }
        XCTAssertEqual(request.outcome, .cancelled)
        XCTAssertEqual(try Data(contentsOf: sink.destination), Data("race".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sink.temporary.deletingLastPathComponent().path))
    }
}

@MainActor
final class UploadPlanAuthorizationTests: XCTestCase {
    private func plan(outside: Bool = false) throws -> TransferPlan {
        let url = URL(fileURLWithPath: "/source/tree")
        let root = TransferPlan.Root(source: .local(url), kind: .directory)
        let relative = [RemotePath.Component(name: "tree", bytes: Data("tree".utf8))]
        let target = try RemotePath.root.appending(name: outside ? "outside" : "tree", bytes: Data((outside ? "outside" : "tree").utf8))
        let node = TransferPlan.Node(rootID: root.id, kind: .directory, source: root.source,
            target: .remote(target, .utf8), relativePath: relative, snapshot: .localDirectory(device: 1, inode: 1))
        return TransferPlan(direction: .upload, roots: [root], nodes: [node])
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition())
    }
    func testUnconfirmedOutsideAndExpiredPlansMakeZeroRequests() async throws {
        let fake = ControlledFTP(), plan = try plan()
        let authorization = try UploadPlanAuthorization(plan: plan, endpoint: FTPEndpoint(address: "example.test"),
            destination: .root, credentials: .anonymous, client: fake)
        do { _ = try await authorization.executeDirectory(nodeID: plan.nodes[0].id); XCTFail("Unconfirmed plan executed") } catch {}
        XCTAssertFalse(authorization.confirm(planID: UUID()))
        XCTAssertTrue(authorization.confirm(planID: plan.id))
        do { _ = try await authorization.executeDirectory(nodeID: UUID()); XCTFail("Outside node executed") } catch {}
        authorization.cancel()
        do { _ = try await authorization.executeDirectory(nodeID: plan.nodes[0].id); XCTFail("Expired authorization executed") } catch {}
        XCTAssertThrowsError(try UploadPlanAuthorization(plan: self.plan(outside: true), endpoint: FTPEndpoint(address: "example.test"),
            destination: .root, credentials: .anonymous, client: fake))
        XCTAssertTrue(fake.browses.isEmpty); XCTAssertTrue(fake.directories.isEmpty)
    }
    func testConfirmedDirectoryExecutesOnceAndLateCancelDoesNotRewriteSuccess() async throws {
        let fake = ControlledFTP(), plan = try plan()
        let authorization = try UploadPlanAuthorization(plan: plan, endpoint: FTPEndpoint(address: "example.test"),
            destination: .root, credentials: .anonymous, client: fake)
        XCTAssertTrue(authorization.confirm(planID: plan.id))
        let task = Task { try await authorization.executeDirectory(nodeID: plan.nodes[0].id) }
        try await wait { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: .init(entries: [], encoding: .utf8))
        try await wait { fake.directories.count == 1 }
        XCTAssertTrue(authorization.isExecuting)
        fake.directories[0].continuation.resume()
        let result = try await task.value
        XCTAssertEqual(result, .created)
        XCTAssertEqual(authorization.results[plan.nodes[0].id], .succeeded)
        authorization.cancel()
        XCTAssertEqual(authorization.results[plan.nodes[0].id], .succeeded)
        do { _ = try await authorization.executeDirectory(nodeID: plan.nodes[0].id); XCTFail("Directory retried implicitly") } catch {}
        XCTAssertEqual(fake.directories.count, 1)
    }
    func testCancellationDoesNotReleaseBusyUntilDirectoryBackendStops() async throws {
        let fake = ControlledFTP(), plan = try plan()
        let authorization = try UploadPlanAuthorization(plan: plan, endpoint: FTPEndpoint(address: "example.test"),
            destination: .root, credentials: .anonymous, client: fake)
        XCTAssertTrue(authorization.confirm(planID: plan.id))
        let task = Task { try await authorization.executeDirectory(nodeID: plan.nodes[0].id) }
        try await wait { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: .init(entries: [], encoding: .utf8))
        try await wait { fake.directories.count == 1 }
        authorization.cancel(id: UUID()); XCTAssertFalse(fake.directories[0].cancellation.isCancelled)
        authorization.cancel(id: authorization.cancellationID)
        XCTAssertTrue(authorization.isExecuting)
        XCTAssertTrue(fake.directories[0].cancellation.isCancelled)
        fake.directories[0].continuation.resume()
        do { _ = try await task.value; XCTFail("Late success after cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(authorization.isExecuting)
        XCTAssertEqual(authorization.results[plan.nodes[0].id], .cancelled)
    }
}

@MainActor
final class RemoteDirectoryCheckTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition())
    }
    private func target() throws -> RemotePath { try RemotePath.root.appending(name: "tree", bytes: Data("tree".utf8)) }
    func testExistingDirectoryReusesButFilesLinksAndUnknownRejectWithoutCreating() async throws {
        for kind in [RemoteEntry.Kind.directory, .regularFile, .symbolicLink, .other, .unknown] {
            let fake = ControlledFTP()
            let task = Task {
                try await fake.ensureDirectory(endpoint: FTPEndpoint(address: "example.test"), path: target(), encoding: .utf8,
                    credentials: .anonymous, cancellation: FTPCancellationToken())
            }
            try await wait { fake.browses.count == 1 }
            fake.browses[0].continuation.resume(returning: .init(entries: [.init(name: "tree", rawName: Data("tree".utf8), kind: kind, size: nil)], encoding: .utf8))
            do { let result = try await task.value; XCTAssertEqual(kind, .directory); XCTAssertEqual(result, .reused) }
            catch { XCTAssertNotEqual(kind, .directory); XCTAssertTrue(error is FTPError) }
            XCTAssertTrue(fake.directories.isEmpty); XCTAssertTrue(fake.uploads.isEmpty)
        }
    }
    func testCreationErrorOnlyReadOnlyVerifiedDirectoryCanSatisfyDependency() async throws {
        for response in 0..<4 {
            let fake = ControlledFTP()
            let task = Task {
                try await fake.ensureDirectory(endpoint: FTPEndpoint(address: "example.test"), path: target(), encoding: .utf8,
                    credentials: .anonymous, cancellation: FTPCancellationToken())
            }
            try await wait { fake.browses.count == 1 }
            fake.browses[0].continuation.resume(returning: .init(entries: [], encoding: .utf8))
            try await wait { fake.directories.count == 1 }
            fake.directories[0].continuation.resume(throwing: FTPError.localFile("already exists or reply lost"))
            try await wait { fake.browses.count == 2 }
            if response == 3 { fake.browses[1].continuation.resume(throwing: FTPError.localFile("cannot list")) }
            else {
                let entries: [RemoteEntry] = response == 2 ? [] : [.init(name: "tree", rawName: Data("tree".utf8), kind: response == 0 ? .directory : .regularFile, size: nil)]
                fake.browses[1].continuation.resume(returning: .init(entries: entries, encoding: .utf8))
            }
            do { let result = try await task.value; XCTAssertEqual(response, 0); XCTAssertEqual(result, .verifiedAfterError) }
            catch { XCTAssertNotEqual(response, 0) }
            XCTAssertEqual(fake.directories.count, 1, "No implicit retry")
            XCTAssertTrue(fake.uploads.isEmpty); XCTAssertTrue(fake.downloads.isEmpty)
        }
    }
    func testCancelPrecedesLateCreationSuccessAndDoesNotRecheck() async throws {
        let fake = ControlledFTP(), token = FTPCancellationToken()
        let task = Task {
            try await fake.ensureDirectory(endpoint: FTPEndpoint(address: "example.test"), path: target(), encoding: .utf8,
                credentials: .anonymous, cancellation: token)
        }
        try await wait { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: .init(entries: [], encoding: .utf8))
        try await wait { fake.directories.count == 1 }
        token.cancel(); fake.directories[0].continuation.resume()
        do { _ = try await task.value; XCTFail("Late mkdir success won cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fake.browses.count, 1)
    }
}

@MainActor
final class RemoteScanTests: XCTestCase {
    private func destination() throws -> LocalDestinationRoot {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try LocalDestinationRoot(url: url)
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition())
    }
    func testReadOnlyRecursionPreservesEachDirectoryEncodingAndEmptyDirectory() async throws {
        let fake = ControlledFTP(), destination = try destination()
        let rootName = "根 中文%#", bytes = try FTPTextEncoding.gb18030.encode(rootName)
        let entry = RemoteEntry(name: rootName, rawName: bytes, kind: .directory, size: nil)
        let path = try RemotePath.root.appending(name: rootName, bytes: bytes)
        let session = TransferScanSession()
        XCTAssertTrue(session.start { token in
            try await RemoteTransferScanner(client: fake).scan(endpoint: FTPEndpoint(address: "example.test"),
                selections: [.init(entry: entry, path: path, encoding: .gb18030)], destination: destination,
                credentials: .anonymous, cancellation: token)
        })
        try await wait { fake.browses.count == 1 }
        let sub = RemoteEntry(name: "子目录", rawName: try FTPTextEncoding.gb18030.encode("子目录"), kind: .directory, size: nil)
        fake.browses[0].continuation.resume(returning: .init(entries: [sub], encoding: .gb18030))
        try await wait { fake.browses.count == 2 }
        let file = RemoteEntry(name: "文件 UTF8", rawName: Data("文件 UTF8".utf8), kind: .regularFile, size: nil)
        let empty = RemoteEntry(name: "empty", rawName: Data("empty".utf8), kind: .directory, size: nil)
        fake.browses[1].continuation.resume(returning: .init(entries: [file, empty], encoding: .utf8))
        try await wait { fake.browses.count == 3 }
        fake.browses[2].continuation.resume(returning: .init(entries: [], encoding: .utf8))
        try await wait { session.phase == .preview }
        let plan = try XCTUnwrap(session.plan)
        XCTAssertTrue(plan.canStart); XCTAssertEqual(plan.nodes.count, 4)
        let fileNode = try XCTUnwrap(plan.nodes.first { $0.kind == .regularFile })
        XCTAssertEqual(fileNode.relativePath.map(\.bytes), [bytes, sub.rawName, file.rawName])
        guard case .remote(let filePath, let encoding) = fileNode.source else { return XCTFail("Wrong source") }
        XCTAssertEqual(filePath.components.map(\.bytes), [bytes, sub.rawName, file.rawName])
        XCTAssertEqual(encoding, .utf8)
        XCTAssertTrue(fake.uploads.isEmpty); XCTAssertTrue(fake.downloads.isEmpty); XCTAssertTrue(fake.directories.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.url.path), [])
        session.cancel(); XCTAssertEqual(session.phase, .finished); XCTAssertNil(session.plan)
    }
    func testRemoteIncompleteListingBlocksStart() async throws {
        let fake = ControlledFTP(), destination = try destination()
        let entry = RemoteEntry(name: "denied", rawName: Data("denied".utf8), kind: .directory, size: nil)
        let path = try RemotePath.root.appending(name: entry.name, bytes: entry.rawName)
        let task = Task {
            try await RemoteTransferScanner(client: fake).scan(endpoint: FTPEndpoint(address: "example.test"),
                selections: [.init(entry: entry, path: path, encoding: .utf8)], destination: destination,
                credentials: .anonymous, cancellation: FTPCancellationToken())
        }
        try await wait { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(throwing: FTPError.localFile("denied"))
        let plan = try await task.value
        XCTAssertFalse(plan.canStart)
        XCTAssertTrue(plan.issues.contains { $0.reason == .unreadable && $0.path == "/denied" })
        XCTAssertTrue(fake.downloads.isEmpty); XCTAssertTrue(fake.uploads.isEmpty)
    }

    func testFTPFixtureScanSendsOnlyReadOnlyCommandsAndDoesNotTouchDestination() async throws {
        for scenario in ["normal", "legacy"] {
            let fixture = try FTPFixture(scenario: scenario)
            defer { fixture.stop() }
            let client = FTPClient(), destination = try destination()
            let listing = try await client.list(endpoint: fixture.endpoint, path: .root)
            let entry = try XCTUnwrap(listing.entries.first { $0.name == "共享 资料%#" })
            let path = try RemotePath.root.appending(name: entry.name, bytes: entry.rawName)
            let plan = try await RemoteTransferScanner(client: client).scan(endpoint: fixture.endpoint,
                selections: [.init(entry: entry, path: path, encoding: listing.encoding)], destination: destination,
                credentials: .anonymous, cancellation: FTPCancellationToken())
            XCTAssertTrue(plan.canStart)
            XCTAssertTrue(plan.nodes.contains { $0.relativePath.last?.name == "项目文件" && $0.kind == .directory })
            XCTAssertFalse(try fixture.commands().contains { ["RETR", "STOR", "MKD", "DELE", "RNFR", "RNTO"].contains($0["command"] ?? "") })
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.url.path), [])
        }
    }

    func testLateScanResultCannotRestoreCancelledGenerationAndLockWaitsForBackend() async throws {
        let fake = ControlledFTP(), destination = try destination()
        let entry = RemoteEntry(name: "tree", rawName: Data("tree".utf8), kind: .directory, size: nil)
        let path = try RemotePath.root.appending(name: entry.name, bytes: entry.rawName)
        let session = TransferScanSession()
        let operation: (FTPCancellationToken) async throws -> TransferPlan = { token in
            try await RemoteTransferScanner(client: fake).scan(endpoint: FTPEndpoint(address: "example.test"),
                selections: [.init(entry: entry, path: path, encoding: .utf8)], destination: destination,
                credentials: .anonymous, cancellation: token)
        }
        XCTAssertTrue(session.start(operation: operation))
        try await wait { fake.browses.count == 1 }
        let generation = session.generation
        session.cancel(id: UUID()); XCTAssertEqual(session.phase, .scanning)
        session.cancel(id: session.cancellationID)
        XCTAssertEqual(session.phase, .cancelling); XCTAssertTrue(session.isLocked)
        XCTAssertFalse(session.start(operation: operation))
        XCTAssertNotEqual(session.generation, generation)
        XCTAssertTrue(fake.browses[0].cancellation.isCancelled)
        fake.browses[0].continuation.resume(returning: .init(entries: [], encoding: .utf8))
        try await wait { session.phase == .finished }
        XCTAssertNil(session.plan); XCTAssertFalse(session.isLocked)
        XCTAssertTrue(fake.uploads.isEmpty); XCTAssertTrue(fake.downloads.isEmpty)
    }
}

@MainActor
final class CollectionModelTests: XCTestCase {
    private final class ScopeCounts: @unchecked Sendable {
        private let lock = NSLock()
        private var started = 0, stopped = 0
        var counts: [Int] { lock.lock(); defer { lock.unlock() }; return [started, stopped] }
        var scope: LocalSecurityScope {
            .init(start: { _ in self.lock.lock(); self.started += 1; self.lock.unlock(); return true },
                  stop: { _ in self.lock.lock(); self.stopped += 1; self.lock.unlock() })
        }
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition())
    }
    private func entry(_ name: String, directory: Bool = false) -> RemoteEntry {
        .init(name: name, rawName: Data(name.utf8), isDirectory: directory, size: directory ? nil : 3)
    }
    private func connected(_ fake: ControlledFTP, counts: ScopeCounts, entries: [RemoteEntry]) async throws -> AppModel {
        let model = AppModel(client: fake, history: isolatedHistory(), rootScope: counts.scope)
        model.address = "example.test"; model.connect()
        try await wait { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: .init(entries: entries, encoding: .utf8))
        try await wait { model.hasDirectory }; return model
    }

    func testQueueMenuGuardsRejectIdleAndForeignQueuesWithoutRequests() async throws {
        let fake = ControlledFTP(), model = AppModel(client: ControlledFTP(), history: isolatedHistory())
        XCTAssertFalse(model.canCancelAllTransfers); XCTAssertFalse(model.canPrepareCollectionRetry())
        XCTAssertFalse(model.prepareCollectionRetry()); XCTAssertNil(model.batchOverwritePrompt)
        let queue = BatchTransferQueue(client: fake, executor: TransferExecutor())
        let file = try folder().appendingPathComponent("file")
        try Data([1]).write(to: file)
        try queue.prepare([file], endpoint: FTPEndpoint(address: "example.test"), path: .root, encoding: .utf8, credentials: .anonymous)
        defer { queue.cancelAll() }
        try await wait { queue.state == .preview }
        XCTAssertTrue(queue.canContinue)
        XCTAssertFalse(model.canContinueQueue(queue)); XCTAssertFalse(model.canSkipQueue(queue))
        model.continueQueue(queue); model.skipQueue(queue); model.cancelAllTransfers()
        XCTAssertEqual(queue.state, .preview); XCTAssertTrue(fake.uploads.isEmpty); XCTAssertTrue(fake.browses.isEmpty)
        XCTAssertFalse(queue.canBeginCollectionRetry()); XCTAssertNil(queue.beginCollectionRetry())
        let hold = UUID(); queue.holdForRetry(hold)
        XCTAssertFalse(queue.canContinue); queue.releaseRetryHold(hold); XCTAssertTrue(queue.canContinue)
    }
    func testInitialCollectionPreviewChecksTargetTypeBeforeAnyWrite() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), base = try folder(), file = base.appendingPathComponent("file")
        try Data([1]).write(to: file)
        let model = try await connected(fake, counts: counts, entries: [])
        fake.autoCheckTargets = false
        XCTAssertTrue(model.prepareUploadCollection([file]))
        try await wait { fake.browses.count == 2 }
        XCTAssertEqual(model.collectionScan.phase, .scanning); XCTAssertFalse(model.canEditConnection)
        fake.browses[1].continuation.resume(returning: .init(entries: [entry("file", directory: true)], encoding: .utf8))
        try await wait { model.collectionScan.phase == .preview }
        let plan = try XCTUnwrap(model.collectionScan.plan)
        XCTAssertEqual(plan.existingTargetIDs, [plan.nodes[0].id])
        XCTAssertTrue(plan.issues.contains { $0.reason == .typeConflict })
        XCTAssertFalse(model.confirmCollection(plan.id, policy: .overwriteExistingFiles))
        XCTAssertTrue(fake.uploads.isEmpty); XCTAssertTrue(fake.directories.isEmpty)
        model.cancelOperation(id: model.cancellationID)
        XCTAssertFalse(model.isBusy); XCTAssertEqual(counts.counts, [1, 1]); XCTAssertTrue(model.history.records.isEmpty)
    }

    func testMixedProviderDropKeepsOrderAndOnlyStartsReadonlyPreview() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), base = try folder()
        let file = base.appendingPathComponent("file"), tree = base.appendingPathComponent("tree")
        try Data([1]).write(to: file); try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        let model = try await connected(fake, counts: counts, entries: [])
        model.selectFile(file); let previous = model.selectedFile, state = model.uploadState
        var calls: [Int] = []
        XCTAssertTrue(model.receiveFileDrop(loaders: [{ calls.append(0); return tree }, { calls.append(1); return file }]))
        try await wait { model.collectionScan.phase == .preview }
        XCTAssertEqual(calls, [0, 1]); XCTAssertEqual(model.collectionScan.plan?.roots.map(\.source), [.local(tree), .local(file)])
        XCTAssertTrue(model.selectedFile === previous); XCTAssertEqual(model.uploadState, state)
        XCTAssertTrue(fake.uploads.isEmpty); XCTAssertTrue(fake.directories.isEmpty); XCTAssertEqual(model.history.records.count, 0)
        XCTAssertFalse(model.receiveFileDrop(loaders: [{ return file }]))
        model.cancelOperation(id: model.cancellationID)
        XCTAssertFalse(model.isBusy); XCTAssertTrue(model.selectedFile === previous)
        XCTAssertEqual(counts.counts, [4, 4])
        XCTAssertTrue(model.selectDroppedFiles([tree]))
        try await wait { model.collectionScan.phase == .preview }
        XCTAssertEqual(model.collectionScan.plan?.nodes.count, 1); XCTAssertTrue(model.selectedFile === previous)
        model.cancelOperation(id: model.cancellationID); XCTAssertTrue(fake.uploads.isEmpty)
    }

    func testProviderCompletionAfterNavigationAndSupersedingDropCannotChangeSelection() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), base = try folder()
        let first = base.appendingPathComponent("first"), other = base.appendingPathComponent("other")
        try Data([1]).write(to: first); try Data([2]).write(to: other)
        let model = try await connected(fake, counts: counts, entries: [])
        model.selectFile(first); let selected = model.selectedFile
        var pending: CheckedContinuation<URL, Error>?
        XCTAssertTrue(model.receiveFileDrop(loaders: [{ try await withCheckedThrowingContinuation { pending = $0 } }]))
        try await wait { pending != nil }
        model.refresh(); try await wait { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: .init(entries: [], encoding: .utf8))
        try await wait { !model.isBusy }
        pending?.resume(returning: other); pending = nil
        await Task.yield(); await Task.yield()
        XCTAssertTrue(model.selectedFile === selected); XCTAssertNil(model.selectionError)
        XCTAssertTrue(model.receiveFileDrop(loaders: [{ try await withCheckedThrowingContinuation { pending = $0 } }]))
        try await wait { pending != nil }
        XCTAssertTrue(model.receiveFileDrop(loaders: [{ return other }]))
        try await wait { model.selectedFile?.url == other }
        pending?.resume(returning: first); await Task.yield(); await Task.yield()
        XCTAssertEqual(model.selectedFile?.url, other); XCTAssertTrue(fake.uploads.isEmpty)
        XCTAssertEqual(model.collectionScan.phase, .finished)
    }

    func testProviderFailureAndLateBusyCompletionNeverStartOrOverwriteState() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), base = try folder(), file = base.appendingPathComponent("file")
        try Data([1]).write(to: file)
        let model = try await connected(fake, counts: counts, entries: [])
        model.selectFile(file); let selected = model.selectedFile
        XCTAssertTrue(model.receiveFileDrop(loaders: [{ return file }, { throw FTPError.invalidName }]))
        try await wait { model.selectionError != nil }
        XCTAssertTrue(model.selectedFile === selected); XCTAssertTrue(fake.uploads.isEmpty)
        var pending: CheckedContinuation<URL, Error>?
        XCTAssertTrue(model.receiveFileDrop(loaders: [{ try await withCheckedThrowingContinuation { pending = $0 } }]))
        try await wait { pending != nil }
        model.upload(); try await wait { fake.uploads.count == 1 }
        let state = model.uploadState, target = model.uploadTarget, error = model.selectionError
        pending?.resume(throwing: FTPError.localFile("late")); await Task.yield(); await Task.yield()
        XCTAssertEqual(model.uploadState, state); XCTAssertEqual(model.uploadTarget, target)
        XCTAssertTrue(model.selectedFile === selected); XCTAssertEqual(model.selectionError, error)
        XCTAssertEqual(model.collectionScan.phase, .finished)
        fake.uploads[0].continuation.resume()
        try await wait { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: .init(entries: [], encoding: .utf8))
        try await wait { !model.isBusy }
    }

    func testRemovingPreviewRootRescansWithNewIDsAndLastRemovalCancelsWithoutHistory() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), tree = try folder(), file = tree.appendingPathComponent("file")
        try Data([1]).write(to: file)
        let model = try await connected(fake, counts: counts, entries: [])
        model.selectFile(file); let selected = model.selectedFile
        XCTAssertTrue(model.prepareUploadCollection([tree, file]))
        try await wait { model.collectionScan.phase == .preview }
        let old = try XCTUnwrap(model.collectionScan.plan)
        XCTAssertFalse(old.canStart); XCTAssertFalse(model.confirmCollection(old.id))
        XCTAssertFalse(model.removeCollectionRoot(UUID()))
        XCTAssertTrue(model.removeCollectionRoot(old.roots[1].id))
        try await wait { model.collectionScan.phase == .preview }
        let fresh = try XCTUnwrap(model.collectionScan.plan)
        XCTAssertNotEqual(fresh.id, old.id); XCTAssertTrue(fresh.canStart); XCTAssertEqual(fresh.roots.count, 1)
        XCTAssertEqual(fresh.nodes.count, 2); XCTAssertEqual(fresh.nodes[1].parentID, fresh.nodes[0].id)
        XCTAssertFalse(model.confirmCollection(old.id)); XCTAssertEqual(model.history.records.count, 0)
        XCTAssertTrue(model.removeCollectionRoot(fresh.roots[0].id))
        XCTAssertFalse(model.isBusy); XCTAssertTrue(model.selectedFile === selected)
        XCTAssertEqual(model.history.records.count, 0); XCTAssertTrue(fake.uploads.isEmpty); XCTAssertTrue(fake.directories.isEmpty)
        XCTAssertEqual(counts.counts, [3, 3])
    }

    func testUnknownDownloadSummaryCountsReceivedPayloadButOnlyCreditsCommittedFiles() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), destination = try folder()
        let unknown = RemoteEntry(name: "unknown", rawName: Data("unknown".utf8), isDirectory: false, size: nil)
        let zero = RemoteEntry(name: "zero", rawName: Data("zero".utf8), isDirectory: false, size: 0)
        let model = try await connected(fake, counts: counts, entries: [unknown, zero])
        XCTAssertTrue(model.prepareDownloadCollection([unknown, zero], to: destination))
        try await wait { model.collectionScan.phase == .preview }
        XCTAssertNil(model.sessionSummary)
        XCTAssertTrue(model.confirmCollection(try XCTUnwrap(model.collectionScan.plan).id))
        try await wait { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: .init(entries: [unknown, zero], encoding: .utf8))
        try await wait { fake.downloads.count == 1 }
        try fake.downloads[0].receive(Data([1, 2, 3, 4]))
        let receiving = try XCTUnwrap(model.sessionSummary)
        XCTAssertEqual(receiving.actualBytes, 4); XCTAssertEqual(receiving.successfulBytes, 0)
        XCTAssertEqual(receiving.original.completedFiles, 0); XCTAssertNil(receiving.original.totalSize)
        XCTAssertNil(receiving.original.byteSuccessFraction); XCTAssertFalse(receiving.allSuccessful)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("unknown").path))
        fake.downloads[0].continuation.resume()
        try await wait { fake.browses.count == 3 }
        fake.browses[2].continuation.resume(returning: .init(entries: [unknown, zero], encoding: .utf8))
        try await wait { fake.downloads.count == 2 }
        XCTAssertEqual(model.sessionSummary?.successfulBytes, 4); XCTAssertFalse(model.sessionSummary?.allSuccessful ?? true)
        fake.downloads[1].continuation.resume(); try await wait { !model.isBusy }
        let finished = try XCTUnwrap(model.sessionSummary)
        XCTAssertEqual(finished.actualBytes, 4); XCTAssertEqual(finished.successfulBytes, 4)
        XCTAssertEqual(finished.original.completedFiles, 2); XCTAssertTrue(finished.allSuccessful)
        XCTAssertNil(finished.original.byteSuccessFraction)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("zero")), Data())
        fake.downloads[0].progress(999, 999); await Task.yield()
        XCTAssertEqual(model.sessionSummary?.actualBytes, 4)
    }

    func testFailedDownloadPayloadCountsWithoutProgressAndDoesNotCreditSuccess() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), destination = try folder(), remote = entry("file")
        let model = try await connected(fake, counts: counts, entries: [remote])
        XCTAssertTrue(model.prepareDownloadCollection([remote], to: destination))
        try await wait { model.collectionScan.phase == .preview }
        XCTAssertTrue(model.confirmCollection(try XCTUnwrap(model.collectionScan.plan).id))
        try await wait { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: .init(entries: [remote], encoding: .utf8))
        try await wait { fake.downloads.count == 1 }
        try fake.downloads[0].receive(Data([1, 2]))
        fake.downloads[0].continuation.resume(throwing: FTPError.localFile("connection lost"))
        try await wait { model.batch.state == .paused }
        XCTAssertEqual(model.sessionSummary?.actualBytes, 2); XCTAssertEqual(model.sessionSummary?.successfulBytes, 0)
        XCTAssertEqual(model.history.records.first?.bytes, 2); XCTAssertFalse(model.sessionSummary?.allSuccessful ?? true)
        model.cancelAllTransfers(); XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.sessionSummary?.original.failed, 1)
        XCTAssertEqual(model.sessionSummary?.actualBytes, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func testRetryFailureCanBeRetriedAgainWithoutChangingEitherOldFailure() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), base = try folder()
        let first = base.appendingPathComponent("first"), other = base.appendingPathComponent("other")
        try Data([1]).write(to: first); try Data([2]).write(to: other)
        let model = try await connected(fake, counts: counts, entries: [])
        XCTAssertTrue(model.prepareUploadCollection([first, other]))
        try await wait { model.collectionScan.phase == .preview }
        XCTAssertTrue(model.confirmCollection(try XCTUnwrap(model.collectionScan.plan).id))
        try await wait { fake.uploads.count == 1 }
        fake.uploads[0].continuation.resume(throwing: FTPError.localFile("first failure"))
        try await wait { model.batch.state == .paused }
        let originalResult = model.batch.taskResults, originalID = model.batch.items[0].id
        XCTAssertTrue(model.prepareCollectionRetry(itemID: originalID))
        try await wait { model.collectionScan.phase == .preview }
        XCTAssertTrue(model.confirmCollection(try XCTUnwrap(model.collectionScan.plan).id))
        let firstRetry = model.retryBatch
        try await wait { fake.uploads.count == 2 }
        fake.uploads[1].continuation.resume(throwing: FTPError.localFile("retry failure"))
        try await wait { firstRetry.state == .paused }
        let failedRetryResult = firstRetry.taskResults, failedRetryID = firstRetry.items[0].id
        XCTAssertTrue(model.prepareCollectionRetry(itemID: failedRetryID))
        try await wait { model.collectionScan.phase == .preview }
        XCTAssertTrue(model.confirmCollection(try XCTUnwrap(model.collectionScan.plan).id))
        let secondRetry = model.retryBatch
        XCTAssertTrue(firstRetry !== secondRetry); XCTAssertNotEqual(secondRetry.items[0].id, failedRetryID)
        model.batch.startOrContinue(); firstRetry.startOrContinue()
        try await wait { fake.uploads.count == 3 }
        XCTAssertEqual(model.batch.items[1].state, .waiting)
        fake.uploads[2].continuation.resume()
        try await wait { secondRetry.state == .finished && firstRetry.state == .finished }
        XCTAssertEqual(model.batch.taskResults, originalResult); XCTAssertEqual(firstRetry.taskResults, failedRetryResult)
        XCTAssertEqual(secondRetry.items[0].state, .succeeded)
        XCTAssertEqual(model.batch.state, .paused); XCTAssertEqual(model.retryBatches.count, 2)
        model.batch.startOrContinue(); try await wait { fake.uploads.count == 4 }
        fake.uploads[3].continuation.resume(); try await wait { !model.isBusy }
        XCTAssertEqual(counts.counts, [4, 4]); XCTAssertEqual(model.history.records.count, 4)
    }

    func testCancelAllNestedRetryWaitsForInnerBackendThenReleasesEveryScope() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), base = try folder()
        let first = base.appendingPathComponent("first"), other = base.appendingPathComponent("other")
        try Data([1]).write(to: first); try Data([2]).write(to: other)
        let model = try await connected(fake, counts: counts, entries: [])
        XCTAssertTrue(model.prepareUploadCollection([first, other]))
        try await wait { model.collectionScan.phase == .preview }
        XCTAssertTrue(model.confirmCollection(try XCTUnwrap(model.collectionScan.plan).id))
        try await wait { fake.uploads.count == 1 }
        fake.uploads[0].continuation.resume(throwing: FTPError.localFile("first failure"))
        try await wait { model.batch.state == .paused }
        XCTAssertTrue(model.prepareCollectionRetry(itemID: model.batch.items[0].id))
        try await wait { model.collectionScan.phase == .preview }
        XCTAssertTrue(model.confirmCollection(try XCTUnwrap(model.collectionScan.plan).id))
        let firstRetry = model.retryBatch
        try await wait { fake.uploads.count == 2 }
        fake.uploads[1].continuation.resume(throwing: FTPError.localFile("retry failure"))
        try await wait { firstRetry.state == .paused }
        let old = firstRetry.taskResults
        XCTAssertTrue(model.prepareCollectionRetry(itemID: firstRetry.items[0].id))
        try await wait { model.collectionScan.phase == .preview }
        XCTAssertTrue(model.confirmCollection(try XCTUnwrap(model.collectionScan.plan).id))
        try await wait { fake.uploads.count == 3 }
        model.cancelAllTransfers(id: model.cancellationID)
        XCTAssertTrue(model.isBusy); XCTAssertTrue(model.hasCollectionCredentials)
        XCTAssertEqual(counts.counts, [4, 0]); XCTAssertTrue(fake.uploads[2].cancellation.isCancelled)
        fake.uploads[2].continuation.resume()
        try await wait { !model.isBusy }
        XCTAssertEqual(counts.counts, [4, 4]); XCTAssertFalse(model.hasCollectionCredentials)
        XCTAssertEqual(firstRetry.taskResults, old); XCTAssertEqual(model.retryBatch.items[0].state, .cancelled)
        XCTAssertEqual(model.batch.items[1].state, .cancelled); XCTAssertEqual(model.history.records.count, 4)
        fake.uploads[2].progress(999, 999); await Task.yield()
        XCTAssertEqual(model.retryBatch.items[0].state, .cancelled)
    }

    func testPausedKeyRetryKeepsMaterialButFinishedRetryRechecksAssociation() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), base = try folder()
        let key = base.appendingPathComponent("key"), file = base.appendingPathComponent("file"), other = base.appendingPathComponent("other")
        let oldBytes = Data("-----BEGIN RSA PRIVATE KEY-----\noriginal".utf8)
        let newBytes = Data("-----BEGIN RSA PRIVATE KEY-----\nchanged".utf8)
        try oldBytes.write(to: key); try Data([1]).write(to: file); try Data([2]).write(to: other)
        let model = AppModel(client: fake, history: isolatedHistory(), rootScope: counts.scope)
        model.transport = .sftp; model.address = "example.test"; model.username = "member"
        model.authenticationMethod = .privateKey; model.choosePrivateKey(key); model.passphrase = "phrase"
        model.connect(); try await wait { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: .init(entries: [], encoding: .utf8))
        try await wait { model.hasDirectory }
        XCTAssertTrue(model.prepareUploadCollection([file, other]))
        try await wait { model.collectionScan.phase == .preview }
        XCTAssertTrue(model.confirmCollection(try XCTUnwrap(model.collectionScan.plan).id))
        try await wait { fake.uploads.count == 1 }
        let material = try XCTUnwrap(fake.uploads[0].credentials.privateKey)
        fake.uploads[0].continuation.resume(throwing: FTPError.localFile("denied"))
        try await wait { model.batch.state == .paused }
        try newBytes.write(to: key)
        XCTAssertTrue(model.prepareCollectionRetry(itemID: model.batch.items[0].id))
        try await wait { model.collectionScan.phase == .preview }
        XCTAssertTrue(model.confirmCollection(try XCTUnwrap(model.collectionScan.plan).id))
        try await wait { fake.uploads.count == 2 }
        XCTAssertTrue(fake.uploads[1].credentials.privateKey === material)
        XCTAssertEqual(fake.uploads[1].credentials.privateKey?.bytes, oldBytes)
        XCTAssertEqual(fake.uploads[1].credentials.passphrase, "phrase")
        fake.uploads[1].continuation.resume(); try await wait { model.retryBatch.state == .finished }
        model.batch.skip(); XCTAssertFalse(model.isBusy)
        let oldResults = model.batch.taskResults
        XCTAssertFalse(model.prepareCollectionRetry()); XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.fieldIssue?.field, .privateKey); XCTAssertNil(model.passphrase)
        model.choosePrivateKey(key)
        XCTAssertFalse(model.prepareCollectionRetry())
        model.connect(); try await wait { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: .init(entries: [], encoding: .utf8))
        try await wait { model.hasDirectory }
        XCTAssertTrue(model.prepareCollectionRetry())
        try await wait { model.collectionScan.phase == .preview }
        XCTAssertEqual(model.collectionScan.plan?.nodes.count, 1)
        XCTAssertTrue(model.confirmCollection(try XCTUnwrap(model.collectionScan.plan).id))
        try await wait { fake.uploads.count == 3 }
        XCTAssertEqual(fake.uploads[2].credentials.privateKey?.bytes, newBytes)
        XCTAssertFalse(fake.uploads[2].credentials.privateKey === material)
        fake.uploads[2].continuation.resume(); try await wait { !model.isBusy }
        XCTAssertEqual(model.batch.taskResults, oldResults); XCTAssertEqual(counts.counts, [4, 4])
    }

    func testFinishedDownloadRetryRefreshesOnlyFailedFileAndAsksAgainForExistingTarget() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), destination = try folder()
        let first = entry("first"), other = entry("other")
        let model = try await connected(fake, counts: counts, entries: [first, other])
        XCTAssertTrue(model.prepareDownloadCollection([first, other], to: destination))
        try await wait { model.collectionScan.phase == .preview }
        XCTAssertTrue(model.confirmCollection(try XCTUnwrap(model.collectionScan.plan).id, policy: .overwriteExistingFiles))
        try await wait { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: .init(entries: [first, other], encoding: .utf8))
        try await wait { fake.downloads.count == 1 }
        fake.downloads[0].continuation.resume(throwing: FTPError.localFile("network failed"))
        try await wait { model.batch.state == .paused }
        model.batch.skip(); model.batch.startOrContinue()
        try await wait { fake.browses.count == 3 }
        fake.browses[2].continuation.resume(returning: .init(entries: [first, other], encoding: .utf8))
        try await wait { fake.downloads.count == 2 }
        try fake.downloads[1].receive(Data([2])); fake.downloads[1].continuation.resume()
        try await wait { !model.isBusy }
        let old = model.batch.taskResults
        let target = destination.appendingPathComponent("first")
        try Data("keep".utf8).write(to: target)
        let fresh = RemoteEntry(name: "first", rawName: first.rawName, isDirectory: false, size: 5)
        XCTAssertTrue(model.canPrepareCollectionRetry()); XCTAssertTrue(model.canPrepareCollectionRetry(batchID: model.batch.collectionPlanID))
        XCTAssertTrue(model.prepareCollectionRetry())
        XCTAssertFalse(model.canPrepareCollectionRetry())
        try await wait { fake.browses.count == 4 }
        fake.browses[3].continuation.resume(returning: .init(entries: [fresh, other, entry("added")], encoding: .utf8))
        try await wait { model.collectionScan.phase == .preview }
        let retry = try XCTUnwrap(model.collectionScan.plan)
        XCTAssertEqual(retry.nodes.count, 1); XCTAssertEqual(retry.nodes[0].size, 5)
        XCTAssertEqual(retry.existingTargetIDs, [retry.nodes[0].id])
        XCTAssertEqual(model.history.records.count, 2); XCTAssertEqual(fake.downloads.count, 2)
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
        XCTAssertTrue(model.confirmCollection(retry.id))
        try await wait { fake.browses.count == 5 }
        fake.browses[4].continuation.resume(returning: .init(entries: [fresh, other], encoding: .utf8))
        try await wait { model.retryBatch.overwriteID != nil }
        XCTAssertEqual(model.retryBatch.conflictPolicy, .ask); XCTAssertEqual(fake.downloads.count, 2)
        let prompt = try XCTUnwrap(model.batchOverwritePrompt)
        XCTAssertTrue(prompt.queue === model.retryBatch); XCTAssertEqual(prompt.id, model.retryBatch.overwriteID)
        XCTAssertEqual(prompt.target, target.path)
        prompt.queue.confirmOverwrite(UUID()); XCTAssertEqual(fake.downloads.count, 2)
        prompt.queue.confirmOverwrite(prompt.id)
        try await wait { fake.downloads.count == 3 }
        try fake.downloads[2].receive(Data("fresh".utf8)); fake.downloads[2].continuation.resume()
        try await wait { !model.isBusy }
        XCTAssertEqual(try Data(contentsOf: target), Data("fresh".utf8))
        XCTAssertEqual(model.batch.taskResults, old); XCTAssertEqual(model.history.records.count, 3)
        XCTAssertEqual(counts.counts, [2, 2])
    }

    func testRetryTargetConflictIsReadOnlyAndBlocksConfirmation() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), base = try folder(), file = base.appendingPathComponent("file")
        try Data([1]).write(to: file)
        let model = try await connected(fake, counts: counts, entries: [])
        XCTAssertTrue(model.prepareUploadCollection([file]))
        try await wait { model.collectionScan.phase == .preview }
        XCTAssertTrue(model.confirmCollection(try XCTUnwrap(model.collectionScan.plan).id))
        try await wait { fake.uploads.count == 1 }
        fake.uploads[0].continuation.resume(throwing: FTPError.localFile("failure"))
        try await wait { model.batch.state == .paused }
        fake.autoCheckTargets = false
        XCTAssertTrue(model.prepareCollectionRetry(itemID: model.batch.items[0].id))
        try await wait { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: .init(entries: [entry("file", directory: true)], encoding: .utf8))
        try await wait { model.collectionScan.phase == .preview }
        let retry = try XCTUnwrap(model.collectionScan.plan)
        XCTAssertEqual(retry.existingTargetIDs, [retry.nodes[0].id])
        XCTAssertTrue(retry.issues.contains { $0.reason == .typeConflict }); XCTAssertFalse(retry.canStart)
        XCTAssertFalse(model.confirmCollection(retry.id, policy: .overwriteExistingFiles))
        XCTAssertEqual(fake.uploads.count, 1); XCTAssertTrue(fake.directories.isEmpty)
        model.cancelOperation(id: model.cancellationID)
        XCTAssertEqual(model.history.records.count, 1); XCTAssertTrue(model.isBusy)
        model.cancelAllTransfers(); XCTAssertFalse(model.isBusy); XCTAssertEqual(counts.counts, [2, 2])
    }

    func testRetryPreviewCancelRestoresOriginalPausedSummaryWithoutNewAttempt() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), base = try folder()
        let file = base.appendingPathComponent("failed")
        try Data([1]).write(to: file)
        let model = try await connected(fake, counts: counts, entries: [])
        let observer = TransferActivityObserver(model: model)
        XCTAssertTrue(model.prepareUploadCollection([file]))
        try await wait { model.collectionScan.phase == .preview }
        let plan = try XCTUnwrap(model.collectionScan.plan)
        XCTAssertTrue(model.confirmCollection(plan.id))
        try await wait { fake.uploads.count == 1 }
        fake.uploads[0].continuation.resume(throwing: FTPError.localFile("denied"))
        try await wait { model.batch.state == .paused }
        let old = model.batch.taskResults
        XCTAssertTrue(model.prepareCollectionRetry(itemID: model.batch.items[0].id))
        try await wait { model.collectionScan.phase == .preview }
        XCTAssertEqual(observer.activity?.source, .scan)
        let id = try XCTUnwrap(model.cancellationID)
        model.cancelOperation(id: id)
        try await wait { model.collectionScan.phase == .finished }
        XCTAssertEqual(observer.activity?.source, .queue(model.batch.id))
        XCTAssertEqual(observer.activity?.phase, .paused)
        XCTAssertEqual(model.batch.taskResults, old)
        XCTAssertEqual(fake.uploads.count, 1)
        XCTAssertEqual(model.history.records.count, 1)
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.canPrepareCollection)
        model.cancelAllTransfers()
        try await wait { !model.isBusy }
        XCTAssertEqual(counts.counts, [2, 2])
    }

    func testPausedFileRetryUsesNewSnapshotAndRequiresExplicitOriginalContinue() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), base = try folder()
        let first = base.appendingPathComponent("first"), other = base.appendingPathComponent("other")
        try Data([1]).write(to: first); try Data([2]).write(to: other)
        let model = try await connected(fake, counts: counts, entries: [])
        XCTAssertTrue(model.prepareUploadCollection([first, other]))
        try await wait { model.collectionScan.phase == .preview }
        let plan = try XCTUnwrap(model.collectionScan.plan)
        XCTAssertTrue(model.confirmCollection(plan.id, policy: .overwriteExistingFiles))
        try await wait { fake.uploads.count == 1 }
        fake.uploads[0].continuation.resume(throwing: FTPError.localFile("denied"))
        try await wait { model.batch.state == .paused }
        let old = model.batch.taskResults, failedID = model.batch.items[0].id
        XCTAssertFalse(model.canContinueQueue(model.batch)); XCTAssertTrue(model.canSkipQueue(model.batch))
        XCTAssertTrue(model.canPrepareCollectionRetry(itemID: failedID)); XCTAssertFalse(model.canPrepareCollectionRetry())
        model.continueQueue(model.batch); XCTAssertEqual(fake.uploads.count, 1)
        try Data([9, 8, 7]).write(to: first)
        XCTAssertTrue(model.prepareCollectionRetry(itemID: failedID))
        XCTAssertFalse(model.canPrepareCollectionRetry(itemID: failedID)); XCTAssertFalse(model.prepareCollectionRetry(itemID: failedID))
        try await wait { model.collectionScan.phase == .preview }
        let retry = try XCTUnwrap(model.collectionScan.plan)
        XCTAssertEqual(retry.nodes.count, 1); XCTAssertEqual(retry.nodes[0].size, 3)
        XCTAssertNotEqual(retry.id, plan.id); XCTAssertNotEqual(retry.roots[0].id, plan.roots[0].id)
        XCTAssertNotEqual(retry.nodes[0].id, failedID); XCTAssertEqual(model.batch.taskResults, old)
        XCTAssertEqual(fake.uploads.count, 1); XCTAssertEqual(model.history.records.count, 1)
        XCTAssertFalse(model.canContinueQueue(model.batch)); XCTAssertFalse(model.canSkipQueue(model.batch))
        XCTAssertTrue(model.canCancelAllTransfers)
        model.skipQueue(model.batch); model.continueQueue(model.batch)
        model.batch.skip(); model.batch.startOrContinue()
        XCTAssertEqual(model.batch.items[1].state, .waiting)
        XCTAssertTrue(model.confirmCollection(retry.id)); XCTAssertEqual(model.retryBatch.conflictPolicy, .ask)
        try await wait { fake.uploads.count == 2 }
        model.batch.startOrContinue(); XCTAssertEqual(fake.uploads.count, 2)
        fake.uploads[1].continuation.resume()
        try await wait { model.retryBatch.state == .finished }
        XCTAssertEqual(model.batch.state, .paused); XCTAssertEqual(model.batch.taskResults, old)
        XCTAssertEqual(model.batch.items[1].state, .waiting); XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.history.records.count, 2)
        XCTAssertTrue(model.canContinueQueue(model.batch)); XCTAssertFalse(model.canPrepareCollectionRetry(batchID: model.retryBatch.collectionPlanID))
        model.continueQueue(model.batch); try await wait { fake.uploads.count == 3 }
        fake.uploads[2].continuation.resume(); try await wait { !model.isBusy }
        XCTAssertEqual(model.batch.taskResults[failedID], old[failedID])
        XCTAssertEqual(model.batch.items[1].state, .succeeded); XCTAssertEqual(counts.counts, [3, 3])
        XCTAssertEqual(model.sessionSummary?.actualBytes, 4)
        XCTAssertEqual(model.sessionSummary?.successfulBytes, 1)
        XCTAssertEqual(model.sessionSummary?.original.plannedSuccessfulBytes, 1)
        XCTAssertFalse(model.sessionSummary?.allSuccessful ?? true)
    }

    func testPausedDirectoryRetryClosesOldSubtreeAndNeverIncludesAddedSources() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), base = try folder()
        let tree = base.appendingPathComponent("tree"), other = base.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data([1]).write(to: tree.appendingPathComponent("nested/file")); try Data([2]).write(to: other)
        let model = try await connected(fake, counts: counts, entries: [])
        XCTAssertTrue(model.prepareUploadCollection([tree, other]))
        try await wait { model.collectionScan.phase == .preview }
        let plan = try XCTUnwrap(model.collectionScan.plan)
        XCTAssertTrue(model.confirmCollection(plan.id))
        try await wait { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: .init(entries: [], encoding: .utf8))
        try await wait { fake.directories.count == 1 }
        fake.directories[0].continuation.resume(throwing: FTPError.localFile("mkdir denied"))
        try await wait { fake.browses.count == 3 }
        fake.browses[2].continuation.resume(returning: .init(entries: [], encoding: .utf8))
        try await wait { model.batch.state == .paused }
        let failedID = model.batch.items[0].id, failure = model.batch.taskResults[model.batch.items[0].id]
        try Data([3]).write(to: tree.appendingPathComponent("added"))
        XCTAssertTrue(model.prepareCollectionRetry(itemID: failedID))
        try await wait { model.collectionScan.phase == .preview }
        let retry = try XCTUnwrap(model.collectionScan.plan)
        XCTAssertEqual(retry.nodes.map { $0.relativePath.map(\.name).joined(separator: "/") },
                       ["tree", "tree/nested", "tree/nested/file"])
        XCTAssertEqual(model.batch.items[1].state, .blocked(parentID: failedID, reason: .failedAncestor))
        XCTAssertEqual(model.batch.items[2].state, .blocked(parentID: model.batch.items[1].id, reason: .failedAncestor))
        let old = model.batch.taskResults
        XCTAssertEqual(model.history.records.count, 3); XCTAssertEqual(fake.directories.count, 1)
        model.cancelOperation(id: model.cancellationID)
        XCTAssertEqual(model.collectionScan.phase, .finished); XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.batch.taskResults, old); XCTAssertEqual(model.batch.taskResults[failedID], failure)
        XCTAssertEqual(model.batch.state, .paused); XCTAssertEqual(model.history.records.count, 3)
        XCTAssertEqual(model.batch.items[3].state, .waiting); XCTAssertEqual(counts.counts, [3, 1])
        // Failed preparation still leaves original results and authorization intact.
        try FileManager.default.removeItem(at: tree.appendingPathComponent("nested/file"))
        XCTAssertTrue(model.prepareCollectionRetry(itemID: failedID))
        try await wait { model.collectionScan.phase == .finished }
        XCTAssertNotNil(model.collectionScan.error); XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.batch.taskResults, old); XCTAssertEqual(model.history.records.count, 3)
        model.cancelAllTransfers(); XCTAssertFalse(model.isBusy); XCTAssertEqual(counts.counts, [4, 4])
        XCTAssertTrue(fake.uploads.isEmpty); XCTAssertTrue(fake.downloads.isEmpty)
    }

    func testCancelAllDuringRetryReadWaitsForBothRootScopesAndPreservesOldFailure() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), destination = try folder()
        let first = entry("first"), other = entry("other")
        let model = try await connected(fake, counts: counts, entries: [first, other])
        XCTAssertTrue(model.prepareDownloadCollection([first, other], to: destination))
        try await wait { model.collectionScan.phase == .preview }
        XCTAssertTrue(model.confirmCollection(try XCTUnwrap(model.collectionScan.plan).id))
        try await wait { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(throwing: FTPError.localFile("read denied"))
        try await wait { model.batch.state == .paused }
        let failedID = model.batch.items[0].id, old = model.batch.taskResults[model.batch.items[0].id]
        XCTAssertTrue(model.prepareCollectionRetry(itemID: failedID))
        try await wait { fake.browses.count == 3 }
        let id = try XCTUnwrap(model.cancellationID)
        model.cancelAllTransfers(id: UUID()); XCTAssertFalse(fake.browses[2].cancellation.isCancelled)
        model.cancelAllTransfers(id: id)
        XCTAssertTrue(fake.browses[2].cancellation.isCancelled)
        XCTAssertEqual(model.collectionScan.phase, .cancelling); XCTAssertEqual(model.batch.state, .cancelling)
        XCTAssertTrue(model.isBusy); XCTAssertTrue(model.hasCollectionCredentials); XCTAssertEqual(counts.counts, [2, 0])
        fake.browses[2].continuation.resume(returning: .init(entries: [first, other], encoding: .utf8))
        try await wait { !model.isBusy }
        XCTAssertEqual(counts.counts, [2, 2]); XCTAssertFalse(model.hasCollectionCredentials)
        XCTAssertEqual(model.batch.taskResults[failedID], old); XCTAssertEqual(model.batch.items[1].state, .cancelled)
        XCTAssertEqual(model.history.records.count, 2); XCTAssertTrue(model.retryBatch.items.isEmpty)
        XCTAssertTrue(fake.downloads.isEmpty); XCTAssertTrue(fake.directories.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func testScanCancellationLocksUntilBackendStopsAndStaleIDsCannotCancelNextScan() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), destination = try folder(), remote = entry("tree", directory: true)
        let model = try await connected(fake, counts: counts, entries: [remote])
        let local = destination.appendingPathComponent("selected.bin"); try Data([1]).write(to: local)
        model.selectFile(local); let original = model.selectedFile
        XCTAssertTrue(model.prepareDownloadCollection([remote], to: destination))
        XCTAssertFalse(model.prepareDownloadCollection([remote], to: destination))
        try await wait { fake.browses.count == 2 }
        let id = try XCTUnwrap(model.cancellationID)
        model.address = "other.test"; model.loginMode = .account; model.refresh(); model.enter(remote)
        model.selectFile(destination); model.upload(); model.prepareBatch([local])
        model.fileSelectionFailed(FTPError.invalidName); model.downloadSelectionFailed(FTPError.invalidName)
        XCTAssertEqual(model.address, "example.test"); XCTAssertEqual(model.loginMode, .anonymous)
        XCTAssertTrue(model.selectedFile === original); XCTAssertNil(model.selectionError)
        XCTAssertEqual(model.downloadState, .idle); XCTAssertEqual(fake.browses.count, 2)
        model.cancelOperation(id: UUID()); XCTAssertFalse(fake.browses[1].cancellation.isCancelled)
        model.cancelOperation(id: id)
        XCTAssertEqual(model.collectionScan.phase, .cancelling); XCTAssertFalse(model.canEditConnection)
        XCTAssertTrue(model.hasCollectionCredentials); XCTAssertEqual(counts.counts, [1, 0])
        fake.browses[1].continuation.resume(returning: .init(entries: [entry("late")], encoding: .utf8))
        try await wait { !model.isBusy }
        XCTAssertNil(model.collectionScan.plan); XCTAssertNil(model.collectionScan.error)
        XCTAssertFalse(model.hasCollectionCredentials); XCTAssertEqual(counts.counts, [1, 1])
        XCTAssertTrue(model.selectedFile === original); XCTAssertTrue(fake.downloads.isEmpty)
        XCTAssertTrue(model.prepareDownloadCollection([remote], to: destination))
        try await wait { fake.browses.count == 3 }
        model.cancelOperation(id: id); XCTAssertFalse(fake.browses[2].cancellation.isCancelled)
        fake.browses[2].continuation.resume(returning: .init(entries: [], encoding: .utf8))
        try await wait { model.collectionScan.phase == .preview }
        XCTAssertFalse(model.confirmCollection(UUID())); XCTAssertTrue(model.isBusy)
        model.cancelAllTransfers(id: model.cancellationID)
        XCTAssertFalse(model.isBusy); XCTAssertEqual(counts.counts, [2, 2])
        XCTAssertTrue(fake.directories.isEmpty); XCTAssertTrue(fake.uploads.isEmpty); XCTAssertTrue(fake.downloads.isEmpty)
    }

    func testPreviewCancelPreservesSingleFileAndDoesNotWriteTargetsOrHistory() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), destination = try folder(), remote = entry("tree", directory: true)
        let model = try await connected(fake, counts: counts, entries: [remote])
        let local = destination.appendingPathComponent("selected.bin"); try Data([1]).write(to: local)
        model.selectFile(local); let original = model.selectedFile, previous = model.uploadState
        XCTAssertTrue(model.prepareDownloadCollection([remote], to: destination))
        try await wait { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: .init(entries: [entry("file")], encoding: .utf8))
        try await wait { model.collectionScan.phase == .preview }
        XCTAssertEqual(model.collectionScan.plan?.nodes.count, 2); XCTAssertFalse(model.canChooseFile)
        XCTAssertTrue(model.hasCollectionCredentials); XCTAssertEqual(counts.counts, [1, 0])
        model.cancelOperation(id: model.cancellationID)
        XCTAssertTrue(model.canChooseFile); XCTAssertFalse(model.hasCollectionCredentials)
        XCTAssertTrue(model.selectedFile === original); XCTAssertEqual(model.uploadState, previous)
        XCTAssertEqual(counts.counts, [1, 1]); XCTAssertTrue(model.history.records.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["selected.bin"])
    }

    func testUploadPreviewHandoffAndActiveCancelWaitForBackendAndIgnoreLateProgress() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), source = try folder()
        let file = source.appendingPathComponent("file.bin"); try Data("one".utf8).write(to: file)
        let model = try await connected(fake, counts: counts, entries: [])
        XCTAssertTrue(model.prepareUploadCollection([file])); XCTAssertFalse(model.prepareUploadCollection([file]))
        try await wait { model.collectionScan.phase == .preview }
        XCTAssertEqual(counts.counts, [1, 0]); XCTAssertTrue(model.hasCollectionCredentials)
        let planID = try XCTUnwrap(model.collectionScan.plan?.id)
        XCTAssertTrue(model.confirmCollection(planID)); XCTAssertFalse(model.confirmCollection(planID))
        try await wait { fake.uploads.count == 1 }
        XCTAssertTrue(model.isBusy); XCTAssertEqual(model.collectionScan.phase, .finished)
        let id = try XCTUnwrap(model.cancellationID)
        model.cancelAllTransfers(id: UUID()); XCTAssertFalse(fake.uploads[0].cancellation.isCancelled)
        model.cancelAllTransfers(id: id)
        XCTAssertEqual(model.batch.state, .cancelling); XCTAssertTrue(model.hasCollectionCredentials)
        XCTAssertFalse(model.canEditConnection); XCTAssertEqual(counts.counts, [1, 0])
        fake.uploads[0].progress(100, 100); fake.uploads[0].continuation.resume()
        try await wait { !model.isBusy }
        XCTAssertEqual(model.batch.items[0].state, .cancelled); XCTAssertEqual(model.batch.items[0].bytes, 0)
        XCTAssertFalse(model.hasCollectionCredentials); XCTAssertEqual(counts.counts, [1, 1])
        fake.uploads[0].progress(999, 999); await Task.yield()
        XCTAssertEqual(model.batch.items[0].state, .cancelled); XCTAssertEqual(model.batch.items[0].bytes, 0)
    }

    func testActiveDirectoryKeepsKeyBytesButNewBatchesRecheckAssociation() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), base = try folder()
        let key = base.appendingPathComponent("key"), source = base.appendingPathComponent("tree")
        let original = Data("-----BEGIN RSA PRIVATE KEY-----\noriginal".utf8)
        try original.write(to: key); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let remote = entry("remote.bin")
        let model = AppModel(client: fake, history: isolatedHistory(), rootScope: counts.scope)
        model.transport = .sftp; model.address = "example.test"; model.username = "member"
        model.authenticationMethod = .privateKey; model.choosePrivateKey(key); model.passphrase = "phrase"
        model.connect(); try await wait { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: .init(entries: [remote], encoding: .utf8))
        try await wait { model.hasDirectory }
        XCTAssertTrue(model.prepareUploadCollection([source])); try await wait { model.collectionScan.phase == .preview }
        XCTAssertTrue(model.confirmCollection(try XCTUnwrap(model.collectionScan.plan?.id)))
        try await wait { fake.browses.count == 2 }
        try Data("-----BEGIN RSA PRIVATE KEY-----\nchanged".utf8).write(to: key)
        XCTAssertFalse(model.prepareUploadCollection([source]))
        fake.browses[1].continuation.resume(returning: .init(entries: [], encoding: .utf8))
        try await wait { fake.directories.count == 1 }
        XCTAssertEqual(fake.directories[0].credentials.privateKey?.bytes, original)
        XCTAssertEqual(fake.directories[0].credentials.passphrase, "phrase")
        fake.directories[0].continuation.resume(); try await wait { !model.isBusy }
        XCTAssertFalse(model.hasCollectionCredentials); XCTAssertEqual(counts.counts, [1, 1])
        XCTAssertFalse(model.prepareUploadCollection([source]))
        XCTAssertEqual(model.fieldIssue?.field, .privateKey); XCTAssertNil(model.passphrase)
        XCTAssertFalse(model.prepareDownloadCollection([remote], to: base)); model.prepareBatch([source])
        XCTAssertEqual(fake.browses.count, 2); XCTAssertEqual(fake.directories.count, 1)
        XCTAssertFalse(model.batch.isLocked); XCTAssertFalse(model.collectionScan.isLocked)
    }

    func testConfirmedDirectoryHistoryUsesNodeIdentityAndIsNotDuplicatedByJobCallback() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), base = try folder(), remote = entry("empty", directory: true)
        let model = try await connected(fake, counts: counts, entries: [remote])
        XCTAssertTrue(model.prepareDownloadCollection([remote], to: base))
        try await wait { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: .init(entries: [], encoding: .utf8))
        try await wait { model.collectionScan.phase == .preview }
        let plan = try XCTUnwrap(model.collectionScan.plan)
        XCTAssertTrue(model.confirmCollection(plan.id)); try await wait { fake.browses.count == 3 }
        fake.browses[2].continuation.resume(returning: .init(entries: [remote], encoding: .utf8))
        try await wait { !model.isBusy }
        XCTAssertEqual(model.history.records.count, 1)
        XCTAssertEqual(model.history.records[0].id, plan.nodes[0].id)
        XCTAssertEqual(model.history.records[0].batchID, plan.id)
        XCTAssertEqual(model.history.records[0].taskKind, .directory)
        XCTAssertEqual(model.history.records[0].bytes, 0); XCTAssertEqual(model.history.records[0].result, "成功")
    }

    func testOriginalBatchPreviewUsesModelCancelWithoutTerminalRecords() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), source = try folder()
        let file = source.appendingPathComponent("file.bin"); try Data([1]).write(to: file)
        let model = try await connected(fake, counts: counts, entries: [])
        model.prepareBatch([file]); try await wait { model.batch.state == .preview }
        XCTAssertTrue(model.canCancel); XCTAssertFalse(model.canEditConnection)
        model.cancelOperation()
        XCTAssertTrue(model.canEditConnection); XCTAssertFalse(model.hasCollectionCredentials)
        XCTAssertTrue(model.batch.taskResults.isEmpty); XCTAssertTrue(model.history.records.isEmpty)
        XCTAssertTrue(fake.uploads.isEmpty)
    }

    func testPausedFailureLocksModelAndOldCurrentCancelIDCannotCancelRemainingQueue() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), destination = try folder()
        let selected = [entry("first.bin"), entry("second.bin")]
        let model = try await connected(fake, counts: counts, entries: selected)
        XCTAssertTrue(model.prepareDownloadCollection(selected, to: destination))
        try await wait { model.collectionScan.phase == .preview }
        XCTAssertTrue(model.confirmCollection(try XCTUnwrap(model.collectionScan.plan?.id)))
        try await wait { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: .init(entries: selected, encoding: .utf8))
        try await wait { fake.downloads.count == 1 }
        let oldID = try XCTUnwrap(model.cancellationID)
        fake.downloads[0].continuation.resume(throwing: FTPError.localFile("network failed"))
        try await wait { model.batch.state == .paused }
        XCTAssertFalse(model.canEditConnection); XCTAssertFalse(model.canChooseFile)
        XCTAssertTrue(model.hasCollectionCredentials); XCTAssertEqual(counts.counts, [1, 0])
        model.address = "other.test"; model.refresh(); model.connect()
        XCTAssertEqual(model.address, "example.test"); XCTAssertEqual(fake.browses.count, 2)
        fake.downloads[0].progress(999, 999); await Task.yield()
        XCTAssertEqual(model.batch.items[0].bytes, 0)
        model.cancelAllTransfers(id: oldID); XCTAssertEqual(model.batch.state, .paused)
        model.batch.startOrContinue(); try await wait { model.batch.state == .paused }
        XCTAssertEqual(fake.downloads.count, 1); XCTAssertEqual(fake.browses.count, 2)
        let original = model.batch.taskResults[model.batch.items[0].id]
        model.cancelAllTransfers()
        XCTAssertTrue(model.canEditConnection); XCTAssertFalse(model.hasCollectionCredentials)
        XCTAssertEqual(counts.counts, [1, 1]); XCTAssertEqual(model.batch.items[1].state, .cancelled)
        XCTAssertEqual(model.batch.taskResults[model.batch.items[0].id], original)
    }

    func testCleanupFailureStillReleasesLeaseDespiteRetainedReceiveCallback() throws {
        let counts = ScopeCounts(), destination = try folder()
        let root = try LocalDestinationRoot(url: destination, scope: counts.scope)
        let service = try LocalDestinationService(root: root)
        var operations = LocalDownload.Anchor.Operations()
        operations.remove = { _, _, _ in throw POSIXError(.EACCES) }
        let sink = try service.download(["file.bin"], operations: operations)
        let retainedReceive = sink.receive
        try retainedReceive(Data([1])); try sink.closeFile()
        XCTAssertThrowsError(try sink.cleanUp())
        root.endAccess()
        XCTAssertEqual(counts.counts, [1, 1]); XCTAssertLessThan(root.descriptor, 0)
        XCTAssertThrowsError(try retainedReceive(Data([2])))
        XCTAssertThrowsError(try sink.currentTargetIdentity()); XCTAssertThrowsError(try sink.commit())
        XCTAssertNoThrow(try sink.cleanUp())
        XCTAssertFalse(FileManager.default.fileExists(atPath: sink.destination.path))
    }

    func testDownloadCommitConfirmationCancelReleasesContinuationAndOwnedTemporaryOnly() async throws {
        let fake = ControlledFTP(), counts = ScopeCounts(), destination = try folder(), remote = entry("file.bin")
        let model = try await connected(fake, counts: counts, entries: [remote])
        XCTAssertTrue(model.prepareDownloadCollection([remote], to: destination))
        try await wait { model.collectionScan.phase == .preview }
        XCTAssertTrue(model.confirmCollection(try XCTUnwrap(model.collectionScan.plan?.id)))
        try await wait { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: .init(entries: [remote], encoding: .utf8))
        try await wait { fake.downloads.count == 1 }
        try fake.downloads[0].receive(Data("new".utf8))
        let target = destination.appendingPathComponent("file.bin"); try Data("keep".utf8).write(to: target)
        fake.downloads[0].continuation.resume()
        try await wait { model.batch.overwriteID != nil }
        XCTAssertFalse(model.canEditConnection); XCTAssertEqual(counts.counts, [1, 0])
        XCTAssertTrue(model.hasCollectionCredentials); XCTAssertEqual(model.batch.items[0].state, .awaitingOverwrite)
        model.cancelAllTransfers(id: model.cancellationID)
        XCTAssertTrue(model.isBusy); XCTAssertTrue(model.hasCollectionCredentials)
        try await wait { !model.isBusy }
        XCTAssertNil(model.batch.overwriteID); XCTAssertFalse(model.hasCollectionCredentials)
        XCTAssertEqual(counts.counts, [1, 1]); XCTAssertEqual(model.batch.items[0].state, .cancelled)
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["file.bin"])
        model.batch.confirmOverwrite(model.batch.items[0].id)
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
    }
}

@MainActor
final class CollectionQueueTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition())
    }
    private func entry(_ name: String, directory: Bool) -> RemoteEntry {
        RemoteEntry(name: name, rawName: Data(name.utf8), isDirectory: directory, size: directory ? nil : 3)
    }
    private func respond(_ fake: ControlledFTP, index: Int, entries: [RemoteEntry]) {
        fake.browses[index].continuation.resume(returning: .init(entries: entries, encoding: .utf8))
    }
    private func uploadPlan(_ urls: [URL]) async throws -> (TransferPlan, [UUID: LocalSourceRoot]) {
        let roots = try urls.map { try LocalSourceRoot(url: $0) }
        let plan = try await LocalTransferScanner().scan(roots: roots, destination: .root, encoding: .utf8,
                                                       cancellation: FTPCancellationToken())
        XCTAssertTrue(plan.canStart)
        return (plan, Dictionary(uniqueKeysWithValues: zip(plan.roots.map(\.id), roots)))
    }
    private func downloadPlan(destination: URL) throws -> TransferPlan {
        let rootPath = try RemotePath.root.appending(name: "tree", bytes: Data("tree".utf8))
        let root = TransferPlan.Root(source: .remote(rootPath, .utf8), kind: .directory)
        var nodes: [TransferPlan.Node] = []
        var ids: [[String]: UUID] = [:]
        let definitions: [([String], RemoteEntry.Kind, Int64?)] = [
            (["tree"], .directory, nil), (["tree", "a.bin"], .regularFile, 3),
            (["tree", "empty"], .directory, nil), (["tree", "nested"], .directory, nil),
            (["tree", "nested", "b.bin"], .regularFile, nil)]
        for (path, kind, size) in definitions {
            let components = path.map { RemotePath.Component(name: $0, bytes: Data($0.utf8)) }
            let source = try path.dropFirst().reduce(rootPath) { try $0.appending(name: $1, bytes: Data($1.utf8)) }
            let node = TransferPlan.Node(rootID: root.id, kind: kind, source: .remote(source, .utf8),
                target: .local(path.reduce(destination) { $0.appendingPathComponent($1) }), relativePath: components,
                parentID: ids[Array(path.dropLast())], size: size, snapshot: .remote(kind: kind, size: size))
            nodes.append(node); ids[path] = node.id
        }
        return TransferPlan(direction: .download, roots: [root], nodes: nodes.reversed())
    }

    func testUploadPrivateKeyRemainsFixedAcrossDirectoryTasksAndFileFailurePause() async throws {
        let base = try folder(), source = base.appendingPathComponent("tree"), key = base.appendingPathComponent("key")
        let keyBytes = Data("-----BEGIN RSA PRIVATE KEY-----\noriginal".utf8)
        try keyBytes.write(to: key)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data([1]).write(to: source.appendingPathComponent("first")); try Data([2]).write(to: source.appendingPathComponent("second"))
        let (plan, roots) = try await uploadPlan([source]), selection = try PrivateKeySelection.select(key)
        let fake = ControlledFTP(), queue = BatchTransferQueue(client: fake, executor: TransferExecutor())
        weak var material: PrivateKeyMaterial?
        func prepare() throws {
            let credentials = try FTPCredentials.key(username: "member", material: selection.material(), passphrase: "phrase")
            material = credentials.privateKey
            try queue.prepare(plan: plan, endpoint: FTPEndpoint(address: "sftp://example.test"), remoteRoot: .root,
                              encoding: .utf8, credentials: credentials, sources: roots)
        }
        try prepare(); queue.startOrContinue(); try await wait { fake.browses.count == 1 }
        respond(fake, index: 0, entries: [entry("tree", directory: true)])
        try await wait { fake.uploads.count == 1 }
        try Data("-----BEGIN RSA PRIVATE KEY-----\nchanged".utf8).write(to: key)
        XCTAssertThrowsError(try selection.material())
        fake.uploads[0].continuation.resume(throwing: FTPError.localFile("failure"))
        try await wait { queue.state == .paused }
        XCTAssertTrue(queue.hasCredentials); XCTAssertNotNil(material)
        queue.startOrContinue(); try await wait { queue.state == .paused }
        XCTAssertEqual(fake.uploads.count, 1)
        queue.skip(); queue.startOrContinue(); try await wait { fake.uploads.count == 2 }
        XCTAssertTrue(fake.uploads[1].credentials.privateKey === material)
        XCTAssertEqual(fake.uploads[1].credentials.privateKey?.bytes, keyBytes)
        XCTAssertEqual(fake.uploads[1].credentials.passphrase, "phrase")
        fake.uploads[1].continuation.resume(); try await wait { queue.state == .finished }
        XCTAssertFalse(queue.hasCredentials); XCTAssertEqual(fake.uploads.count, 2)
        fake.browses.removeAll(); fake.uploads.removeAll(); fake.directories.removeAll()
        XCTAssertNil(material)
    }

    func testDownloadPrivateKeyRemainsFixedForDirectoriesAndFilesAfterFailure() async throws {
        let destination = try folder(), keyBase = try folder(), key = keyBase.appendingPathComponent("key")
        let keyBytes = Data("-----BEGIN RSA PRIVATE KEY-----\noriginal".utf8); try keyBytes.write(to: key)
        let selection = try PrivateKeySelection.select(key), plan = try downloadPlan(destination: destination)
        let fake = ControlledFTP(), queue = BatchTransferQueue(client: fake, executor: TransferExecutor())
        weak var material: PrivateKeyMaterial?
        func prepare() throws {
            let credentials = try FTPCredentials.key(username: "member", material: selection.material(), passphrase: "phrase")
            material = credentials.privateKey
            try queue.prepare(plan: plan, endpoint: FTPEndpoint(address: "sftp://example.test"), remoteRoot: .root,
                              encoding: .utf8, credentials: credentials, destination: LocalDestinationRoot(url: destination))
        }
        try prepare(); queue.startOrContinue(); try await wait { fake.browses.count == 1 }
        respond(fake, index: 0, entries: [entry("tree", directory: true)])
        try await wait { fake.browses.count == 2 }; respond(fake, index: 1, entries: [entry("a.bin", directory: false)])
        try await wait { fake.downloads.count == 1 }
        try Data("-----BEGIN RSA PRIVATE KEY-----\nchanged".utf8).write(to: key)
        fake.downloads[0].continuation.resume(throwing: FTPError.localFile("failure"))
        try await wait { queue.state == .paused }
        queue.startOrContinue(); try await wait { queue.state == .paused }
        XCTAssertEqual(fake.downloads.count, 1); XCTAssertEqual(fake.browses.count, 2)
        queue.skip(); queue.startOrContinue(); try await wait { fake.browses.count == 3 }
        respond(fake, index: 2, entries: [entry("empty", directory: true)])
        try await wait { fake.browses.count == 4 }; respond(fake, index: 3, entries: [entry("nested", directory: true)])
        try await wait { fake.browses.count == 5 }; respond(fake, index: 4, entries: [entry("b.bin", directory: false)])
        try await wait { fake.downloads.count == 2 }
        XCTAssertTrue(fake.browses.allSatisfy { $0.credentials.privateKey === material && $0.credentials.privateKey?.bytes == keyBytes })
        XCTAssertTrue(fake.downloads.allSatisfy { $0.credentials.privateKey === material && $0.credentials.passphrase == "phrase" })
        try fake.downloads[1].receive(Data([2])); fake.downloads[1].continuation.resume()
        try await wait { queue.state == .finished }
        XCTAssertFalse(queue.hasCredentials); XCTAssertEqual(fake.downloads.count, 2)
        fake.browses.removeAll(); fake.downloads.removeAll()
        XCTAssertNil(material)
    }

    private func singleDownloadPlan(_ destination: URL) throws -> TransferPlan {
        let path = try RemotePath.root.appending(name: "file.bin", bytes: Data("file.bin".utf8))
        let root = TransferPlan.Root(source: .remote(path, .utf8), kind: .regularFile)
        let node = TransferPlan.Node(rootID: root.id, kind: .regularFile, source: root.source,
            target: .local(destination.appendingPathComponent("file.bin")), relativePath: path.components,
            parentID: nil, size: 3, snapshot: .remote(kind: .regularFile, size: 3))
        return TransferPlan(direction: .download, roots: [root], nodes: [node])
    }

    func testUploadPoliciesCheckEveryFileAndNeverSurviveNewPlan() async throws {
        for policy in [TransferConflictPolicy.ask, .skipExistingFiles, .overwriteExistingFiles] {
            let base = try folder(), urls = [base.appendingPathComponent("first"), base.appendingPathComponent("second")]
            try urls.forEach { try Data([1]).write(to: $0) }
            let (plan, roots) = try await uploadPlan(urls), fake = ControlledFTP()
            fake.autoCheckTargets = false
            let queue = BatchTransferQueue(client: fake, executor: TransferExecutor())
            try queue.prepare(plan: plan, endpoint: FTPEndpoint(address: "ftp://example.test"), remoteRoot: .root,
                              encoding: .utf8, credentials: .anonymous, sources: roots)
            XCTAssertFalse(queue.chooseConflictPolicy(.overwriteExistingFiles, planID: UUID()))
            XCTAssertTrue(queue.chooseConflictPolicy(policy, planID: plan.id))
            queue.startOrContinue()
            XCTAssertFalse(queue.chooseConflictPolicy(.overwriteExistingFiles, planID: plan.id))
            try await wait { fake.browses.count == 1 }; respond(fake, index: 0, entries: [entry("first", directory: false)])
            switch policy {
            case .ask:
                try await wait { queue.overwriteID != nil }
                let request = try XCTUnwrap(queue.overwriteID)
                XCTAssertNotEqual(request, queue.items[0].id); XCTAssertEqual(queue.overwriteTarget, queue.items[0].target)
                queue.skipOverwrite(UUID()); XCTAssertEqual(queue.overwriteID, request)
                queue.skipOverwrite(request)
            case .skipExistingFiles: break
            case .overwriteExistingFiles:
                try await wait { fake.uploads.count == 1 }; XCTAssertNil(queue.overwriteID)
                fake.uploads[0].continuation.resume()
            }
            try await wait { fake.browses.count == 2 }; respond(fake, index: 1, entries: [entry("second", directory: false)])
            switch policy {
            case .ask:
                try await wait { queue.overwriteID != nil }; queue.confirmOverwrite(try XCTUnwrap(queue.overwriteID))
                try await wait { fake.uploads.count == 1 }; fake.uploads[0].continuation.resume()
            case .skipExistingFiles: break
            case .overwriteExistingFiles:
                try await wait { fake.uploads.count == 2 }; fake.uploads[1].continuation.resume()
            }
            try await wait { queue.state == .finished }
            switch policy {
            case .ask: XCTAssertEqual(queue.items.map(\.state), [.skipped, .succeeded])
            case .skipExistingFiles: XCTAssertTrue(fake.uploads.isEmpty); XCTAssertEqual(queue.items.map(\.state), [.skipped, .skipped])
            case .overwriteExistingFiles: XCTAssertEqual(queue.items.map(\.state), [.succeeded, .succeeded])
            }
            let (fresh, freshRoots) = try await uploadPlan([urls[0]])
            try queue.prepare(plan: fresh, endpoint: FTPEndpoint(address: "ftp://example.test"), remoteRoot: .root,
                              encoding: .utf8, credentials: .anonymous, sources: freshRoots)
            queue.startOrContinue(); try await wait { fake.browses.count == 3 }
            respond(fake, index: 2, entries: [entry("first", directory: false)])
            try await wait { queue.overwriteID != nil }
            queue.cancelAll(); try await wait { queue.state == .finished }
        }
    }

    func testOverwritePolicyNeverAppliesToUploadDirectoryConflict() async throws {
        let base = try folder(), source = base.appendingPathComponent("file.bin"); try Data([1]).write(to: source)
        let (plan, roots) = try await uploadPlan([source]), fake = ControlledFTP(); fake.autoCheckTargets = false
        let queue = BatchTransferQueue(client: fake, executor: TransferExecutor())
        try queue.prepare(plan: plan, endpoint: FTPEndpoint(address: "ftp://example.test"), remoteRoot: .root,
                          encoding: .utf8, credentials: .anonymous, sources: roots)
        XCTAssertTrue(queue.chooseConflictPolicy(.overwriteExistingFiles, planID: plan.id))
        queue.startOrContinue(); try await wait { fake.browses.count == 1 }
        respond(fake, index: 0, entries: [entry("file.bin", directory: true)])
        try await wait { queue.state == .paused }
        guard case .failed = queue.items[0].state else { return XCTFail("Expected type conflict") }
        XCTAssertNil(queue.overwriteID); XCTAssertTrue(fake.uploads.isEmpty); XCTAssertTrue(fake.directories.isEmpty)
        queue.cancelAll()
    }

    func testDownloadPoliciesSkipBeforeReceptionAndRejectDirectoryTargets() async throws {
        for directory in [false, true] {
            let destination = try folder(), target = destination.appendingPathComponent("file.bin")
            if directory { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
            else { try Data("keep".utf8).write(to: target) }
            let plan = try singleDownloadPlan(destination), fake = ControlledFTP()
            let queue = BatchTransferQueue(client: fake, executor: TransferExecutor())
            try queue.prepare(plan: plan, endpoint: FTPEndpoint(address: "ftp://example.test"), remoteRoot: .root,
                              encoding: .utf8, credentials: .anonymous, destination: LocalDestinationRoot(url: destination))
            XCTAssertTrue(queue.chooseConflictPolicy(.skipExistingFiles, planID: plan.id))
            queue.startOrContinue(); try await wait { fake.browses.count == 1 }
            respond(fake, index: 0, entries: [entry("file.bin", directory: false)])
            try await wait { queue.state == (directory ? .paused : .finished) }
            if directory { guard case .failed = queue.items[0].state else { return XCTFail("Expected type conflict") }; queue.cancelAll() }
            else { XCTAssertEqual(queue.items[0].state, .skipped); XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8)) }
            XCTAssertTrue(fake.downloads.isEmpty); XCTAssertNil(queue.overwriteID)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["file.bin"])
        }
    }

    func testDefaultDownloadPromptSupportsExplicitSkipOrOnlyThisOverwrite() async throws {
        for overwrite in [false, true] {
            let destination = try folder(), target = destination.appendingPathComponent("file.bin"), fake = ControlledFTP()
            try Data("keep".utf8).write(to: target)
            let plan = try singleDownloadPlan(destination), queue = BatchTransferQueue(client: fake, executor: TransferExecutor())
            try queue.prepare(plan: plan, endpoint: FTPEndpoint(address: "ftp://example.test"), remoteRoot: .root,
                              encoding: .utf8, credentials: .anonymous, destination: LocalDestinationRoot(url: destination))
            queue.startOrContinue(); try await wait { fake.browses.count == 1 }
            respond(fake, index: 0, entries: [entry("file.bin", directory: false)])
            try await wait { queue.overwriteID != nil }
            XCTAssertTrue(fake.downloads.isEmpty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["file.bin"])
            let id = try XCTUnwrap(queue.overwriteID)
            if overwrite {
                queue.confirmOverwrite(id); try await wait { fake.downloads.count == 1 }
                queue.cancelOverwrite(id); XCTAssertFalse(fake.downloads[0].cancellation.isCancelled)
                try fake.downloads[0].receive(Data("new".utf8)); fake.downloads[0].continuation.resume()
            } else { queue.skipOverwrite(id) }
            try await wait { queue.state == .finished }
            XCTAssertEqual(queue.items[0].state, overwrite ? .succeeded : .skipped)
            XCTAssertEqual(try Data(contentsOf: target), Data((overwrite ? "new" : "keep").utf8))
        }
    }

    func testBatchOverwriteCannotConfirmChangedDownloadTargetAndOldPromptActionsAreInert() async throws {
        let destination = try folder(), target = destination.appendingPathComponent("file.bin"), fake = ControlledFTP()
        try Data("old".utf8).write(to: target)
        let plan = try singleDownloadPlan(destination), queue = BatchTransferQueue(client: fake, executor: TransferExecutor())
        try queue.prepare(plan: plan, endpoint: FTPEndpoint(address: "ftp://example.test"), remoteRoot: .root,
                          encoding: .utf8, credentials: .anonymous, destination: LocalDestinationRoot(url: destination))
        XCTAssertTrue(queue.chooseConflictPolicy(.overwriteExistingFiles, planID: plan.id))
        queue.startOrContinue(); try await wait { fake.browses.count == 1 }
        respond(fake, index: 0, entries: [entry("file.bin", directory: false)])
        try await wait { fake.downloads.count == 1 }; XCTAssertNil(queue.overwriteID)
        try fake.downloads[0].receive(Data("new".utf8)); try Data("changed".utf8).write(to: target)
        fake.downloads[0].continuation.resume(); try await wait { queue.overwriteID != nil }
        let first = try XCTUnwrap(queue.overwriteID)
        XCTAssertEqual(try Data(contentsOf: target), Data("changed".utf8))
        try Data("changed-again-longer".utf8).write(to: target)
        queue.confirmOverwrite(first)
        try await wait { queue.overwriteID != nil && queue.overwriteID != first }
        let second = try XCTUnwrap(queue.overwriteID)
        XCTAssertEqual(queue.overwriteNodeID, plan.nodes[0].id)
        queue.confirmOverwrite(first); queue.skipOverwrite(first); queue.cancelOverwrite(first)
        XCTAssertEqual(queue.overwriteID, second); XCTAssertFalse(fake.downloads[0].cancellation.isCancelled)
        XCTAssertEqual(try Data(contentsOf: target), Data("changed-again-longer".utf8))
        queue.confirmOverwrite(second); try await wait { queue.state == .finished }
        XCTAssertEqual(queue.items[0].state, .succeeded); XCTAssertEqual(fake.downloads.count, 1)
        XCTAssertEqual(try Data(contentsOf: target), Data("new".utf8))
    }

    func testUploadSerialParentsEmptyDirectoryAndExistingDirectoryReuse() async throws {
        let base = try folder(), source = base.appendingPathComponent("tree"), fake = ControlledFTP()
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: false)
        try Data("one".utf8).write(to: source.appendingPathComponent("a.bin"))
        try Data("two".utf8).write(to: source.appendingPathComponent("nested/b.bin"))
        let (plan, roots) = try await uploadPlan([source]), executor = TransferExecutor()
        let queue = BatchTransferQueue(client: fake, executor: executor)
        try queue.prepare(plan: plan, endpoint: FTPEndpoint(address: "ftp://example.test"), remoteRoot: .root,
                          encoding: .utf8, credentials: .anonymous, sources: roots)
        XCTAssertEqual(queue.state, .preview); XCTAssertTrue(fake.browses.isEmpty)
        XCTAssertEqual(queue.items.map(\.name), ["tree", "a.bin", "empty", "nested", "b.bin"])
        XCTAssertTrue(queue.items.allSatisfy { $0.direction == .upload })
        queue.startOrContinue(); queue.startOrContinue()
        try await wait { fake.browses.count == 1 }
        XCTAssertNotNil(executor.activeJob); XCTAssertTrue(fake.uploads.isEmpty)
        respond(fake, index: 0, entries: [entry("tree", directory: true)])
        try await wait { fake.uploads.count == 1 }
        XCTAssertTrue(queue.items[0].reusedDirectory); XCTAssertTrue(fake.directories.isEmpty)
        XCTAssertEqual(queue.items[2].state, .waiting)
        fake.uploads[0].continuation.resume()
        try await wait { fake.browses.count == 2 }
        respond(fake, index: 1, entries: [])
        try await wait { fake.directories.count == 1 }
        XCTAssertEqual(fake.directories[0].path.components.map(\.name), ["tree", "empty"])
        XCTAssertEqual(fake.uploads.count, 1); XCTAssertEqual(queue.items[3].state, .waiting)
        fake.directories[0].continuation.resume()
        try await wait { fake.browses.count == 3 }
        respond(fake, index: 2, entries: [entry("nested", directory: true)])
        try await wait { fake.uploads.count == 2 }
        XCTAssertTrue(queue.items[3].reusedDirectory); XCTAssertEqual(fake.directories.count, 1)
        fake.uploads[1].continuation.resume()
        try await wait { queue.state == .finished }
        XCTAssertTrue(queue.items.allSatisfy { $0.state == .succeeded })
        XCTAssertNil(executor.activeJob); XCTAssertFalse(queue.hasCredentials)
        XCTAssertTrue(roots.values.allSatisfy { $0.descriptor < 0 })
    }

    func testDownloadSerialParentsEmptyDirectoriesAndSafeFileCommit() async throws {
        let destination = try folder(), fake = ControlledFTP(), executor = TransferExecutor()
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("tree/nested"), withIntermediateDirectories: true)
        try Data("extra".utf8).write(to: destination.appendingPathComponent("tree/extra"))
        let plan = try downloadPlan(destination: destination)
        XCTAssertTrue(plan.canStart)
        let queue = BatchTransferQueue(client: fake, executor: executor)
        try queue.prepare(plan: plan, endpoint: FTPEndpoint(address: "ftp://example.test"), remoteRoot: .root,
                          encoding: .utf8, credentials: .anonymous, destination: LocalDestinationRoot(url: destination))
        XCTAssertTrue(fake.browses.isEmpty); XCTAssertTrue(fake.downloads.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("tree/empty").path))
        XCTAssertEqual(queue.items[0].sizeDescription, "目录")
        XCTAssertEqual(queue.items[1].sizeDescription, ByteCountFormatter.string(fromByteCount: 3, countStyle: .file))
        XCTAssertEqual(queue.items[4].sizeDescription, "大小未知")
        queue.startOrContinue(); queue.startOrContinue()
        try await wait { fake.browses.count == 1 }
        respond(fake, index: 0, entries: [entry("tree", directory: true)])
        try await wait { fake.browses.count == 2 }
        XCTAssertTrue(queue.items[0].reusedDirectory)
        respond(fake, index: 1, entries: [entry("a.bin", directory: false)])
        try await wait { fake.downloads.count == 1 }
        try fake.downloads[0].receive(Data("one".utf8)); fake.downloads[0].progress(3, 3)
        XCTAssertEqual(fake.browses.count, 2); XCTAssertEqual(queue.items[2].state, .waiting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("tree/a.bin").path))
        fake.downloads[0].continuation.resume()
        try await wait { fake.browses.count == 3 }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("tree/a.bin")), Data("one".utf8))
        respond(fake, index: 2, entries: [entry("empty", directory: true)])
        try await wait { fake.browses.count == 4 }
        respond(fake, index: 3, entries: [entry("nested", directory: true)])
        try await wait { fake.browses.count == 5 }
        XCTAssertTrue(queue.items[3].reusedDirectory)
        respond(fake, index: 4, entries: [entry("b.bin", directory: false)])
        try await wait { fake.downloads.count == 2 }
        try fake.downloads[1].receive(Data([255])); fake.downloads[1].continuation.resume()
        try await wait { queue.state == .finished }
        XCTAssertTrue(queue.items.allSatisfy { $0.state == .succeeded && $0.direction == .download })
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("tree/nested/b.bin")), Data([255]))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("tree/extra")), Data("extra".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent("tree/empty").path), [])
        XCTAssertTrue(fake.directories.isEmpty); XCTAssertTrue(fake.uploads.isEmpty); XCTAssertNil(executor.activeJob)
    }

    func testRepresentativePartialResultCategoriesMatchOnlyActualRequests() async throws {
        let base = try folder(), success = base.appendingPathComponent("success.bin"), tree = base.appendingPathComponent("tree")
        let skipped = base.appendingPathComponent("skipped.bin"), cancelled = base.appendingPathComponent("cancelled.bin")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        try Data("one".utf8).write(to: success); try Data("child".utf8).write(to: tree.appendingPathComponent("child.bin"))
        try Data([1]).write(to: skipped); try Data([2]).write(to: cancelled)
        let fake = ControlledFTP(), (plan, roots) = try await uploadPlan([success, tree, skipped, cancelled])
        let queue = BatchTransferQueue(client: fake, executor: TransferExecutor())
        try queue.prepare(plan: plan, endpoint: FTPEndpoint(address: "ftp://example.test"), remoteRoot: .root,
                          encoding: .utf8, credentials: .anonymous, sources: roots)
        queue.startOrContinue(); try await wait { fake.uploads.count == 1 }
        fake.uploads[0].continuation.resume()
        try await wait { fake.browses.count == 1 }; respond(fake, index: 0, entries: [])
        try await wait { fake.directories.count == 1 }
        fake.directories[0].continuation.resume(throwing: FTPError.localFile("mkdir denied"))
        try await wait { fake.browses.count == 2 }; respond(fake, index: 1, entries: [])
        try await wait { queue.state == .paused }
        queue.skip(); queue.skipItem(queue.items[3].id); queue.cancelAll()
        let summary = try XCTUnwrap(queue.summary)
        XCTAssertEqual([summary.succeeded, summary.failed, summary.cancelled, summary.skipped, summary.blocked], [1, 1, 1, 1, 1])
        XCTAssertFalse(summary.allSuccessful); XCTAssertEqual(summary.actualBytes, 3); XCTAssertEqual(summary.successfulBytes, 3)
        XCTAssertEqual(fake.uploads.count, 1); XCTAssertEqual(fake.directories.count, 1); XCTAssertEqual(fake.browses.count, 2)
        XCTAssertTrue(fake.downloads.isEmpty); XCTAssertEqual(summary.entries.count, 5)
        let evidence: [String: Any] = ["scope": "ControlledFTP model, not a live protocol or native UI test",
            "requests": ["upload": fake.uploads.map(\.name), "mkdir": fake.directories.map { $0.path.display },
                         "list": fake.browses.map { $0.path.display }, "downloadCount": fake.downloads.count],
            "results": queue.items.map { ["name": $0.name, "result": $0.state.title, "actualBytes": String($0.actualBytes)] },
            "successfulBytes": summary.successfulBytes!, "actualBytes": summary.actualBytes!, "allSuccessful": summary.allSuccessful]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "partial-result-requests"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testPureEmptyDirectoryPlanCreatesARealTask() async throws {
        let base = try folder(), source = base.appendingPathComponent("empty"), fake = ControlledFTP()
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let (plan, roots) = try await uploadPlan([source])
        let queue = BatchTransferQueue(client: fake, executor: TransferExecutor())
        try queue.prepare(plan: plan, endpoint: FTPEndpoint(address: "ftp://example.test"), remoteRoot: .root,
                          encoding: .utf8, credentials: .anonymous, sources: roots)
        XCTAssertEqual(queue.items.count, 1); XCTAssertNil(queue.items[0].snapshot)
        XCTAssertEqual(queue.items[0].sizeDescription, "目录")
        queue.startOrContinue(); try await wait { fake.browses.count == 1 }
        respond(fake, index: 0, entries: [])
        try await wait { fake.directories.count == 1 }; fake.directories[0].continuation.resume()
        try await wait { queue.state == .finished }
        XCTAssertEqual(queue.items[0].state, .succeeded); XCTAssertEqual(queue.items[0].bytes, 0)
        XCTAssertTrue(fake.uploads.isEmpty); XCTAssertTrue(fake.downloads.isEmpty)
    }

    func testCancelCurrentDirectoryUsesJobTokenAndDoesNotInvalidateOtherRoots() async throws {
        let base = try folder(), fake = ControlledFTP(), executor = TransferExecutor()
        let urls = [base.appendingPathComponent("first"), base.appendingPathComponent("second")]
        try urls.forEach { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: false) }
        let (plan, roots) = try await uploadPlan(urls)
        let queue = BatchTransferQueue(client: fake, executor: executor)
        try queue.prepare(plan: plan, endpoint: FTPEndpoint(address: "ftp://example.test"), remoteRoot: .root,
                          encoding: .utf8, credentials: .anonymous, sources: roots)
        queue.startOrContinue(); try await wait { fake.browses.count == 1 }
        respond(fake, index: 0, entries: [])
        try await wait { fake.directories.count == 1 }
        XCTAssertEqual(queue.cancellationID, fake.directories[0].cancellation.id)
        queue.cancelCurrent()
        XCTAssertTrue(fake.directories[0].cancellation.isCancelled)
        XCTAssertTrue(queue.hasCredentials); XCTAssertNotNil(executor.activeJob)
        fake.directories[0].continuation.resume()
        try await wait { queue.state == .paused }
        XCTAssertEqual(queue.items[0].state, .cancelled)
        queue.skip(); queue.startOrContinue(); try await wait { fake.browses.count == 2 }
        respond(fake, index: 1, entries: [])
        try await wait { fake.directories.count == 2 }; fake.directories[1].continuation.resume()
        try await wait { queue.state == .finished }
        XCTAssertEqual(queue.items[1].state, .succeeded); XCTAssertFalse(queue.hasCredentials)
    }

    func testCancelAllWaitsForDirectoryBackendBeforeScopeRelease() async throws {
        let base = try folder(), source = base.appendingPathComponent("empty"), fake = ControlledFTP()
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let (plan, roots) = try await uploadPlan([source]), executor = TransferExecutor()
        let queue = BatchTransferQueue(client: fake, executor: executor)
        try queue.prepare(plan: plan, endpoint: FTPEndpoint(address: "ftp://example.test"), remoteRoot: .root,
                          encoding: .utf8, credentials: .anonymous, sources: roots)
        queue.startOrContinue(); try await wait { fake.browses.count == 1 }
        respond(fake, index: 0, entries: [])
        try await wait { fake.directories.count == 1 }
        queue.cancelAll()
        XCTAssertEqual(queue.state, .cancelling); XCTAssertTrue(queue.hasCredentials)
        XCTAssertTrue(roots.values.allSatisfy { $0.descriptor >= 0 }); XCTAssertNotNil(executor.activeJob)
        fake.directories[0].continuation.resume()
        try await wait { queue.state == .finished }
        XCTAssertTrue(roots.values.allSatisfy { $0.descriptor < 0 }); XCTAssertNil(executor.activeJob)
        XCTAssertEqual(queue.items[0].state, .cancelled)
    }

    func testFailedDirectorySkipBlocksSubtreeButUnrelatedRootContinues() async throws {
        let base = try folder(), source = base.appendingPathComponent("tree"), other = base.appendingPathComponent("other.bin")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("child"), withIntermediateDirectories: true)
        try Data("child".utf8).write(to: source.appendingPathComponent("child/file"))
        try Data("other".utf8).write(to: other)
        let fake = ControlledFTP(), (plan, roots) = try await uploadPlan([source, other])
        let queue = BatchTransferQueue(client: fake, executor: TransferExecutor())
        var results: [UUID: Int] = [:]
        queue.onResult = { id, _ in results[id, default: 0] += 1 }
        try queue.prepare(plan: plan, endpoint: FTPEndpoint(address: "ftp://example.test"), remoteRoot: .root,
                          encoding: .utf8, credentials: .anonymous, sources: roots)
        queue.startOrContinue(); try await wait { fake.browses.count == 1 }
        respond(fake, index: 0, entries: [])
        try await wait { fake.directories.count == 1 }
        fake.directories[0].continuation.resume(throwing: FTPError.localFile("mkdir denied"))
        try await wait { fake.browses.count == 2 }; respond(fake, index: 1, entries: [])
        try await wait { queue.state == .paused }
        let original = queue.taskResults[queue.items[0].id]
        guard case .failed = original else { return XCTFail("Expected failed root") }
        XCTAssertTrue(queue.items.dropFirst().allSatisfy { $0.state == .waiting })
        queue.startOrContinue(); try await wait { queue.state == .paused }
        XCTAssertTrue(fake.uploads.isEmpty); XCTAssertEqual(fake.browses.count, 2)
        queue.skip()
        XCTAssertEqual(queue.taskResults[queue.items[0].id], original)
        XCTAssertEqual(queue.items[1].state, .blocked(parentID: queue.items[0].id, reason: .failedAncestor))
        XCTAssertEqual(queue.items[2].state, .blocked(parentID: queue.items[1].id, reason: .failedAncestor))
        XCTAssertTrue(queue.items.prefix(3).allSatisfy(\.isEligibleForFailureRetry))
        queue.startOrContinue(); try await wait { fake.uploads.count == 1 }
        XCTAssertEqual(queue.items[3].state, .running); XCTAssertEqual(fake.directories.count, 1)
        fake.uploads[0].continuation.resume(); try await wait { queue.state == .finished }
        XCTAssertEqual(queue.items[3].state, .succeeded); XCTAssertEqual(queue.taskResults.count, 4)
        XCTAssertTrue(results.values.allSatisfy { $0 == 1 }); XCTAssertEqual(results.count, 4)
        queue.cancelAll(); XCTAssertEqual(queue.taskResults[queue.items[0].id], original)
        let request = try XCTUnwrap(queue.beginCollectionRetry())
        XCTAssertNil(request.fixedCredentials)
        XCTAssertEqual(request.plan.nodes.map(\.id), Array(plan.nodes.prefix(3)).map(\.id))
        XCTAssertFalse(request.plan.nodes.contains { $0.id == queue.items[3].id })
        XCTAssertTrue(queue.isLocked); queue.endCollectionRetry(); XCTAssertFalse(queue.isLocked)
    }

    func testExplicitWaitingDirectorySkipIsNotEligibleForFailedRetry() async throws {
        let base = try folder(), first = base.appendingPathComponent("first.bin"), chosen = base.appendingPathComponent("chosen")
        let last = base.appendingPathComponent("last.bin")
        try Data([1]).write(to: first); try Data([3]).write(to: last)
        try FileManager.default.createDirectory(at: chosen.appendingPathComponent("child"), withIntermediateDirectories: true)
        try Data([2]).write(to: chosen.appendingPathComponent("child/file"))
        let fake = ControlledFTP(), (plan, roots) = try await uploadPlan([first, chosen, last])
        let queue = BatchTransferQueue(client: fake, executor: TransferExecutor())
        var results: [UUID: Int] = [:]
        queue.onResult = { id, _ in results[id, default: 0] += 1 }
        try queue.prepare(plan: plan, endpoint: FTPEndpoint(address: "ftp://example.test"), remoteRoot: .root,
                          encoding: .utf8, credentials: .anonymous, sources: roots)
        queue.startOrContinue(); try await wait { fake.uploads.count == 1 }
        fake.uploads[0].continuation.resume(throwing: FTPError.localFile("file denied"))
        try await wait { queue.state == .paused }
        let id = queue.items[1].id
        queue.skipItem(id); queue.skipItem(id)
        XCTAssertEqual(queue.items[1].state, .skipped)
        XCTAssertEqual(queue.items[2].state, .blocked(parentID: id, reason: .skippedAncestor))
        XCTAssertEqual(queue.items[3].state, .blocked(parentID: queue.items[2].id, reason: .skippedAncestor))
        XCTAssertTrue(queue.items[0].isEligibleForFailureRetry)
        XCTAssertFalse(queue.items[1...3].contains(where: \.isEligibleForFailureRetry))
        XCTAssertEqual(queue.taskResults[id], .skipped("用户主动跳过")); XCTAssertEqual(results[id], 1)
        queue.skip(); queue.startOrContinue(); try await wait { fake.uploads.count == 2 }
        fake.uploads[1].continuation.resume(); try await wait { queue.state == .finished }
        XCTAssertEqual(queue.items[4].state, .succeeded)
        XCTAssertTrue(fake.browses.isEmpty); XCTAssertTrue(fake.directories.isEmpty)
        XCTAssertEqual(results.count, 5); XCTAssertTrue(results.values.allSatisfy { $0 == 1 })
        let request = try XCTUnwrap(queue.beginCollectionRetry())
        XCTAssertEqual(request.plan.nodes.map(\.id), [queue.items[0].id])
        XCTAssertNil(request.fixedCredentials); queue.endCollectionRetry()
    }

    func testCancelledDirectoryBlocksDescendantsWithDistinctReason() async throws {
        let base = try folder(), source = base.appendingPathComponent("tree"), other = base.appendingPathComponent("other.bin")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("child"), withIntermediateDirectories: true)
        try Data([1]).write(to: source.appendingPathComponent("child/file")); try Data([2]).write(to: other)
        let fake = ControlledFTP(), (plan, roots) = try await uploadPlan([source, other])
        let queue = BatchTransferQueue(client: fake, executor: TransferExecutor())
        try queue.prepare(plan: plan, endpoint: FTPEndpoint(address: "ftp://example.test"), remoteRoot: .root,
                          encoding: .utf8, credentials: .anonymous, sources: roots)
        queue.startOrContinue(); try await wait { fake.browses.count == 1 }
        respond(fake, index: 0, entries: [])
        try await wait { fake.directories.count == 1 }
        queue.cancelCurrent(); fake.directories[0].continuation.resume()
        try await wait { queue.state == .paused }
        queue.skip()
        XCTAssertEqual(queue.items[1].state, .blocked(parentID: queue.items[0].id, reason: .cancelledAncestor))
        XCTAssertEqual(queue.items[2].state, .blocked(parentID: queue.items[1].id, reason: .cancelledAncestor))
        XCTAssertFalse(queue.items.prefix(3).contains(where: \.isEligibleForFailureRetry))
        queue.startOrContinue(); try await wait { fake.uploads.count == 1 }
        fake.uploads[0].continuation.resume(); try await wait { queue.state == .finished }
        XCTAssertEqual(queue.taskResults[queue.items[0].id], .cancelled)
        XCTAssertEqual(fake.browses.count, 1); XCTAssertEqual(fake.directories.count, 1)
    }

    func testDownloadDirectoryFailureBlocksChildrenWithoutOverwritingConflict() async throws {
        let destination = try folder(), tree = destination.appendingPathComponent("tree"), fake = ControlledFTP()
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        let plan = try downloadPlan(destination: destination), root = try LocalDestinationRoot(url: destination)
        let queue = BatchTransferQueue(client: fake, executor: TransferExecutor())
        try queue.prepare(plan: plan, endpoint: FTPEndpoint(address: "ftp://example.test"), remoteRoot: .root,
                          encoding: .utf8, credentials: .anonymous, destination: root)
        try FileManager.default.removeItem(at: tree); try Data("keep".utf8).write(to: tree)
        queue.startOrContinue(); try await wait { fake.browses.count == 1 }
        respond(fake, index: 0, entries: [entry("tree", directory: true)])
        try await wait { queue.state == .paused }
        let original = queue.taskResults[queue.items[0].id]
        guard case .failed = original else { return XCTFail("Expected local directory conflict") }
        queue.skip(); XCTAssertEqual(queue.state, .finished)
        XCTAssertEqual(queue.taskResults[queue.items[0].id], original)
        XCTAssertTrue(queue.items.dropFirst().allSatisfy {
            if case .blocked(_, .failedAncestor) = $0.state { return true }; return false
        })
        XCTAssertEqual(fake.browses.count, 1); XCTAssertTrue(fake.downloads.isEmpty); XCTAssertTrue(fake.directories.isEmpty)
        XCTAssertEqual(try Data(contentsOf: tree), Data("keep".utf8)); XCTAssertLessThan(root.descriptor, 0)
    }

    func testChangedSourceDirectoryBlocksChildrenWithoutRequests() async throws {
        let base = try folder(), source = base.appendingPathComponent("tree"), outside = try folder(), fake = ControlledFTP()
        let nested = source.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("approved".utf8).write(to: nested.appendingPathComponent("file"))
        try Data("foreign".utf8).write(to: outside.appendingPathComponent("file"))
        let (plan, roots) = try await uploadPlan([source])
        let queue = BatchTransferQueue(client: fake, executor: TransferExecutor())
        try queue.prepare(plan: plan, endpoint: FTPEndpoint(address: "ftp://example.test"), remoteRoot: .root,
                          encoding: .utf8, credentials: .anonymous, sources: roots)
        try FileManager.default.moveItem(at: nested, to: source.appendingPathComponent("original"))
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: outside)
        queue.startOrContinue(); try await wait { fake.browses.count == 1 }
        respond(fake, index: 0, entries: [entry("tree", directory: true)])
        try await wait { queue.state == .paused }
        guard case .failed = queue.items[1].state else { return XCTFail("Expected directory identity failure") }
        XCTAssertEqual(fake.browses.count, 1); XCTAssertTrue(fake.uploads.isEmpty); XCTAssertTrue(fake.directories.isEmpty)
        XCTAssertEqual(queue.items[2].state, .waiting)
        queue.cancelAll()
    }
}

@MainActor
final class BatchQueueTests: XCTestCase {
    func testKeyBatchRetainsSnapshotAcrossReplacementPauseRetryAndReleases() async throws {
        let fake = ControlledFTP(); let executor = TransferExecutor()
        let queue = BatchTransferQueue(client: fake, executor: executor)
        let urls = try files(); let keyURL = urls[0].deletingLastPathComponent().appendingPathComponent("key")
        try Data("-----BEGIN RSA PRIVATE KEY-----\noriginal".utf8).write(to: keyURL)
        let selection = try PrivateKeySelection.select(keyURL)
        weak var released: PrivateKeyMaterial?
        do {
            let material = try selection.material(); released = material
            try queue.prepare(urls, endpoint: FTPEndpoint(address: "sftp://example.test"), path: .root,
                              encoding: .utf8, credentials: .key(username: "member", material: material, passphrase: "phrase"))
        }
        try FileManager.default.removeItem(at: keyURL)
        try await wait { queue.state == .preview }
        queue.startOrContinue(); try await wait { fake.uploads.count == 1 }
        XCTAssertNotNil(released)
        XCTAssertEqual(fake.uploads[0].credentials.privateKey?.digest, selection.digest)
        fake.uploads[0].continuation.resume(throwing: FTPError.localFile("phrase refused"))
        try await wait { queue.state == .paused }
        if case .failed(let text) = queue.items[0].state { XCTAssertFalse(text.contains("phrase")) }
        else { XCTFail("Expected failure") }
        queue.retry(); try await wait { fake.uploads.count == 2 }
        XCTAssertTrue(fake.uploads[0].credentials.privateKey === fake.uploads[1].credentials.privateKey)
        queue.cancelAll(); fake.uploads[1].continuation.resume()
        try await wait { queue.state == .finished }
        XCTAssertFalse(queue.hasCredentials); XCTAssertNil(executor.activeJob)
        fake.uploads.removeAll(); XCTAssertNil(released)
        XCTAssertThrowsError(try selection.material())
    }
    private func wait(_ condition: () -> Bool) async throws {
        let limit = Date().addingTimeInterval(3)
        while !condition() && Date() < limit { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition())
    }
    private func files() throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try ["first.bin", "second.bin"].map { name in
            let url = directory.appendingPathComponent(name); try Data(name.utf8).write(to: url); return url
        }
    }
    func testPreviewValidationAndSerialExecutionPauseExplicitRetry() async throws {
        let fake = ControlledFTP(), executor = TransferExecutor(); let queue = BatchTransferQueue(client: fake, executor: executor)
        let urls = try files(); let endpoint = try FTPEndpoint(address: "example.test")
        XCTAssertThrowsError(try queue.prepare([urls[0], urls[0]], endpoint: endpoint, path: .root, encoding: .utf8, credentials: .anonymous))
        XCTAssertThrowsError(try queue.prepare([urls[0].deletingLastPathComponent()], endpoint: endpoint, path: .root, encoding: .utf8, credentials: .anonymous))
        try queue.prepare(urls, endpoint: endpoint, path: .root, encoding: .utf8, credentials: .anonymous)
        XCTAssertEqual(queue.state, .scanning)
        try await wait { queue.state == .preview }
        XCTAssertTrue(fake.uploads.isEmpty)
        queue.startOrContinue(); queue.startOrContinue()
        try await wait { fake.uploads.count == 1 }
        fake.uploads[0].continuation.resume(throwing: FTPError.localFile("denied"))
        try await wait { queue.state == .paused }
        XCTAssertEqual(fake.uploads.count, 1); XCTAssertTrue(queue.isLocked)
        queue.retry()
        try await wait { fake.uploads.count == 2 }
        XCTAssertNotEqual(queue.items[0].id, queue.items[1].id)
        fake.uploads[1].continuation.resume()
        try await wait { fake.uploads.count == 3 }
        fake.uploads[2].continuation.resume()
        try await wait { queue.state == .finished }
        XCTAssertFalse(queue.hasCredentials); XCTAssertNil(executor.activeJob)
        XCTAssertEqual(queue.items.filter { $0.state == .succeeded }.count, 2)
    }
    func testChangedWaitingFileFailsAndSkipDoesNotSendIt() async throws {
        let fake = ControlledFTP(); let queue = BatchTransferQueue(client: fake, executor: TransferExecutor())
        let urls = try files()
        try queue.prepare(urls, endpoint: FTPEndpoint(address: "example.test"), path: .root, encoding: .utf8, credentials: .anonymous)
        try await wait { queue.state == .preview }
        queue.startOrContinue(); try await wait { fake.uploads.count == 1 }
        try FileManager.default.removeItem(at: urls[1])
        fake.uploads[0].continuation.resume(); try await wait { queue.state == .paused }
        XCTAssertEqual(fake.uploads.count, 1)
        if case .failed = queue.items[1].state {} else { XCTFail("Missing file must fail") }
        queue.skip(); XCTAssertFalse(queue.isLocked); XCTAssertFalse(queue.hasCredentials)
    }
    func testOverwriteDecisionIsPerItemAndCancelAllWaitsForBackend() async throws {
        let fake = ControlledFTP(); fake.autoCheckTargets = false
        let queue = BatchTransferQueue(client: fake, executor: TransferExecutor()); let urls = try files()
        try queue.prepare(urls, endpoint: FTPEndpoint(address: "example.test"), path: .root, encoding: .utf8, credentials: .anonymous)
        try await wait { queue.state == .preview }
        queue.startOrContinue(); try await wait { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [RemoteEntry(name: "first.bin", rawName: Data("first.bin".utf8), isDirectory: false, size: 3)], encoding: .utf8))
        try await wait { queue.overwriteID != nil }
        XCTAssertTrue(fake.uploads.isEmpty)
        queue.confirmOverwrite(UUID()); XCTAssertTrue(fake.uploads.isEmpty)
        queue.confirmOverwrite(queue.overwriteID!)
        try await wait { fake.uploads.count == 1 }
        queue.cancelAll(); XCTAssertTrue(queue.isLocked); XCTAssertTrue(queue.hasCredentials)
        XCTAssertEqual(queue.items[1].state, .cancelled)
        fake.uploads[0].continuation.resume()
        try await wait { queue.state == .finished }
        XCTAssertEqual(fake.uploads.count, 1); XCTAssertFalse(queue.hasCredentials)
        XCTAssertEqual(queue.items[0].state, .cancelled)
    }
    func testModelLocksSiteThroughoutPreviewAndPausedBatch() async throws {
        let fake = ControlledFTP(); let model = AppModel(client: fake, history: isolatedHistory()); let urls = try files()
        let keyURL = urls[0].deletingLastPathComponent().appendingPathComponent("key")
        try Data("-----BEGIN RSA PRIVATE KEY-----\nkey".utf8).write(to: keyURL)
        model.transport = .sftp; model.address = "example.test"; model.username = "member"
        model.authenticationMethod = .privateKey; model.choosePrivateKey(keyURL); model.passphrase = "phrase"
        model.connect(); try await wait { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await wait { model.hasDirectory }
        model.prepareBatch(urls); XCTAssertFalse(model.canEditConnection)
        model.address = "other.test"; model.refresh(); XCTAssertEqual(model.address, "example.test")
        model.authenticationMethod = .password; model.passphrase = "changed"; model.choosePrivateKey(urls[0])
        XCTAssertEqual(model.authenticationMethod, .privateKey); XCTAssertEqual(model.passphrase, "phrase")
        XCTAssertEqual(model.privateKeySelection?.url, keyURL)
        XCTAssertEqual(fake.browses.count, 1)
        model.batch.cancelAll()
        try await wait { model.canEditConnection }
        XCTAssertTrue(fake.uploads.isEmpty)
    }
}

@MainActor
final class TransferMetricsTests: XCTestCase {
    func testFiveSecondWindowStallUnknownZeroAndOutOfOrder() {
        var metrics = TransferMetrics()
        metrics.sample(bytes: 0, total: 1000, at: 0)
        metrics.sample(bytes: 100, total: 1000, at: 1)
        metrics.sample(bytes: 600, total: 1000, at: 6)
        XCTAssertEqual(metrics.estimate(at: 6).speed!, 100, accuracy: 0.001)
        XCTAssertEqual(metrics.estimate(at: 6).remaining!, 4, accuracy: 0.001)
        metrics.sample(bytes: 2, total: 1000, at: 5)
        XCTAssertEqual(metrics.bytes, 600)
        XCTAssertNil(metrics.estimate(at: 11).speed)
        metrics.sample(bytes: 700, total: -1, at: 12); XCTAssertNil(metrics.estimate(at: 12).remaining)
        var empty = TransferMetrics(); empty.sample(bytes: 0, total: 0, at: 1)
        XCTAssertNil(empty.estimate(at: 1).speed); XCTAssertNil(empty.estimate(at: 1).remaining)
    }
    func testMetricPresentationAtMostOncePerSecond() {
        var now = 0.0; let monitor = TransferMetricsMonitor(clock: { now })
        monitor.reset(total: 100)
        XCTAssertTrue(monitor.update(bytes: 1, total: 100))
        now = 0.2; XCTAssertFalse(monitor.update(bytes: 2, total: 100))
        now = 0.9; XCTAssertFalse(monitor.emit())
        now = 1; XCTAssertTrue(monitor.emit()); XCTAssertEqual(monitor.estimate.bytes, 2)
        monitor.stop()
    }
}

@MainActor
final class TransferHistoryTests: XCTestCase {
    private func writeLegacy(_ url: URL) throws -> TransferRecord {
        struct Legacy: Encodable { let version = 1; let records: [TransferRecord] }
        let old = TransferRecord(id: UUID(), direction: .download, name: "旧文件", transport: .ftp,
            server: "example.test", target: "ftp://example.test/旧文件", started: Date(timeIntervalSince1970: 100),
            ended: Date(timeIntervalSince1970: 200), bytes: 7, result: "失败", error: "旧错误")
        try JSONEncoder().encode(Legacy(records: [old])).write(to: url)
        return old
    }
    private func task(_ result: TransferTaskResult, kind: TransferTaskKind = .file, id: UUID = UUID()) throws -> TransferRecord {
        .task(id: id, direction: .download, kind: kind, name: "file", endpoint: try FTPEndpoint(address: "sftp://example.test"),
            target: "/tmp/file", credentials: try .account(username: "member", password: "secret"),
            result: result, started: Date(), bytes: 7, batchID: UUID())
    }
    func testVersionOnePreservesEveryFieldAndBacksUpBeforeFirstVersionTwoWrite() throws {
        let url = try location(), old = try writeLegacy(url), original = try Data(contentsOf: url)
        let history = TransferHistory(url: url)
        XCTAssertEqual(history.records, [old]); XCTAssertEqual(history.records[0].taskKind, .file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.backupURL.path))
        history.record(try task(.skipped("明确跳过")))
        XCTAssertEqual(try Data(contentsOf: history.backupURL), original)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(json["version"] as? Int, 2)
        let loaded = TransferHistory(url: url)
        XCTAssertNil(loaded.error); XCTAssertEqual(loaded.records, history.records)
        XCTAssertTrue(loaded.records.contains(old))
    }
    func testAllTerminalKindsRoundTripAreWriteOnceAndRetentionDoesNotChangeSessionResults() throws {
        let url = try location(), history = TransferHistory(url: url), parent = UUID()
        let results: [TransferTaskResult] = [.succeeded, .failed("secret rejected"), .cancelled,
                                            .skipped("用户跳过"), .blocked(parentID: parent, reason: .failedAncestor)]
        for result in results {
            let next = try task(result, kind: .directory)
            history.record(next); history.record(next)
        }
        XCTAssertEqual(history.records.count, 5); XCTAssertTrue(history.records.allSatisfy { $0.bytes == 0 && $0.taskKind == .directory })
        XCTAssertEqual(TransferHistory(url: url).records, history.records)
        let blocked = try XCTUnwrap(history.records.first { $0.result == "依赖阻塞" })
        XCTAssertEqual(blocked.blockedParentID, parent); XCTAssertEqual(blocked.blockedReason, .failedAncestor)
        var complete: [TransferRecord] = []
        for _ in 0..<105 { let next = try task(.succeeded); complete.append(next); history.record(next) }
        XCTAssertEqual(history.records.count, 100); XCTAssertEqual(complete.count, 105)
        XCTAssertEqual(Set(history.records.map(\.id)), Set(complete.suffix(100).map(\.id)))
        XCTAssertEqual(TransferHistory(url: url).records, history.records)
    }
    func testBackupFailureOrDifferentExistingBackupNeverOverwritesOriginal() throws {
        for different in [false, true] {
            let url = try location(); _ = try writeLegacy(url); let original = try Data(contentsOf: url)
            let history = TransferHistory(url: url, backupWriter: { _, _ in throw POSIXError(.EACCES) })
            if different { try Data("keep-backup".utf8).write(to: history.backupURL) }
            let request = try job(); request.finish(.succeeded)
            history.record(request, target: "target", bytes: 3)
            XCTAssertNotNil(history.error); XCTAssertEqual(request.outcome, .succeeded)
            XCTAssertEqual(try Data(contentsOf: url), original); XCTAssertEqual(history.records.count, 1)
            history.clear(); XCTAssertNotNil(history.error); XCTAssertEqual(try Data(contentsOf: url), original)
            if different { XCTAssertEqual(try Data(contentsOf: history.backupURL), Data("keep-backup".utf8)) }
        }
    }
    func testIncompleteBackupAndCorruptVersionTwoStayProtected() throws {
        let url = try location(); _ = try writeLegacy(url); let original = try Data(contentsOf: url)
        let history = TransferHistory(url: url, backupWriter: { _, target in try Data("incomplete".utf8).write(to: target) })
        history.record(try task(.succeeded))
        XCTAssertNotNil(history.error); XCTAssertEqual(try Data(contentsOf: url), original)
        let damaged = Data("{\"version\":2,\"records\":[invalid]}".utf8); try damaged.write(to: url)
        let protected = TransferHistory(url: url)
        protected.record(try task(.succeeded)); protected.clear()
        XCTAssertNotNil(protected.error); XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

    func testMigrationSaveAndClearFailuresKeepOriginalAndBackup() throws {
        let url = try location(); _ = try writeLegacy(url); let original = try Data(contentsOf: url)
        let history = TransferHistory(url: url, writer: { _, _ in throw POSIXError(.ENOSPC) })
        let request = try job(); request.finish(.succeeded)
        history.record(request, target: "target", bytes: 3)
        XCTAssertNotNil(history.error); XCTAssertEqual(request.outcome, .succeeded)
        XCTAssertEqual(try Data(contentsOf: history.backupURL), original); XCTAssertEqual(try Data(contentsOf: url), original)
        history.clear(); XCTAssertNotNil(history.error); XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(history.records.count, 1)
    }
    func testRestartLoadsOnlyRecordsAndNeverRestoresOrStartsWork() throws {
        let url = try location(), history = TransferHistory(url: url)
        history.record(try task(.failed("error"))); history.record(try task(.skipped("skip")))
        let fake = ControlledFTP(), reopened = TransferHistory(url: url)
        let model = AppModel(client: fake, history: reopened)
        XCTAssertEqual(model.history.records, history.records)
        XCTAssertFalse(model.batch.isLocked); XCTAssertTrue(model.batch.items.isEmpty)
        XCTAssertEqual(model.collectionScan.phase, .finished); XCTAssertNil(model.collectionScan.plan)
        XCTAssertFalse(model.hasCollectionCredentials); XCTAssertFalse(model.hasDirectory)
        XCTAssertTrue(fake.browses.isEmpty); XCTAssertTrue(fake.uploads.isEmpty)
        XCTAssertTrue(fake.downloads.isEmpty); XCTAssertTrue(fake.directories.isEmpty)
    }

    func testTypedTaskRecordNeverSerializesSecretsOrAuthorization() throws {
        let url = try location(), history = TransferHistory(url: url)
        let bytes = Data("private-material-fixture".utf8)
        let credentials = try FTPCredentials.key(username: "member", material: PrivateKeyMaterial(bytes), passphrase: "phrase-fixture")
        let record = TransferRecord.task(id: UUID(), direction: .upload, kind: .directory, name: "tree", endpoint: try FTPEndpoint(address: "sftp://example.test"),
            target: "sftp://member:phrase-fixture@example.test/tree", credentials: credentials,
            result: .failed("private-material-fixture phrase-fixture"), started: Date(), bytes: 999, batchID: UUID())
        history.record(record)
        let text = try String(contentsOf: url)
        for forbidden in ["private-material-fixture", "phrase-fixture", "member:", "bookmark", "password", "passphrase", "privateKey"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        XCTAssertEqual(history.records[0].bytes, 0); XCTAssertTrue(text.contains("redacted"))
    }

    func testPrivateKeyFailureHistoryNeverSerializesAuthenticationMaterial() throws {
        let url = try location(); let history = TransferHistory(url: url)
        let bytes = Data("test-private-material".utf8)
        let credentials = try FTPCredentials.key(username: "member", material: PrivateKeyMaterial(bytes), passphrase: "test-key-phrase")
        let job = TransferJob(direction: .upload, endpoint: try FTPEndpoint(address: "sftp://example.test"),
                              path: .root, encoding: .utf8, credentials: credentials, localURL: URL(fileURLWithPath: "/tmp/test.bin"))
        job.finish(.failed("test-private-material test-key-phrase"))
        history.record(job, target: "sftp://example.test/test.bin", bytes: 0)
        let text = try String(contentsOf: url)
        XCTAssertFalse(text.contains("test-private-material")); XCTAssertFalse(text.contains("test-key-phrase"))
        XCTAssertFalse(text.contains("bookmark")); XCTAssertTrue(text.contains("[redacted]"))
    }
    private func location() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("history.json")
    }
    private func job() throws -> TransferJob {
        TransferJob(direction: .upload, endpoint: try FTPEndpoint(address: "example.test"), path: .root, encoding: .utf8,
                    credentials: try .account(username: "member", password: "secret"), localURL: URL(fileURLWithPath: "/tmp/file.bin"))
    }
    func testTerminalOnceRetentionRestartNoCredentialsAndClear() throws {
        let url = try location(); let store = TransferHistory(url: url)
        let first = try job(); first.finish(.failed("ftp://member:secret@example.test rejected secret"))
        store.record(first, target: "ftp://member:secret@example.test/file.bin", bytes: 4)
        store.record(first, target: "same", bytes: 4); XCTAssertEqual(store.records.count, 1)
        let text = try String(contentsOf: url)
        XCTAssertFalse(text.contains("secret")); XCTAssertFalse(text.contains("member:")); XCTAssertFalse(text.contains("password"))
        for _ in 0..<100 { let next = try job(); next.finish(.succeeded); store.record(next, target: "fixed", bytes: 8) }
        XCTAssertEqual(store.records.count, 100); XCTAssertFalse(store.records.contains { $0.id == first.id })
        let reopened = TransferHistory(url: url); XCTAssertEqual(reopened.records, store.records)
        XCTAssertNil(reopened.error)
        reopened.clear(); XCTAssertTrue(reopened.records.isEmpty)
        XCTAssertTrue(TransferHistory(url: url).records.isEmpty)
    }
    func testWriteFailureNeverChangesJobOutcomeAndCorruptionIsPreserved() throws {
        let url = try location(); let store = TransferHistory(url: url, writer: { _, _ in throw POSIXError(.ENOSPC) })
        let request = try job(); request.finish(.succeeded); store.record(request, target: "fixed", bytes: 2)
        XCTAssertEqual(request.outcome, .succeeded); XCTAssertNotNil(store.error)
        XCTAssertTrue(store.records.isEmpty)
        let damaged = Data("damaged history".utf8); try damaged.write(to: url)
        let broken = TransferHistory(url: url); XCTAssertNotNil(broken.error)
        broken.record(request, target: "fixed", bytes: 2); broken.clear()
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

}
