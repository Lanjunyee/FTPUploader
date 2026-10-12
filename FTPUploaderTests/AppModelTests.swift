import XCTest

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

    func testByteProgressKeepsDirectoryRevisionAndEventProjectionUnchanged() async throws {
        let fake = ControlledFTP(), model = AppModel(client: fake, history: isolatedHistory())
        let listing = (0..<1_000).map { RemoteEntry(name: "item-\($0)", rawName: Data("item-\($0)".utf8), kind: .regularFile, size: Int64($0)) }
        model.address = "example.test"; model.connect(); try await waitUntil { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: .init(entries: listing, encoding: .utf8))
        try await waitUntil { model.hasDirectory }
        let revision = model.directoryContentRevision
        var cache = DirectoryProjectionCache()
        cache.update(model.entries, query: "", sort: .name, ascending: true, generation: revision, location: model.currentLocation)
        cache.select([listing[0].id])
        let traversals = cache.selectionTraversalCount
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 9, count: 200).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        model.selectFile(url); model.upload(); try await waitUntil { fake.uploads.count == 1 }
        fake.uploads[0].progress(1, 200); try await waitUntil { model.sent == 1 }
        for value in 2...150 {
            fake.uploads[0].progress(Int64(value), 200)
            XCTAssertTrue(cache.isCurrent(model.entries, query: "", sort: .name, ascending: true,
                generation: model.directoryContentRevision, location: model.currentLocation))
            XCTAssertEqual(cache.selectedRow?.id, listing[0].id)
        }
        XCTAssertEqual(model.directoryContentRevision, revision)
        XCTAssertEqual(cache.projectionCount, 1); XCTAssertEqual(cache.rowProjectionCount, 1)
        XCTAssertEqual(cache.selectionTraversalCount, traversals)
        model.cancelOperation(); fake.uploads[0].continuation.resume(throwing: CancellationError())
        try await waitUntil { !model.isBusy }; XCTAssertEqual(model.directoryContentRevision, revision)
    }
    func testOverwriteResumeUsesOneAuthorizationComparisonAndOneFinalHash() async throws {
        let fake = ControlledFTP(), counts = TransferDiagnostics(); fake.autoCheckTargets = false
        let model = AppModel(client: fake, history: isolatedHistory(), diagnostics: counts)
        try await connect(model, fake)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let payload = Data("confirmed contents".utf8); try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        model.selectFile(url); model.upload(); try await waitUntil { fake.browses.count == 2 }
        let target = RemoteEntry(name: url.lastPathComponent, rawName: Data(url.lastPathComponent.utf8), kind: .regularFile, size: 1)
        fake.browses[1].continuation.resume(returning: .init(entries: [target], encoding: .utf8))
        try await waitUntil { model.overwriteRequestID != nil }
        XCTAssertEqual(counts.snapshot["hashPasses"], 2)
        model.confirmOverwrite(try XCTUnwrap(model.overwriteRequestID))
        try await waitUntil { fake.uploads.count == 1 }
        XCTAssertEqual(counts.snapshot["hashPasses"], 4, "Resume adds only initial-authorization comparison and final fd hash")
        XCTAssertEqual(counts.snapshot["hashBytes"], Int64(payload.count * 4))
        XCTAssertEqual(fake.browses.count, 2, "Same decision is not a new automatic target query")
        fake.uploads[0].continuation.resume()
        try await waitUntil { model.uploadState == .succeeded && fake.browses.count == 3 }
        fake.browses[2].continuation.resume(returning: .init(entries: [], encoding: .utf8))
        try await waitUntil { !model.isBusy }
    }
    func testChangedOverwriteSourceNeverRestartsWhenTargetWouldNowBeAbsent() async throws {
        let fake = ControlledFTP(); fake.autoCheckTargets = false
        let model = AppModel(client: fake, history: isolatedHistory()); try await connect(model, fake)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("old".utf8).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        model.selectFile(url); model.upload(); try await waitUntil { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: .init(entries: [.init(name: url.lastPathComponent, rawName: Data(url.lastPathComponent.utf8), kind: .regularFile, size: 3)], encoding: .utf8))
        try await waitUntil { model.overwriteRequestID != nil }
        let id = try XCTUnwrap(model.overwriteRequestID)
        try Data("new".utf8).write(to: url); fake.autoCheckTargets = true
        model.confirmOverwrite(id); try await waitUntil { !model.isBusy }
        XCTAssertEqual(model.uploadState, .cancelled); XCTAssertTrue(model.canUpload)
        XCTAssertEqual(fake.browses.count, 2); XCTAssertTrue(fake.uploads.isEmpty)
        XCTAssertNotNil(model.selectionError); model.confirmOverwrite(id); await Task.yield()
        XCTAssertTrue(fake.uploads.isEmpty); XCTAssertEqual(model.uploadState, .cancelled)
        try await model.history.drain(); XCTAssertEqual(model.history.records.first?.result, "取消")
        XCTAssertEqual(model.history.records.first?.bytes, 0)
    }
    func testStableSingleUploadUsesExactlyTwoFullHashesAndVerifiedSource() async throws {
        let fake = ControlledFTP(), counts = TransferDiagnostics()
        let model = AppModel(client: fake, history: isolatedHistory(), diagnostics: counts)
        try await connect(model, fake)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let payload = Data(repeating: 37, count: 2 * 1024 * 1024 + 7)
        try payload.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        model.selectFile(url); model.upload(); try await waitUntil { fake.uploads.count == 1 }
        XCTAssertEqual(counts.snapshot["hashPasses"], 2)
        XCTAssertEqual(counts.snapshot["hashBytes"], Int64(payload.count * 2))
        let source = try XCTUnwrap(fake.uploadSources.first)
        XCTAssertEqual(source.expected.size, Int64(payload.count)); try source.validateDescriptor()
        fake.uploads[0].continuation.resume()
        try await waitUntil { model.uploadState == .succeeded && fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: .init(entries: [], encoding: .utf8))
        try await waitUntil { !model.isBusy }
        XCTAssertEqual(counts.snapshot["hashPasses"], 2); XCTAssertEqual(counts.snapshot["hashBytes"], Int64(payload.count * 2))
        try await model.history.drain(); XCTAssertEqual(model.history.records.first?.bytes, Int64(payload.count))
    }
    func testUploadTerminalHistoryUsesFrozenBytesWithinDisplayThrottleForAllOutcomes() async throws {
        for outcome in ["success", "failure", "cancel"] {
            let fake = ControlledFTP(), actualModel = AppModel(client: fake, history: isolatedHistory())
            try await connect(actualModel, fake)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data(repeating: 7, count: 200).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
            actualModel.selectFile(file); actualModel.upload()
            try await waitUntil { fake.uploads.count == 1 }
            let request = fake.uploads[0]
            request.progress(1, 200); try await waitUntil { actualModel.sent == 1 }
            for bytes in 2...150 { request.progress(Int64(bytes), 200) }
            XCTAssertEqual(actualModel.sent, 1, "Backend samples are not per-callback UI tasks")
            if outcome == "success" { request.continuation.resume() }
            else if outcome == "failure" { request.continuation.resume(throwing: FTPError.localFile("rejected")) }
            else { actualModel.cancelOperation(); XCTAssertEqual(actualModel.uploadState, .cancelling); request.continuation.resume(throwing: CancellationError()) }
            try await waitUntil { !actualModel.isUploading }
            let expected: Int64 = outcome == "success" ? 200 : 150
            XCTAssertEqual(actualModel.sent, expected); XCTAssertEqual(actualModel.metrics.bytes, expected)
            try await actualModel.history.drain()
            XCTAssertEqual(actualModel.history.records.first?.bytes, expected)
            let terminal = actualModel.uploadState
            request.progress(999, 999); await Task.yield()
            XCTAssertEqual(actualModel.sent, expected); XCTAssertEqual(actualModel.uploadState, terminal)
            XCTAssertEqual(actualModel.history.records.count, 1)
            if outcome == "success" {
                try await waitUntil { fake.browses.count == 2 }
                fake.browses[1].continuation.resume(returning: .init(entries: [], encoding: .utf8))
                try await waitUntil { !actualModel.isDirectoryLoading }
            }
        }
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
            if change == "content" {
                try await waitUntil { !model.isBusy }
                XCTAssertEqual(model.uploadState, .cancelled)
                XCTAssertEqual(fake.browses.count, 2, "Stale approval must not automatically query or send changed content")
                XCTAssertNotNil(model.selectionError); XCTAssertTrue(fake.uploads.isEmpty)
                model.confirmOverwrite(id); XCTAssertEqual(fake.browses.count, 2)
                model.upload() // A new explicit user action, not an automatic restart.
            }
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
