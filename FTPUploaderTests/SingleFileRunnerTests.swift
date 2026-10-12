import XCTest

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
    func testUnknownDownloadTerminalCountsReceivedPayloadWithoutLastDisplaySampleForAllOutcomes() async throws {
        for outcome in ["success", "failure", "cancel"] {
            let fake = ControlledFTP(), model = AppModel(client: fake, history: isolatedHistory())
            let file = RemoteEntry(name: "unknown", rawName: Data("unknown".utf8), kind: .regularFile, size: nil)
            model.address = "example.test"; model.connect(); try await wait { fake.browses.count == 1 }
            fake.browses[0].continuation.resume(returning: .init(entries: [file], encoding: .utf8))
            try await wait { model.hasDirectory }
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: destination) }
            model.download(file, to: destination); try await wait { fake.downloads.count == 1 }
            let request = fake.downloads[0], payload = Data("payload-without-display-callback".utf8)
            try request.receive(Data(payload.prefix(1))); request.progress(1, -1)
            try await wait { model.downloadBytes == 1 }; XCTAssertNil(model.metrics.estimate.total)
            try request.receive(Data(payload.dropFirst()))
            XCTAssertEqual(model.downloadBytes, 1)
            if outcome == "success" { request.continuation.resume() }
            else if outcome == "failure" { request.continuation.resume(throwing: FTPError.localFile("rejected")) }
            else { model.cancelOperation(); XCTAssertEqual(model.downloadState, .cancelling); request.continuation.resume(throwing: CancellationError()) }
            try await wait { !model.isDownloading }
            let expected = Int64(payload.count)
            XCTAssertEqual(model.downloadBytes, expected); XCTAssertEqual(model.metrics.bytes, expected)
            try await model.history.drain(); XCTAssertEqual(model.history.records.first?.bytes, expected)
            let terminal = model.downloadState
            request.progress(999, 999); XCTAssertThrowsError(try request.receive(Data("late".utf8))); await Task.yield()
            XCTAssertEqual(model.downloadBytes, expected); XCTAssertEqual(model.downloadState, terminal)
            if outcome == "success" { XCTAssertEqual(try Data(contentsOf: destination), payload) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path)) }
        }
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

    func testSingleDownloadTerminalCleanupReleasesScopeBeforeUnlockWithRetainedCallbacks() async throws {
        for fault in ["none", "network", "close", "commit", "cleanup", "network-cleanup", "cancel", "confirmation-cancel", "confirm-then-cancel"] {
            let fake = ControlledFTP()
            let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("old".utf8).write(to: target)
            defer { try? FileManager.default.removeItem(at: target) }
            var starts = 0, stops = 0
            var descriptor: Int32 = -1
            var retainedSink: LocalDownload?
            weak var observed: AppModel?
            let scope = LocalSecurityScope(start: { url in
                XCTAssertEqual(url, target); starts += 1; return true
            }, stop: { url in
                XCTAssertEqual(url, target); stops += 1
                XCTAssertTrue(observed?.isBusy == true, "Unlock must follow resource release")
                XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
                XCTAssertEqual(errno, EBADF)
            })
            let model = AppModel(client: fake, history: isolatedHistory(), makeDownload: { url, identity in
                let sink = try LocalDownload(destination: url, authorizedIdentity: identity, scope: scope,
                    write: { handle, bytes in descriptor = handle.fileDescriptor; try handle.write(contentsOf: bytes) },
                    close: { handle in
                        if fault == "close" { throw POSIXError(.EIO) }
                        try handle.close()
                    }, rename: { source, destination, replace in
                        if fault == "commit" { throw POSIXError(.EACCES) }
                        if replace { _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: destination), withItemAt: URL(fileURLWithPath: source)) }
                        else { try FileManager.default.moveItem(atPath: source, toPath: destination) }
                    })
                retainedSink = sink
                if fault.contains("cleanup") {
                    try Data("unowned".utf8).write(to: sink.temporary.deletingLastPathComponent().appendingPathComponent("unexpected"))
                }
                return sink
            })
            observed = model
            let entry = RemoteEntry(name: "file", rawName: Data("file".utf8), kind: .regularFile, size: 3)
            model.address = "example.test"; model.connect()
            try await wait { fake.browses.count == 1 }
            fake.browses[0].continuation.resume(returning: .init(entries: [entry], encoding: .utf8))
            try await wait { model.hasDirectory }
            model.download(entry, to: target, authorizedIdentity: try LocalDownload.identity(target))
            try await wait { fake.downloads.count == 1 }
            let sink = try XCTUnwrap(retainedSink)
            defer { try? FileManager.default.removeItem(at: sink.temporary.deletingLastPathComponent()) }
            try fake.downloads[0].receive(Data("new".utf8))
            XCTAssertEqual(starts, 1); XCTAssertEqual(stops, 0)
            if fault == "cancel" {
                model.cancelOperation()
                XCTAssertTrue(model.isBusy); XCTAssertEqual(stops, 0)
            }
            let confirming = fault == "confirmation-cancel" || fault == "confirm-then-cancel"
            if confirming { try Data("changed".utf8).write(to: target) }
            if fault.hasPrefix("network") {
                fake.downloads[0].continuation.resume(throwing: FTPError.transport(code: 56, response: 552, message: "backend refusal", upload: false))
            } else { fake.downloads[0].continuation.resume() }
            if confirming {
                try await wait { model.downloadConfirmationID != nil }
                XCTAssertEqual(stops, 0); XCTAssertTrue(model.isBusy)
                let id = try XCTUnwrap(model.downloadConfirmationID)
                if fault == "confirm-then-cancel" { model.confirmDownloadCommit(id); model.cancelOperation() }
                else { model.cancelDownloadConfirmation(id) }
                XCTAssertTrue(model.isBusy)
            }
            try await wait { !model.isBusy }
            XCTAssertEqual(stops, 1)
            XCTAssertEqual(model.history.records.count, 1)
            let succeeds = fault == "none" || fault == "cleanup"
            if succeeds { XCTAssertEqual(model.downloadState, .succeeded) }
            else if fault.contains("cancel") { XCTAssertEqual(model.downloadState, .cancelled) }
            else {
                guard case .failed(let message) = model.downloadState else { return XCTFail("Expected failure") }
                if fault.hasPrefix("network") { XCTAssertTrue(message.contains("backend refusal")); XCTAssertFalse(message.contains("清理")) }
            }
            XCTAssertEqual(try Data(contentsOf: target), succeeds ? Data("new".utf8) : Data(confirming ? "changed".utf8 : "old".utf8))
            XCTAssertEqual(model.downloadCleanupError != nil, fault.contains("cleanup"))
            let finalRecords = model.history.records
            let finalState = model.downloadState
            XCTAssertThrowsError(try fake.downloads[0].receive(Data("late".utf8)))
            fake.downloads[0].progress(999, 999)
            try sink.cleanUp(); XCTAssertThrowsError(try sink.commit())
            await Task.yield()
            XCTAssertEqual(model.downloadState, finalState)
            XCTAssertEqual(model.history.records, finalRecords)
            retainedSink = nil
            XCTAssertEqual(stops, 1, "Retained callbacks cannot retain or double-release authorization")
        }
    }

    func testSingleDownloadRepeatedChangesRequireFreshIDsAndIgnoreStaleButtons() async throws {
        for acceptFinal in [false, true] {
            let fake = ControlledFTP(), model = AppModel(client: fake, history: isolatedHistory())
            let entry = RemoteEntry(name: "file", rawName: Data("file".utf8), kind: .regularFile, size: 3)
            let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: target) }
            model.address = "example.test"; model.connect()
            try await wait { fake.browses.count == 1 }
            fake.browses[0].continuation.resume(returning: .init(entries: [entry], encoding: .utf8))
            try await wait { model.hasDirectory }
            model.download(entry, to: target)
            try await wait { fake.downloads.count == 1 }
            try fake.downloads[0].receive(Data("new".utf8))
            try Data("A".utf8).write(to: target)
            fake.downloads[0].continuation.resume()
            try await wait { model.downloadConfirmationID != nil }
            let first = try XCTUnwrap(model.downloadConfirmationID)
            fake.downloads[0].progress(999, 999)
            XCTAssertThrowsError(try fake.downloads[0].receive(Data("late while confirming".utf8)))
            await Task.yield()
            XCTAssertEqual(model.downloadConfirmationID, first)
            try Data("BB".utf8).write(to: target)
            model.confirmDownloadCommit(first)
            try await wait { model.downloadConfirmationID != nil }
            let second = try XCTUnwrap(model.downloadConfirmationID)
            XCTAssertNotEqual(first, second)
            model.confirmDownloadCommit(first); model.cancelDownloadConfirmation(first)
            XCTAssertEqual(model.downloadConfirmationID, second)
            XCTAssertEqual(try Data(contentsOf: target), Data("BB".utf8))
            try Data("CCC".utf8).write(to: target)
            model.confirmDownloadCommit(second)
            try await wait { model.downloadConfirmationID != nil }
            let third = try XCTUnwrap(model.downloadConfirmationID)
            XCTAssertNotEqual(second, third)
            model.confirmDownloadCommit(second); model.cancelDownloadConfirmation(second)
            XCTAssertEqual(model.downloadConfirmationID, third)
            XCTAssertTrue(model.isBusy); XCTAssertTrue(model.history.records.isEmpty)
            XCTAssertEqual(try Data(contentsOf: target), Data("CCC".utf8))
            if acceptFinal { model.confirmDownloadCommit(third) }
            else { model.cancelDownloadConfirmation() }
            try await wait { !model.isBusy }
            XCTAssertEqual(model.downloadState, acceptFinal ? .succeeded : .cancelled)
            XCTAssertEqual(model.downloadBytes, 3)
            try await model.history.drain()
            XCTAssertEqual(model.history.records.first?.bytes, 3, "Accounting freezes before user confirmation")
            XCTAssertEqual(try Data(contentsOf: target), acceptFinal ? Data("new".utf8) : Data("CCC".utf8))
            XCTAssertEqual(model.history.records.count, 1)
            model.confirmDownloadCommit(first); model.confirmDownloadCommit(third)
            XCTAssertEqual(model.history.records.count, 1)
            XCTAssertEqual(fake.downloads.count, 1)
        }
    }

    func testSingleDownloadDecisionRejectsReplacementLinkOrDirectory() async throws {
        for link in [false, true] {
            let fake = ControlledFTP(), model = AppModel(client: fake, history: isolatedHistory())
            let entry = RemoteEntry(name: "file", rawName: Data("file".utf8), kind: .regularFile, size: 3)
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let target = base.appendingPathComponent("target"), protected = base.appendingPathComponent("protected")
            try Data("protected".utf8).write(to: protected)
            model.address = "example.test"; model.connect()
            try await wait { fake.browses.count == 1 }
            fake.browses[0].continuation.resume(returning: .init(entries: [entry], encoding: .utf8))
            try await wait { model.hasDirectory }
            model.download(entry, to: target)
            try await wait { fake.downloads.count == 1 }
            try fake.downloads[0].receive(Data("new".utf8))
            try Data("A".utf8).write(to: target)
            fake.downloads[0].continuation.resume()
            try await wait { model.downloadConfirmationID != nil }
            let id = try XCTUnwrap(model.downloadConfirmationID)
            try FileManager.default.removeItem(at: target)
            if link { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: protected) }
            else { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
            model.confirmDownloadCommit(id)
            try await wait { !model.isBusy }
            guard case .failed = model.downloadState else { return XCTFail("Unsafe replacement accepted") }
            XCTAssertNil(model.downloadConfirmationID)
            XCTAssertEqual(try Data(contentsOf: protected), Data("protected".utf8))
            if link { XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path), protected.path) }
            else { XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), []) }
            XCTAssertEqual(model.history.records.count, 1)
        }
    }

    func testSharedSingleDownloadHandlesEmptyNormalAuthorizedAndProtocolRejection() async throws {
        for (payload, authorized, rejected) in [(Data(), false, false), (Data([0, 255, 42]), false, false),
                                               (Data("new".utf8), true, false), (Data("new".utf8), true, true)] {
            let fake = ControlledFTP(), model = AppModel(client: fake, history: isolatedHistory())
            let entry = RemoteEntry(name: "file", rawName: Data("file".utf8), kind: .regularFile, size: Int64(payload.count))
            let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: target) }
            if authorized { try Data("old".utf8).write(to: target) }
            model.address = "example.test"; model.connect()
            try await wait { fake.browses.count == 1 }
            fake.browses[0].continuation.resume(returning: .init(entries: [entry], encoding: .utf8))
            try await wait { model.hasDirectory }
            model.download(entry, to: target, authorizedIdentity: try LocalDownload.identity(target))
            try await wait { fake.downloads.count == 1 }
            try fake.downloads[0].receive(payload)
            if rejected { fake.downloads[0].continuation.resume(throwing: FTPError.transport(code: 56, response: 552, message: "final rejection", upload: false)) }
            else { fake.downloads[0].continuation.resume() }
            try await wait { !model.isBusy }
            XCTAssertNil(model.downloadConfirmationID)
            if rejected { guard case .failed = model.downloadState else { return XCTFail("Expected protocol failure") } }
            else { XCTAssertEqual(model.downloadState, .succeeded) }
            XCTAssertEqual(try Data(contentsOf: target), rejected ? Data("old".utf8) : payload)
            XCTAssertEqual(model.history.records.count, 1)
        }
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
final class LocalDownloadScopeTests: XCTestCase {
    func testExplicitCleanupDestructorFallbackAndUnscopedAccessArePaired() throws {
        for explicit in [false, true] {
            for granted in [false, true] {
                let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: base) }
                var starts = 0, stops = 0
                let scope = LocalSecurityScope(start: { _ in starts += 1; return granted }, stop: { _ in stops += 1 })
                var sink: LocalDownload? = try LocalDownload(destination: base.appendingPathComponent("file"), scope: scope)
                let temporary = try XCTUnwrap(sink).temporary.deletingLastPathComponent()
                try sink?.receive(Data([42]))
                if explicit { try sink?.cleanUp(); try sink?.cleanUp(); XCTAssertEqual(stops, granted ? 1 : 0) }
                else { XCTAssertEqual(stops, 0) }
                sink = nil
                XCTAssertEqual(starts, 1); XCTAssertEqual(stops, granted ? 1 : 0)
                XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
            }
        }
    }

    func testInitializationFailureReleasesExactlyOnceAndPreservesTarget() throws {
        for kind in ["file", "directory", "link"] {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let target = base.appendingPathComponent("target"), protected = base.appendingPathComponent("protected")
            try Data("protected".utf8).write(to: protected)
            if kind == "file" { try Data("old".utf8).write(to: target) }
            else if kind == "directory" { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
            else { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: protected) }
            var starts = 0, stops = 0
            let scope = LocalSecurityScope(start: { _ in starts += 1; return true }, stop: { _ in stops += 1 })
            XCTAssertThrowsError(try LocalDownload(destination: target, scope: scope))
            XCTAssertEqual(starts, 1); XCTAssertEqual(stops, 1)
            XCTAssertEqual(try Data(contentsOf: protected), Data("protected".utf8))
            if kind == "file" { XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8)) }
        }
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
