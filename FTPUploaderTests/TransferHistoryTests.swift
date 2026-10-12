import XCTest

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
    func testVersionOnePreservesEveryFieldAndBacksUpBeforeFirstVersionTwoWrite() async throws {
        let url = try location(), old = try writeLegacy(url), original = try Data(contentsOf: url)
        let history = TransferHistory(url: url)
        try await history.drain()
        XCTAssertEqual(history.records, [old]); XCTAssertEqual(history.records[0].taskKind, .file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.backupURL.path))
        history.record(try task(.skipped("明确跳过")))
        try await history.drain()
        XCTAssertEqual(try Data(contentsOf: history.backupURL), original)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(json["version"] as? Int, 2)
        let loaded = try await reopen(url)
        XCTAssertNil(loaded.error); XCTAssertEqual(loaded.records, history.records)
        XCTAssertTrue(loaded.records.contains(old))
    }
    func testAllTerminalKindsRoundTripAreWriteOnceAndRetentionDoesNotChangeSessionResults() async throws {
        let url = try location(), history = TransferHistory(url: url), parent = UUID()
        let results: [TransferTaskResult] = [.succeeded, .failed("secret rejected"), .cancelled,
                                            .skipped("用户跳过"), .blocked(parentID: parent, reason: .failedAncestor)]
        for result in results {
            let next = try task(result, kind: .directory)
            history.record(next); history.record(next)
        }
        XCTAssertEqual(history.records.count, 5); XCTAssertTrue(history.records.allSatisfy { $0.bytes == 0 && $0.taskKind == .directory })
        try await history.drain()
        let initialReload = try await reopen(url)
        XCTAssertEqual(initialReload.records, history.records)
        let blocked = try XCTUnwrap(history.records.first { $0.result == "依赖阻塞" })
        XCTAssertEqual(blocked.blockedParentID, parent); XCTAssertEqual(blocked.blockedReason, .failedAncestor)
        var complete: [TransferRecord] = []
        for _ in 0..<105 { let next = try task(.succeeded); complete.append(next); history.record(next) }
        XCTAssertEqual(history.records.count, 100); XCTAssertEqual(complete.count, 105)
        XCTAssertEqual(Set(history.records.map(\.id)), Set(complete.suffix(100).map(\.id)))
        try await history.drain()
        let retainedReload = try await reopen(url)
        XCTAssertEqual(retainedReload.records, history.records)
    }
    func testBackupFailureOrDifferentExistingBackupNeverOverwritesOriginal() async throws {
        for different in [false, true] {
            let url = try location(); _ = try writeLegacy(url); let original = try Data(contentsOf: url)
            let history = TransferHistory(url: url, backupWriter: { _, _ in throw POSIXError(.EACCES) })
            if different { try Data("keep-backup".utf8).write(to: history.backupURL) }
            let request = try job(); request.finish(.succeeded)
            history.record(request, target: "target", bytes: 3)
            await expectDrainFailure(history)
            XCTAssertNotNil(history.error); XCTAssertEqual(request.outcome, .succeeded)
            XCTAssertEqual(try Data(contentsOf: url), original); XCTAssertEqual(history.records.count, 2, "Accepted terminal remains visible and pending alongside the old record")
            history.clear(); await expectDrainFailure(history)
            XCTAssertNotNil(history.error); XCTAssertEqual(try Data(contentsOf: url), original)
            if different { XCTAssertEqual(try Data(contentsOf: history.backupURL), Data("keep-backup".utf8)) }
        }
    }
    func testIncompleteBackupAndCorruptVersionTwoStayProtected() async throws {
        let url = try location(); _ = try writeLegacy(url); let original = try Data(contentsOf: url)
        let history = TransferHistory(url: url, backupWriter: { _, target in try Data("incomplete".utf8).write(to: target) })
        history.record(try task(.succeeded))
        await expectDrainFailure(history)
        XCTAssertNotNil(history.error); XCTAssertEqual(try Data(contentsOf: url), original)
        let damaged = Data("{\"version\":2,\"records\":[invalid]}".utf8); try damaged.write(to: url)
        let protected = TransferHistory(url: url)
        protected.record(try task(.succeeded)); await expectDrainFailure(protected)
        protected.clear()
        XCTAssertNotNil(protected.error); XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

    func testMigrationSaveAndClearFailuresKeepOriginalAndBackup() async throws {
        let url = try location(); _ = try writeLegacy(url); let original = try Data(contentsOf: url)
        let history = TransferHistory(url: url, writer: { _, _ in throw POSIXError(.ENOSPC) })
        let request = try job(); request.finish(.succeeded)
        history.record(request, target: "target", bytes: 3)
        await expectDrainFailure(history)
        XCTAssertNotNil(history.error); XCTAssertEqual(request.outcome, .succeeded)
        XCTAssertEqual(try Data(contentsOf: history.backupURL), original); XCTAssertEqual(try Data(contentsOf: url), original)
        history.clear(); await expectDrainFailure(history)
        XCTAssertNotNil(history.error); XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(history.records.count, 2)
    }
    func testRestartLoadsOnlyRecordsAndNeverRestoresOrStartsWork() async throws {
        let url = try location(), history = TransferHistory(url: url)
        history.record(try task(.failed("error"))); history.record(try task(.skipped("skip")))
        try await history.drain()
        let fake = ControlledFTP(), reopened = try await reopen(url)
        let model = AppModel(client: fake, history: reopened)
        XCTAssertEqual(model.history.records, history.records)
        XCTAssertFalse(model.batch.isLocked); XCTAssertTrue(model.batch.items.isEmpty)
        XCTAssertEqual(model.collectionScan.phase, .finished); XCTAssertNil(model.collectionScan.plan)
        XCTAssertFalse(model.hasCollectionCredentials); XCTAssertFalse(model.hasDirectory)
        XCTAssertTrue(fake.browses.isEmpty); XCTAssertTrue(fake.uploads.isEmpty)
        XCTAssertTrue(fake.downloads.isEmpty); XCTAssertTrue(fake.directories.isEmpty)
    }

    func testTypedTaskRecordNeverSerializesSecretsOrAuthorization() async throws {
        let url = try location(), history = TransferHistory(url: url)
        let bytes = Data("private-material-fixture".utf8)
        let credentials = try FTPCredentials.key(username: "member", material: PrivateKeyMaterial(bytes), passphrase: "phrase-fixture")
        let record = TransferRecord.task(id: UUID(), direction: .upload, kind: .directory, name: "tree", endpoint: try FTPEndpoint(address: "sftp://example.test"),
            target: "sftp://member:phrase-fixture@example.test/tree", credentials: credentials,
            result: .failed("private-material-fixture phrase-fixture"), started: Date(), bytes: 999, batchID: UUID())
        history.record(record)
        try await history.drain()
        let text = try String(contentsOf: url)
        for forbidden in ["private-material-fixture", "phrase-fixture", "member:", "bookmark", "password", "passphrase", "privateKey"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        XCTAssertEqual(history.records[0].bytes, 0); XCTAssertTrue(text.contains("redacted"))
    }

    func testPrivateKeyFailureHistoryNeverSerializesAuthenticationMaterial() async throws {
        let url = try location(); let history = TransferHistory(url: url)
        let bytes = Data("test-private-material".utf8)
        let credentials = try FTPCredentials.key(username: "member", material: PrivateKeyMaterial(bytes), passphrase: "test-key-phrase")
        let job = TransferJob(direction: .upload, endpoint: try FTPEndpoint(address: "sftp://example.test"),
                              path: .root, encoding: .utf8, credentials: credentials, localURL: URL(fileURLWithPath: "/tmp/test.bin"))
        job.finish(.failed("test-private-material test-key-phrase"))
        history.record(job, target: "sftp://example.test/test.bin", bytes: 0)
        try await history.drain()
        let text = try String(contentsOf: url)
        XCTAssertFalse(text.contains("test-private-material")); XCTAssertFalse(text.contains("test-key-phrase"))
        XCTAssertFalse(text.contains("bookmark")); XCTAssertTrue(text.contains("[redacted]"))
    }
    func testSlowWriterKeepsMainActorResponsiveAndDrainVerifiesRevision() async throws {
        let url = try location(), started = expectation(description: "background writer entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let history = TransferHistory(url: url, writer: { bytes, target in
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            try bytes.write(to: target, options: .atomic)
        })
        try await history.drain()
        let request = try job(); request.finish(.succeeded)
        history.record(request, target: "fixed", bytes: 2)
        await fulfillment(of: [started], timeout: 5)
        var sentinelRan = false
        let sentinel = Task { @MainActor in sentinelRan = true }
        await sentinel.value
        XCTAssertTrue(sentinelRan); XCTAssertTrue(history.isSaving)
        XCTAssertEqual(history.acceptedRevision, 1); XCTAssertEqual(history.durableRevision, 0)
        XCTAssertTrue(history.hasPendingSave); XCTAssertEqual(history.records.count, 1)
        var drained = false
        let draining = Task { try await history.drain(); drained = true }
        await Task.yield(); XCTAssertFalse(drained)
        release.signal(); try await draining.value
        XCTAssertEqual(history.durableRevision, history.acceptedRevision)
        XCTAssertFalse(history.hasPendingSave); XCTAssertFalse(history.isSaving)
        let loaded = try await reopen(url); XCTAssertEqual(loaded.records, history.records)
    }
    func testEarlyTerminalWaitsForBackgroundLoadAndBackupVerificationBeforeDurability() async throws {
        let url = try location(), old = try writeLegacy(url), original = try Data(contentsOf: url)
        let history = TransferHistory(url: url, writer: { bytes, target in
            XCTAssertFalse(Thread.isMainThread); try bytes.write(to: target, options: .atomic)
        }, backupWriter: { bytes, target in
            XCTAssertFalse(Thread.isMainThread); try bytes.write(to: target, options: .withoutOverwriting)
        })
        XCTAssertTrue(history.isLoading); XCTAssertFalse(history.isLoaded)
        let request = try job(); request.finish(.succeeded)
        history.record(request, target: "fixed", bytes: 2)
        XCTAssertEqual(history.records.count, 1); XCTAssertEqual(history.acceptedRevision, 1)
        XCTAssertEqual(history.durableRevision, 0)
        try await history.drain()
        XCTAssertTrue(history.records.contains(old)); XCTAssertEqual(history.records.count, 2)
        XCTAssertEqual(try Data(contentsOf: history.backupURL), original)
        XCTAssertEqual(history.acceptedRevision, history.durableRevision)
        let loaded = try await reopen(url); XCTAssertEqual(loaded.records, history.records)
    }
    func testExternallyChangedHistoryIsNotOverwrittenAndDrainReportsFailure() async throws {
        let url = try location(); _ = try writeLegacy(url)
        let history = try await reopen(url)
        let unknown = Data("external unknown history".utf8); try unknown.write(to: url)
        let request = try job(); request.finish(.succeeded)
        history.record(request, target: "fixed", bytes: 2)
        await expectDrainFailure(history)
        XCTAssertEqual(request.outcome, .succeeded); XCTAssertEqual(history.records.count, 2)
        XCTAssertTrue(history.hasPendingSave); XCTAssertEqual(history.durableRevision, 0)
        XCTAssertEqual(try Data(contentsOf: url), unknown)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.backupURL.path))
        history.retrySave(); await expectDrainFailure(history)
        XCTAssertEqual(try Data(contentsOf: url), unknown)
    }
    func testTenThousandTerminalsKeepOneInFlightOneLatestSnapshotAndCompleteSessionResults() async throws {
        let url = try location(), entered = expectation(description: "first snapshot blocked")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var writes = 0
        let history = TransferHistory(url: url, writer: { data, target in
            writes += 1
            if writes == 1 {
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 20), .success)
            }
            try data.write(to: target, options: .atomic)
        })
        try await history.drain()
        var owners: [TransferTaskState] = [], emitted: [TransferRecord] = []
        func append(_ index: Int) {
            let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!
            let owner = TransferTaskState(id: id, kind: .file)
            XCTAssertTrue(owner.finish(.succeeded)); owners.append(owner)
            let record = TransferRecord(id: id, direction: .upload, name: "file-\(index)", transport: .ftp,
                server: "example.test", target: "/file-\(index)", started: Date(timeIntervalSince1970: Double(index)),
                ended: Date(timeIntervalSince1970: Double(index + 1)), bytes: 7, result: "成功", error: nil,
                kind: .file, historyAdmission: owner.historyAdmission)
            emitted.append(record); history.record(record)
            XCTAssertEqual(history.inFlightSnapshotCount, 1)
            XCTAssertLessThanOrEqual(history.queuedSnapshotCount, 1)
            XCTAssertLessThanOrEqual(history.retainedIdentityCount, 100)
        }
        append(0); await fulfillment(of: [entered], timeout: 5)
        for index in 1..<10_000 { append(index) }
        XCTAssertEqual(history.acceptedRevision, 10_000); XCTAssertEqual(history.durableRevision, 0)
        XCTAssertEqual(history.records.count, 100); XCTAssertEqual(history.queuedSnapshotCount, 1)
        let revision = history.acceptedRevision
        history.record(emitted[0]); history.record(history.records[0])
        var changedCopy = emitted[0]; changedCopy.batchID = UUID(); history.record(changedCopy)
        history.record(.task(id: owners[0].id, direction: .upload, kind: .file, name: "late",
            endpoint: try FTPEndpoint(address: "example.test"), target: "late", credentials: .anonymous,
            result: .failed("late"), started: Date(), bytes: 0, batchID: nil, admission: owners[0].historyAdmission))
        XCTAssertEqual(history.acceptedRevision, revision)
        XCTAssertEqual(owners.count, 10_000); XCTAssertTrue(owners.allSatisfy { $0.result == .succeeded })
        XCTAssertFalse(owners[0].finish(.failed("late")))
        release.signal(); try await history.drain()
        XCTAssertEqual(writes, 2, "Only first and latest snapshots should be written")
        XCTAssertEqual(history.durableRevision, 10_000)
        let loaded = try await reopen(url)
        XCTAssertEqual(Set(loaded.records.map(\.id)), Set(emitted.suffix(100).map(\.id)))
        XCTAssertEqual(owners.count, 10_000); XCTAssertTrue(owners.allSatisfy { $0.result == .succeeded })
        XCTAssertFalse(try String(contentsOf: url).contains("historyAdmission"))
    }
    func testFailedSaveRetainsLatestPendingSnapshotAndExplicitRetryNeverUsesNetwork() async throws {
        let url = try location(), old = try writeLegacy(url), original = try Data(contentsOf: url)
        var denied = true, writes = 0
        let history = TransferHistory(url: url, writer: { data, target in
            writes += 1
            if denied { throw POSIXError(.ENOSPC) }
            try data.write(to: target, options: .atomic)
        })
        try await history.drain()
        let fake = ControlledFTP(), model = AppModel(client: fake, history: history)
        let first = try job(); first.finish(.succeeded)
        history.record(first, target: "first", bytes: 7); await expectDrainFailure(history)
        XCTAssertEqual(try Data(contentsOf: url), original); XCTAssertEqual(history.durableRevision, 0)
        let second = try job(); second.finish(.cancelled)
        history.record(second, target: "second", bytes: 3); await Task.yield()
        XCTAssertEqual(writes, 1, "New results must not silently retry the failed writer")
        XCTAssertEqual(history.queuedSnapshotCount, 1); XCTAssertTrue(history.canRetrySave)
        denied = false; history.retrySave(); try await history.drain()
        XCTAssertEqual(writes, 2); XCTAssertEqual(history.acceptedRevision, history.durableRevision)
        XCTAssertEqual(Set(history.records.map(\.id)), Set([old.id, first.id, second.id]))
        XCTAssertEqual(first.outcome, .succeeded); XCTAssertEqual(second.outcome, .cancelled)
        XCTAssertTrue(fake.browses.isEmpty); XCTAssertTrue(fake.uploads.isEmpty)
        XCTAssertTrue(fake.downloads.isEmpty); XCTAssertTrue(fake.directories.isEmpty)
        XCTAssertFalse(model.hasDirectory)
        let loaded = try await reopen(url); XCTAssertEqual(loaded.records, history.records)
    }
    func testJobAndRecordAdmissionsRejectLateReplayAfterEvictionAndClear() async throws {
        let url = try location(), history = TransferHistory(url: url), request = try job()
        request.finish(.succeeded); history.record(request, target: "original", bytes: 1)
        let first = try task(.succeeded); history.record(first)
        for _ in 0..<100 { history.record(try task(.succeeded)) }
        let displayed = history.records[0], revision = history.acceptedRevision
        history.record(request, target: "late", bytes: 999); history.record(first)
        XCTAssertEqual(history.acceptedRevision, revision); XCTAssertFalse(history.records.contains { $0.id == request.id })
        try await history.drain(); history.clear(); try await history.drain()
        let clearRevision = history.acceptedRevision
        history.record(request, target: "late", bytes: 999); history.record(first); history.record(displayed)
        XCTAssertEqual(history.acceptedRevision, clearRevision); XCTAssertTrue(history.records.isEmpty)
        let loaded = try await reopen(url); XCTAssertTrue(loaded.records.isEmpty)
    }
    func testClearBarrierOrdersLateOldWriteBeforeClearAndPreservesPostClearTerminal() async throws {
        for oldWriteFails in [false, true] {
            let url = try location(), old = try writeLegacy(url), original = try Data(contentsOf: url)
            let entered = expectation(description: "old write blocked"), release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            var writes: [[UUID]] = []
            let history = TransferHistory(url: url, writer: { data, target in
                let archive = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let rows = try XCTUnwrap(archive["records"] as? [[String: Any]])
                writes.append(rows.map { UUID(uuidString: $0["id"] as! String)! })
                if writes.count == 1 {
                    entered.fulfill(); XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
                    if oldWriteFails { throw POSIXError(.ENOSPC) }
                }
                try data.write(to: target, options: .atomic)
            })
            try await history.drain()
            let oldDisplayCopy = try XCTUnwrap(history.records.first)
            let prior = try job(); prior.finish(.succeeded); history.record(prior, target: "before-clear", bytes: 1)
            await fulfillment(of: [entered], timeout: 5)
            history.clear(); let clearRevision = history.acceptedRevision
            XCTAssertTrue(history.isClearing); XCTAssertTrue(history.hasPendingClear)
            XCTAssertNil(history.clearCompletedRevision)
            let after = try job(); after.finish(.succeeded); history.record(after, target: "after-clear", bytes: 2)
            XCTAssertTrue(history.records.contains { $0.id == old.id })
            release.signal()
            if oldWriteFails {
                await expectDrainFailure(history)
                XCTAssertEqual(try Data(contentsOf: url), original)
                XCTAssertFalse(history.isClearing); XCTAssertTrue(history.hasPendingClear)
                XCTAssertNil(history.clearCompletedRevision); XCTAssertTrue(history.canRetrySave)
                history.retrySave()
            }
            try await history.drain()
            XCTAssertEqual(writes.count, 3); XCTAssertTrue(writes[0].contains(prior.id))
            XCTAssertTrue(writes[1].isEmpty); XCTAssertEqual(writes[2], [after.id])
            XCTAssertEqual(history.clearCompletedRevision, clearRevision)
            XCTAssertFalse(history.hasPendingClear); XCTAssertFalse(history.isClearing)
            XCTAssertEqual(history.records.map(\.id), [after.id])
            history.record(prior, target: "late-old", bytes: 99); history.record(oldDisplayCopy)
            let loaded = try await reopen(url); XCTAssertEqual(loaded.records.map(\.id), [after.id])
            XCTAssertEqual(prior.outcome, .succeeded); XCTAssertEqual(after.outcome, .succeeded)
        }
    }
    func testClearFailureKeepsDurableAndVisibleRecordsThenRetrySavesOnlyPostClearResults() async throws {
        let url = try location(), historyFolder = url.deletingLastPathComponent()
        let unrelated = historyFolder.appendingPathComponent("unrelated-file")
        let sentinel = Data("source-file-unchanged".utf8); try sentinel.write(to: unrelated)
        var failClear = true
        let history = TransferHistory(url: url, writer: { data, target in
            let archive = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let rows = try XCTUnwrap(archive["records"] as? [[String: Any]])
            if rows.isEmpty && failClear { throw POSIXError(.EACCES) }
            try data.write(to: target, options: .atomic)
        })
        let prior = try job(); prior.finish(.succeeded); history.record(prior, target: "prior", bytes: 1)
        try await history.drain()
        let durable = try Data(contentsOf: url), displayed = history.records
        history.clear(); let requested = history.acceptedRevision
        await expectDrainFailure(history)
        XCTAssertEqual(try Data(contentsOf: url), durable); XCTAssertEqual(history.records, displayed)
        XCTAssertNil(history.clearCompletedRevision); XCTAssertTrue(history.hasPendingClear)
        XCTAssertFalse(history.isClearing); XCTAssertTrue(history.canRetrySave)
        let after = try job(); after.finish(.failed("after-clear")); history.record(after, target: "after", bytes: 2)
        XCTAssertEqual(try Data(contentsOf: url), durable)
        failClear = false; history.retrySave(); try await history.drain()
        XCTAssertEqual(history.clearCompletedRevision, requested)
        XCTAssertEqual(history.records.map(\.id), [after.id])
        let loaded = try await reopen(url); XCTAssertEqual(loaded.records, history.records)
        XCTAssertEqual(try Data(contentsOf: unrelated), sentinel)
        XCTAssertEqual(prior.outcome, .succeeded); XCTAssertEqual(after.outcome, .failed("after-clear"))
    }
    func testNormalExitWaitsForEarlyAndLateAcceptedRecordsWithoutDuplicatingQuitRequest() async throws {
        let url = try location(), old = try writeLegacy(url), entered = expectation(description: "exit writer blocked")
        let replied = expectation(description: "termination reply"), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var writes = 0, answer: Bool?, duplicateReply = false
        let history = TransferHistory(url: url, writer: { data, target in
            writes += 1
            if writes == 1 { entered.fulfill(); XCTAssertEqual(release.wait(timeout: .now() + 10), .success) }
            try data.write(to: target, options: .atomic)
        })
        let early = try job(); early.finish(.succeeded); history.record(early, target: "early", bytes: 7)
        XCTAssertTrue(history.isLoading); XCTAssertFalse(history.canClear)
        let exit = HistoryTerminationCoordinator()
        exit.requestExit(history: history, onFailure: { _ in XCTFail("Unexpected exit failure"); return false },
            reply: { answer = $0; replied.fulfill() })
        exit.requestExit(history: history, onFailure: { _ in XCTFail(); return false }, reply: { _ in duplicateReply = true })
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertNil(answer); XCTAssertTrue(exit.isDraining); XCTAssertTrue(history.persistenceStatus.contains("待保存"))
        let late = try job(); late.finish(.cancelled); history.record(late, target: "late", bytes: 3)
        release.signal(); await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(answer, true); XCTAssertFalse(duplicateReply); XCTAssertFalse(exit.isDraining)
        XCTAssertEqual(history.acceptedRevision, history.durableRevision)
        XCTAssertEqual(Set(history.records.map(\.id)), Set([old.id, early.id, late.id]))
        XCTAssertEqual(early.outcome, .succeeded); XCTAssertEqual(late.outcome, .cancelled)
        let loaded = try await reopen(url); XCTAssertEqual(loaded.records, history.records)
    }
    func testNormalExitReportsLoadOrWriteFailureAndOnlyDiscardsPendingStateWithExplicitConsent() async throws {
        for corruptLoad in [false, true] {
            let url = try location()
            if corruptLoad { try Data("damaged history".utf8).write(to: url) } else { _ = try writeLegacy(url) }
            let original = try Data(contentsOf: url)
            var attempts = 0, failures = 0, answer: Bool?
            let history = TransferHistory(url: url, writer: { _, _ in attempts += 1; throw POSIXError(.ENOSPC) })
            let request = try job(); request.finish(.succeeded); history.record(request, target: "pending", bytes: 7)
            let exit = HistoryTerminationCoordinator(), replied = expectation(description: "cancel quit on failure")
            exit.requestExit(history: history, onFailure: { _ in failures += 1; return false },
                reply: { answer = $0; replied.fulfill() })
            await fulfillment(of: [replied], timeout: 5)
            XCTAssertEqual(answer, false); XCTAssertEqual(failures, 1); XCTAssertFalse(exit.isDraining)
            XCTAssertEqual(attempts, corruptLoad ? 0 : 1)
            XCTAssertTrue(history.hasPendingSave); XCTAssertEqual(history.durableRevision, 0)
            XCTAssertTrue(history.persistenceStatus.contains(corruptLoad ? "加载失败" : "待保存"))
            XCTAssertEqual(request.outcome, .succeeded); XCTAssertEqual(try Data(contentsOf: url), original)
            let consent = expectation(description: "explicit quit despite failure")
            exit.requestExit(history: history, onFailure: { _ in failures += 1; return true },
                reply: { answer = $0; consent.fulfill() })
            await fulfillment(of: [consent], timeout: 5)
            XCTAssertEqual(answer, true); XCTAssertEqual(failures, 2)
            XCTAssertEqual(attempts, corruptLoad ? 0 : 1, "Quit must not silently retry a failed save")
            XCTAssertEqual(try Data(contentsOf: url), original); XCTAssertEqual(request.outcome, .succeeded)
        }
    }
    private func reopen(_ url: URL) async throws -> TransferHistory {
        let history = TransferHistory(url: url)
        try await history.drain()
        return history
    }
    private func expectDrainFailure(_ history: TransferHistory, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await history.drain(); XCTFail("Persistence failure was hidden", file: file, line: line) } catch {}
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
    func testTerminalOnceRetentionRestartNoCredentialsAndClear() async throws {
        let url = try location(); let store = TransferHistory(url: url)
        let first = try job(); first.finish(.failed("ftp://member:secret@example.test rejected secret"))
        store.record(first, target: "ftp://member:secret@example.test/file.bin", bytes: 4)
        store.record(first, target: "same", bytes: 4); XCTAssertEqual(store.records.count, 1)
        try await store.drain()
        let text = try String(contentsOf: url)
        XCTAssertFalse(text.contains("secret")); XCTAssertFalse(text.contains("member:")); XCTAssertFalse(text.contains("password"))
        for _ in 0..<100 { let next = try job(); next.finish(.succeeded); store.record(next, target: "fixed", bytes: 8) }
        XCTAssertEqual(store.records.count, 100); XCTAssertFalse(store.records.contains { $0.id == first.id })
        try await store.drain()
        let reopened = try await reopen(url); XCTAssertEqual(reopened.records, store.records)
        XCTAssertNil(reopened.error)
        reopened.clear(); try await reopened.drain(); XCTAssertTrue(reopened.records.isEmpty)
        let afterClear = try await reopen(url); XCTAssertTrue(afterClear.records.isEmpty)
    }
    func testWriteFailureNeverChangesJobOutcomeAndCorruptionIsPreserved() async throws {
        let url = try location(); let store = TransferHistory(url: url, writer: { _, _ in throw POSIXError(.ENOSPC) })
        let request = try job(); request.finish(.succeeded); store.record(request, target: "fixed", bytes: 2)
        await expectDrainFailure(store)
        XCTAssertEqual(request.outcome, .succeeded); XCTAssertNotNil(store.error)
        XCTAssertEqual(store.records.count, 1); XCTAssertTrue(store.hasPendingSave)
        XCTAssertEqual(store.durableRevision, 0)
        let damaged = Data("damaged history".utf8); try damaged.write(to: url)
        let broken = TransferHistory(url: url); await expectDrainFailure(broken); XCTAssertNotNil(broken.error)
        broken.record(request, target: "fixed", bytes: 2); broken.clear()
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

}
