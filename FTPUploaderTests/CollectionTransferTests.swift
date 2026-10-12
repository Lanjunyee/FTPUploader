import XCTest

@MainActor
final class PreviewListingCacheTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition())
    }
    func testThousandAndTenThousandLegalFlatNodesQueryOneParentAndReleaseCache() async throws {
        for count in [1_000, 10_000] {
            let fake = ControlledFTP(), token = FTPCancellationToken()
            let entries = (0..<count).map { index in
                let name = String(format: "cache-%05d", index)
                return RemoteEntry(name: name, rawName: Data(name.utf8), kind: .regularFile, size: 4096)
            }
            let roots = try entries.map { TransferPlan.Root(source: .remote(try RemotePath.root.appending(name: $0.name, bytes: $0.rawName), .utf8), kind: .regularFile) }
            let nodes = zip(roots, entries).map { root, entry in
                TransferPlan.Node(rootID: root.id, kind: .regularFile, source: root.source,
                    target: .local(URL(fileURLWithPath: "/tmp/cache-preview/" + entry.name)),
                    relativePath: [.init(name: entry.name, bytes: entry.rawName)], parentID: nil,
                    size: entry.size, snapshot: .remote(kind: .regularFile, size: entry.size))
            }
            let plan = TransferPlan(direction: .download, roots: roots, nodes: nodes)
            XCTAssertTrue(plan.canStart); XCTAssertEqual(plan.nodes.count, count)
            let lookups = entries.map { PreviewListingCache.Lookup(path: .root, encoding: .utf8, rawName: $0.rawName) }
            let cache = try PreviewListingCache(client: fake, endpoint: FTPEndpoint(address: "example.test"),
                credentials: .anonymous, cancellation: token, lookups: lookups)
            let reading = Task { () throws -> Int in
                var found = 0
                for lookup in lookups { if try await cache.match(lookup).entry != nil { found += 1 } }
                return found
            }
            try await wait { fake.browses.count == 1 }
            fake.browses[0].continuation.resume(returning: .init(entries: entries, encoding: .utf8))
            let found = try await reading.value
            XCTAssertEqual(found, count); XCTAssertEqual(fake.browses.count, 1)
            XCTAssertEqual(cache.cachedDirectoryCount, 1); XCTAssertEqual(cache.retainedEntryCount, count)
            cache.close(); XCTAssertEqual(cache.cachedDirectoryCount, 0); XCTAssertEqual(cache.retainedEntryCount, 0)
            XCTAssertFalse(token.isCancelled, "Successful close must not cancel the enclosing preview")
            let extra = RemoteEntry(name: "new-unselected", rawName: Data("new-unselected".utf8), kind: .regularFile, size: 1)
            let retry = Task { try await TransferRetryPlanner().download(plan, client: fake,
                endpoint: FTPEndpoint(address: "example.test"), credentials: .anonymous, cancellation: FTPCancellationToken()) }
            try await wait { fake.browses.count == 2 }
            fake.browses[1].continuation.resume(returning: .init(entries: entries + [extra], encoding: .utf8))
            let refreshed = try await retry.value
            XCTAssertTrue(refreshed.canStart); XCTAssertEqual(refreshed.nodes.map(\.id), plan.nodes.map(\.id))
            XCTAssertEqual(refreshed.roots, plan.roots); XCTAssertEqual(refreshed.nodes.count, count)
            XCTAssertEqual(fake.browses.count, 2, "A fresh retry queries once and cannot enumerate new items")
            let uploadRoots = plan.nodes.map { TransferPlan.Root(id: $0.rootID, source: $0.target, kind: .regularFile) }
            let validationCounts = TransferDiagnostics()
            let upload = TransferPlan(direction: .upload, roots: uploadRoots, nodes: plan.nodes.map {
                .init(id: $0.id, rootID: $0.rootID, kind: .regularFile, source: $0.target, target: $0.source,
                    relativePath: $0.relativePath, parentID: nil, size: $0.size,
                    snapshot: .localFile(.init(size: 4096, modified: nil, inode: 1, digest: Data())))
            }, diagnostics: validationCounts)
            XCTAssertEqual(validationCounts.snapshot["planRootKeys"], Int64(count))
            XCTAssertEqual(validationCounts.snapshot["planNodeMembershipChecks"], Int64(count))
            XCTAssertTrue(upload.canStart); fake.autoCheckTargets = false
            let preview = Task { try await TransferRetryPlanner().inspectTargets(upload, client: fake,
                endpoint: FTPEndpoint(address: "example.test"), credentials: .anonymous, destination: nil, cancellation: FTPCancellationToken()) }
            try await wait { fake.browses.count == 3 }
            fake.browses[2].continuation.resume(returning: .init(entries: entries + [extra], encoding: .utf8))
            let checked = try await preview.value
            XCTAssertTrue(checked.canStart); XCTAssertEqual(checked.existingTargetIDs.count, count)
            XCTAssertEqual(fake.browses.count, 3); XCTAssertEqual(fake.previewTargetListingCount, 1)
            XCTAssertTrue(fake.uploads.isEmpty); XCTAssertTrue(fake.downloads.isEmpty); XCTAssertTrue(fake.directories.isEmpty)
        }
    }
    func testEncodingPoliciesAndFreshIdentityScopesNeverReuseOldListing() async throws {
        let fake = ControlledFTP(), endpoint = try FTPEndpoint(address: "example.test")
        let entry = RemoteEntry(name: "file", rawName: Data("file".utf8), kind: .regularFile, size: 1)
        let lookups = [FTPTextEncoding.utf8, .gb18030].map { PreviewListingCache.Lookup(path: .root, encoding: $0, rawName: entry.rawName) }
        let cache = try PreviewListingCache(client: fake, endpoint: endpoint, credentials: .anonymous,
            cancellation: FTPCancellationToken(), lookups: lookups)
        for (index, lookup) in lookups.enumerated() {
            let reading = Task { try await cache.match(lookup) }
            try await wait { fake.browses.count == index + 1 }
            fake.browses[index].continuation.resume(returning: .init(entries: [entry], encoding: .utf8))
            let value = try await reading.value; XCTAssertEqual(value.entry, entry)
        }
        XCTAssertEqual(cache.cachedDirectoryCount, 2); cache.close()
        let fresh = try PreviewListingCache(client: fake, endpoint: FTPEndpoint(address: "other.test:2222", transport: .sftp),
            credentials: .account(username: "different", password: "memory-only"), cancellation: FTPCancellationToken(), lookups: [lookups[0]])
        let reading = Task { try await fresh.match(lookups[0]) }
        try await wait { fake.browses.count == 3 }
        XCTAssertEqual(fake.browses[2].endpoint.transport, .sftp); XCTAssertEqual(fake.browses[2].endpoint.port, 2222)
        fake.browses[2].continuation.resume(returning: .init(entries: [], encoding: .utf8))
        let value = try await reading.value; XCTAssertNil(value.entry); fresh.close()
    }
    func testDuplicateUnknownEncodingAndBackendFailuresStayClosedWithoutRepeatedQueries() async throws {
        for fault in ["duplicate", "unknown", "encoding", "backend"] {
            let fake = ControlledFTP(), lookup = PreviewListingCache.Lookup(path: .root, encoding: .utf8, rawName: Data("file".utf8))
            let cache = try PreviewListingCache(client: fake, endpoint: FTPEndpoint(address: "example.test"),
                credentials: .anonymous, cancellation: FTPCancellationToken(), lookups: [lookup])
            let reading = Task { try await cache.match(lookup) }
            try await wait { fake.browses.count == 1 }
            let entry = RemoteEntry(name: fault == "encoding" ? "wrong" : "file", rawName: lookup.rawName,
                kind: fault == "unknown" ? .unknown : .regularFile, size: 1)
            if fault == "backend" { fake.browses[0].continuation.resume(throwing: FTPError.localFile("unreadable")) }
            else { fake.browses[0].continuation.resume(returning: .init(entries: fault == "duplicate" ? [entry, entry] : [entry], encoding: .utf8)) }
            do { _ = try await reading.value; XCTFail("Must reject invalid listing") } catch {}
            do { _ = try await cache.match(lookup); XCTFail("Must retain the phase failure") } catch {}
            XCTAssertEqual(fake.browses.count, 1); XCTAssertEqual(cache.retainedEntryCount, 0); cache.close()
        }
    }
    func testRetryEncodingChangeMustStillDecodeTheOriginalName() async throws {
        let fake = ControlledFTP(), name = "中文", bytes = try FTPTextEncoding.utf8.encode(name)
        let path = try RemotePath.root.appending(name: name, bytes: bytes)
        let root = TransferPlan.Root(source: .remote(path, .utf8), kind: .regularFile)
        let plan = TransferPlan(direction: .download, roots: [root], nodes: [.init(rootID: root.id, kind: .regularFile,
            source: root.source, target: .local(URL(fileURLWithPath: "/tmp/encoding-preview/" + name)),
            relativePath: [.init(name: name, bytes: bytes)], parentID: nil, size: 1, snapshot: .remote(kind: .regularFile, size: 1))])
        XCTAssertTrue(plan.canStart)
        let retry = Task { try await TransferRetryPlanner().download(plan, client: fake,
            endpoint: FTPEndpoint(address: "example.test"), credentials: .anonymous, cancellation: FTPCancellationToken()) }
        try await wait { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: .init(entries: [.init(name: name, rawName: bytes, kind: .regularFile, size: 1)], encoding: .gb18030))
        do { _ = try await retry.value; XCTFail("Encoding changes cannot authorize a different name") } catch {}
        XCTAssertEqual(fake.browses.count, 1); XCTAssertTrue(fake.downloads.isEmpty)
    }
    func testCancellationDuringQueryDiscardsLateResultAndRejectsUndeclaredLookups() async throws {
        let fake = ControlledFTP(), token = FTPCancellationToken()
        let lookup = PreviewListingCache.Lookup(path: .root, encoding: .utf8, rawName: Data("file".utf8))
        let cache = try PreviewListingCache(client: fake, endpoint: FTPEndpoint(address: "example.test"),
            credentials: .anonymous, cancellation: token, lookups: [lookup])
        let outside = PreviewListingCache.Lookup(path: .root, encoding: .utf8, rawName: Data("outside".utf8))
        do { _ = try await cache.match(outside); XCTFail("Cannot expand fixed lookups") } catch {}
        XCTAssertTrue(fake.browses.isEmpty)
        let reading = Task { try await cache.match(lookup) }; try await wait { fake.browses.count == 1 }
        token.cancel(); cache.close()
        XCTAssertEqual(cache.cachedDirectoryCount, 0); XCTAssertEqual(cache.retainedEntryCount, 0)
        fake.browses[0].continuation.resume(returning: .init(entries: [.init(name: "file", rawName: lookup.rawName, kind: .regularFile, size: 1)], encoding: .utf8))
        do { _ = try await reading.value; XCTFail("Late result cannot restore cache") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(cache.cachedDirectoryCount, 0); XCTAssertEqual(cache.retainedEntryCount, 0)
        do { _ = try await cache.match(lookup); XCTFail("Closed phase cannot reopen") } catch {}
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

    func testScanDiscoveryCoalescesAndRetainedOldHandlerCannotPublishIntoNewGeneration() async throws {
        let fake = ControlledFTP(), destination = try destination(), session = TransferScanSession()
        let entry = RemoteEntry(name: "tree", rawName: Data("tree".utf8), kind: .directory, size: nil)
        let path = try RemotePath.root.appending(name: entry.name, bytes: entry.rawName)
        var handlers: [(Int) -> Void] = []
        let operation: (FTPCancellationToken) async throws -> TransferPlan = { token in
            let handler = session.discoveryHandler(cancellationID: token.id); handlers.append(handler)
            return try await RemoteTransferScanner(client: fake).scan(endpoint: FTPEndpoint(address: "example.test"),
                selections: [.init(entry: entry, path: path, encoding: .utf8)], destination: destination,
                credentials: .anonymous, cancellation: token, discovered: handler)
        }
        XCTAssertTrue(session.start(operation: operation)); try await wait { fake.browses.count == 1 }
        handlers[0](2); try await wait { session.discoveredNodes == 2 }
        var notifications = 0
        let observation = session.objectWillChange.sink { notifications += 1 }; defer { observation.cancel() }
        for value in 3...10_000 { handlers[0](value) }
        XCTAssertEqual(notifications, 0); XCTAssertEqual(session.discoveredNodes, 2)
        session.cancel(); XCTAssertEqual(session.phase, .cancelling); XCTAssertTrue(session.isLocked)
        handlers[0](100_000)
        fake.browses[0].continuation.resume(returning: .init(entries: [], encoding: .utf8))
        try await wait { session.phase == .finished }
        XCTAssertTrue(session.start(operation: operation)); try await wait { fake.browses.count == 2 && session.discoveredNodes == 1 }
        handlers[0](100_000); await Task.yield(); XCTAssertEqual(session.discoveredNodes, 1)
        fake.browses[1].continuation.resume(returning: .init(entries: [], encoding: .utf8))
        try await wait { session.phase == .preview }
        XCTAssertEqual(session.discoveredNodes, session.plan?.nodes.count)
        session.cancel(); XCTAssertEqual(session.phase, .finished)
        XCTAssertTrue(fake.uploads.isEmpty); XCTAssertTrue(fake.downloads.isEmpty)
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
    func testExecutionFetchesFreshAfterPreviewAndNeverInheritsTargetAuthorization() async throws {
        for change in ["upload-added", "upload-type", "upload-duplicate", "download-missing", "download-type", "download-duplicate"] {
            let fake = ControlledFTP(), counts = ScopeCounts(), base = try folder(), remote = entry("file")
            let upload = change.hasPrefix("upload")
            let model = try await connected(fake, counts: counts, entries: upload ? [] : [remote])
            if upload {
                let file = base.appendingPathComponent("file"); try Data("old".utf8).write(to: file)
                XCTAssertTrue(model.prepareUploadCollection([file]))
            } else { XCTAssertTrue(model.prepareDownloadCollection([remote], to: base)) }
            try await wait { model.collectionScan.phase == .preview }
            let plan = try XCTUnwrap(model.collectionScan.plan)
            XCTAssertTrue(plan.canStart); XCTAssertTrue(plan.existingTargetIDs.isEmpty)
            fake.autoCheckTargets = false
            XCTAssertTrue(model.confirmCollection(plan.id))
            try await wait { fake.browses.count == 2 }
            let current = change.hasSuffix("type") ? entry("file", directory: true) : remote
            let listing = change.hasSuffix("missing") ? [] : (change.hasSuffix("duplicate") ? [current, current] : [current])
            fake.browses[1].continuation.resume(returning: .init(entries: listing, encoding: .utf8))
            if change == "upload-added" {
                try await wait { model.batch.overwriteID != nil }
                XCTAssertEqual(model.batch.items.first?.state, .awaitingOverwrite)
                model.batch.confirmOverwrite(UUID()); XCTAssertNotNil(model.batch.overwriteID)
            } else {
                try await wait { model.batch.state == .paused }
                guard let state = model.batch.items.first?.state, case .failed = state else { return XCTFail("Fresh conflict must fail") }
            }
            XCTAssertTrue(fake.uploads.isEmpty); XCTAssertTrue(fake.downloads.isEmpty); XCTAssertTrue(fake.directories.isEmpty)
            XCTAssertEqual(fake.browses.count, 2, "Execution must fetch, even when preview already inspected")
            model.cancelAllTransfers(); try await wait { !model.isBusy }
            XCTAssertEqual(counts.counts, [1, 1])
            if upload { XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("file")), Data("old".utf8)) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("file").path)) }
        }
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
        var notifications = 0
        let observation = model.objectWillChange.sink { notifications += 1 }
        // Every ancestor remains observed, not just the latest published retryBatch.
        for queue in model.sessionQueues {
            let before = notifications
            queue.objectWillChange.send()
            XCTAssertEqual(notifications, before + 1)
        }
        withExtendedLifetime(observation) {}
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
        XCTAssertEqual(queue.summary?.actualBytes, 0)
        fake.uploads[0].progress(1, 9)
        XCTAssertEqual(queue.summary?.actualBytes, 1)
        fake.uploads[0].progress(2, 9)
        XCTAssertEqual(queue.summary?.actualBytes, 2, "Counter changes invalidate cached traffic even before display delivery")
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
        for item in queue.items {
            XCTAssertEqual(queue.item(id: item.id)?.id, item.id)
            XCTAssertEqual(queue.item(id: item.id)?.state, item.state, "Insertion must update later node positions")
        }
        XCTAssertEqual(queue.summary?.failed, 1); XCTAssertEqual(queue.summary?.succeeded, 2)
        XCTAssertFalse(queue.summary?.allSuccessful ?? true, "Retry result does not rewrite the old failed entry")
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
