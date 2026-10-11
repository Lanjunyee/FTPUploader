import CryptoKit
import XCTest

/// Exercises production scanning, preparation, policy and serial execution against
/// disposable wire servers. No GUI credentials, persistent queues or real servers.
@MainActor
final class CollectionProtocolMatrixTests: XCTestCase {
    private struct Mode {
        let transport: FileTransport
        let encoding: FTPTextEncoding
        var key = false
        var label: String { transport.rawValue + (transport == .sftp ? (key ? "-key" : "-password") : "-anonymous") + (encoding == .gb18030 ? "-gb18030" : "-utf8") }
    }
    @MainActor
    private final class Wire {
        let mode: Mode
        let ftp: FTPFixture?
        let ssh: SFTPFixture?
        let client: FTPClient
        let credentials: FTPCredentials
        var root: URL { ftp?.root ?? ssh!.root }
        var endpoint: FTPEndpoint { ftp?.endpoint ?? ssh!.endpoint }
        init(_ mode: Mode) throws {
            self.mode = mode
            ftp = mode.transport == .sftp ? nil : try FTPFixture(scenario: mode.encoding == .gb18030 ? "legacy" : "normal", delay: 3, transport: mode.transport)
            ssh = mode.transport == .sftp ? try SFTPFixture(delay: 3, keyAuth: mode.key) : nil
            let root = ftp?.root ?? ssh!.root
            let trust = HostTrustStore(url: root.appendingPathComponent(".matrix-trust.json"))
            if let ssh { try trust.trust(ssh.identity) }
            let ca = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/tls-fixtures/ca.pem")
            client = FTPClient(responseTimeout: 8, stallTimeout: 10, caFile: ca.path, trust: trust)
            if mode.key {
                credentials = try .key(username: "member", material: PrivateKeyAccess().read(root.appendingPathComponent(".keys/openssh-ed25519-encrypted")), passphrase: " 密钥口令:@ ")
            } else {
                credentials = mode.transport == .sftp ? try .account(username: "member", password: "fixture-pass:@ ") : .anonymous
            }
        }
        func commands() throws -> [[String: String]] { try ftp?.commands() ?? ssh!.commands() }
        func stop() { ftp?.stop(); ssh?.stop() }
    }
    private var modes: [Mode] {
        [FileTransport.ftp, .ftpsExplicit, .ftpsImplicit].flatMap { transport in
            [Mode(transport: transport, encoding: .utf8), Mode(transport: transport, encoding: .gb18030)]
        } + [Mode(transport: .sftp, encoding: .utf8), Mode(transport: .sftp, encoding: .utf8, key: true)]
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("collection-matrix-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func wait(_ condition: () throws -> Bool, seconds: Double = 30) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while try !condition() {
            guard ProcessInfo.processInfo.systemUptime < end else {
                XCTFail("Collection matrix timed out"); throw POSIXError(.ETIMEDOUT)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    private func path(_ names: [String], _ wire: Wire) throws -> RemotePath {
        try names.reduce(.root) { try $0.appending(name: $1, bytes: wire.mode.encoding.encode($1)) }
    }
    private func upload(_ urls: [URL], to remote: RemotePath = .root, wire: Wire) async throws -> (TransferPlan, BatchTransferQueue) {
        let roots = try urls.map { try LocalSourceRoot(url: $0) }
        let scanned = try await LocalTransferScanner().scan(roots: roots, destination: remote, encoding: wire.mode.encoding, cancellation: FTPCancellationToken())
        let plan = try await TransferRetryPlanner().inspectTargets(scanned, client: wire.client, endpoint: wire.endpoint, credentials: wire.credentials, destination: nil, cancellation: FTPCancellationToken())
        let queue = BatchTransferQueue(client: wire.client, executor: TransferExecutor())
        do {
            try queue.prepare(plan: plan, endpoint: wire.endpoint, remoteRoot: remote, encoding: wire.mode.encoding,
                              credentials: wire.credentials, sources: Dictionary(uniqueKeysWithValues: zip(plan.roots.map(\.id), roots)))
        } catch { roots.forEach { $0.endAccess() }; throw error }
        return (plan, queue)
    }
    private func download(_ names: [String], to destination: URL, wire: Wire) async throws -> (TransferPlan, BatchTransferQueue) {
        let listing = try await wire.client.list(endpoint: wire.endpoint, path: .root, encoding: wire.mode.encoding, credentials: wire.credentials, cancellation: FTPCancellationToken())
        let selections = try names.map { name -> RemoteTransferScanner.Selection in
            let entry = try XCTUnwrap(listing.entries.first { $0.name == name })
            return .init(entry: entry, path: try path([name], wire), encoding: listing.encoding)
        }
        let root = try LocalDestinationRoot(url: destination)
        let scanned = try await RemoteTransferScanner(client: wire.client).scan(endpoint: wire.endpoint, selections: selections, destination: root, credentials: wire.credentials, cancellation: FTPCancellationToken())
        let plan = try await TransferRetryPlanner().inspectTargets(scanned, client: wire.client, endpoint: wire.endpoint, credentials: wire.credentials, destination: root, cancellation: FTPCancellationToken())
        let queue = BatchTransferQueue(client: wire.client, executor: TransferExecutor())
        do { try queue.prepare(plan: plan, endpoint: wire.endpoint, remoteRoot: .root, encoding: wire.mode.encoding, credentials: wire.credentials, destination: root) }
        catch { root.endAccess(); throw error }
        return (plan, queue)
    }
    private func run(_ plan: TransferPlan, _ queue: BatchTransferQueue, policy: TransferConflictPolicy = .ask) async throws {
        XCTAssertTrue(plan.canStart); XCTAssertTrue(queue.chooseConflictPolicy(policy, planID: plan.id))
        queue.startOrContinue()
        try await wait { queue.state == .finished || queue.state == .paused || queue.overwriteID != nil }
    }
    private func contentCount(_ wire: Wire) throws -> Int {
        try wire.commands().filter { ["STOR", "RETR", "OPEN"].contains($0["command"] ?? "") }.count
    }
    private func verifyPlanFiles(_ plan: TransferPlan, base: URL) throws {
        for node in plan.nodes {
            let target = node.relativePath.reduce(base) { $0.appendingPathComponent($1.name) }
            if node.kind == .directory {
                var isDirectory: ObjCBool = false
                XCTAssertTrue(FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)); XCTAssertTrue(isDirectory.boolValue)
            } else {
                let source: URL
                switch node.source {
                case .local(let url): source = url
                case .remote(let path, _): source = path.components.reduce(base) { $0.appendingPathComponent($1.name) }
                }
                if plan.direction == .upload { XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: target)) }
            }
        }
    }
    private func evidence(_ wire: Wire, stage: String, plan: TransferPlan, queue: BatchTransferQueue, base: URL, start: Int) throws {
        let summary = try XCTUnwrap(queue.summary)
        let nodes: [[String: Any]] = try zip(plan.nodes, queue.items).map { node, item in
            let relative = node.relativePath.map(\.name).joined(separator: "/")
            let target = base.appendingPathComponent(relative)
            var entry: [String: Any] = ["path": relative, "raw_segments": node.relativePath.map { $0.bytes.map { String(format: "%02x", $0) }.joined() }, "kind": item.kindTitle, "direction": item.directionTitle, "result": item.statusTitle, "exists": FileManager.default.fileExists(atPath: target.path)]
            if node.kind == .regularFile, FileManager.default.fileExists(atPath: target.path) {
                let bytes = try Data(contentsOf: target)
                entry["bytes"] = bytes.count; entry["sha256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            }
            return entry
        }
        let commands = Array(try wire.commands().dropFirst(start))
        XCTAssertFalse(commands.contains { ["DELE", "RNFR", "RNTO", "SITE", "APPE", "REST", "REMOVE", "RMDIR", "RENAME", "SETSTAT", "FSETSTAT"].contains($0["command"] ?? "") })
        if wire.mode.transport.requiresTLS {
            XCTAssertTrue(commands.filter { ["USER", "PASS", "MKD", "STOR", "RETR", "MLSD"].contains($0["command"] ?? "") }.allSatisfy { $0["control_tls"] == "yes" })
            XCTAssertTrue(commands.filter { $0["command"] == "DATA" }.allSatisfy { $0["data_tls"] == "yes" })
        }
        if wire.mode.key { XCTAssertFalse(commands.contains { $0["command"] == "AUTH" }) }
        let result: [String: Any] = ["mode": wire.mode.label, "stage": stage, "plan_node_count": plan.nodes.count, "files": summary.fileCount, "directories": summary.directoryCount, "succeeded": summary.succeeded, "failed": summary.failed, "cancelled": summary.cancelled, "skipped": summary.skipped, "blocked": summary.blocked, "all_successful": summary.allSuccessful, "successful_bytes": summary.successfulBytes as Any? ?? NSNull(), "actual_bytes": summary.actualBytes as Any? ?? NSNull(), "nodes": nodes, "commands": commands]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "collection-matrix-" + wire.mode.label + "-" + stage; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testFullDirectoryRoundTripMergePoliciesPartialFailureAndCancellationMatrix() async throws {
        for mode in modes {
            let wire = try Wire(mode); defer { wire.stop() }
            try await roundTrip(wire)
            try await partialUpload(wire)
            try await partialDownload(wire)
            try await cancellation(wire)
            try await uploadCancellation(wire)
            try await typeConflict(wire)
        }
    }
    private func roundTrip(_ wire: Wire) async throws {
        let base = try folder(), tree = base.appendingPathComponent("项目 中文 %#"), single = base.appendingPathComponent("单独 文件%#.txt")
        for relative in ["嵌套 层", "空目录", "资料.app/空目录"] {
            try FileManager.default.createDirectory(at: tree.appendingPathComponent(relative), withIntermediateDirectories: true)
        }
        let binary = Data((0..<65536).map { UInt8($0 % 256) })
        try binary.write(to: tree.appendingPathComponent("嵌套 层/中文 文件%#.bin"))
        try Data().write(to: tree.appendingPathComponent("零字节.dat"))
        try Data([0, 255, 10]).write(to: tree.appendingPathComponent(".hidden"))
        try Data("single\n".utf8).write(to: single)
        let remoteTree = wire.root.appendingPathComponent(tree.lastPathComponent)
        try FileManager.default.createDirectory(at: remoteTree.appendingPathComponent("嵌套 层"), withIntermediateDirectories: true)
        let extra = Data("keep remote extra\n".utf8)
        try extra.write(to: remoteTree.appendingPathComponent("keep-extra.txt"))
        var start = try wire.commands().count
        let (up, queue) = try await upload([tree, single], wire: wire)
        XCTAssertEqual(up.nodes.count, 9); XCTAssertEqual(try contentCount(wire), 0)
        try await run(up, queue); XCTAssertEqual(queue.state, .finished); XCTAssertTrue(queue.summary?.allSuccessful == true); XCTAssertFalse(queue.hasCredentials)
        try verifyPlanFiles(up, base: wire.root)
        XCTAssertEqual(try Data(contentsOf: remoteTree.appendingPathComponent("keep-extra.txt")), extra)
        XCTAssertEqual(queue.items.filter(\.reusedDirectory).count, 2)
        try evidence(wire, stage: "upload-merge", plan: up, queue: queue, base: wire.root, start: start)
        let beforeSkip = try contentCount(wire); start = try wire.commands().count
        let (skipUp, skippedUp) = try await upload([tree, single], wire: wire)
        try await run(skipUp, skippedUp, policy: .skipExistingFiles)
        XCTAssertEqual(skippedUp.summary?.skipped, 4); XCTAssertEqual(skippedUp.summary?.succeeded, 5)
        XCTAssertFalse(skippedUp.summary?.allSuccessful ?? true); XCTAssertEqual(try contentCount(wire), beforeSkip)
        try verifyPlanFiles(skipUp, base: wire.root)
        try evidence(wire, stage: "upload-skip-existing", plan: skipUp, queue: skippedUp, base: wire.root, start: start)

        let destination = try folder(), localTree = destination.appendingPathComponent(tree.lastPathComponent)
        try FileManager.default.createDirectory(at: localTree.appendingPathComponent("嵌套 层"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: localTree.appendingPathComponent("嵌套 层/中文 文件%#.bin"))
        let localExtra = Data("keep local extra\n".utf8)
        try localExtra.write(to: localTree.appendingPathComponent("local-extra.txt"))
        start = try wire.commands().count
        let (down, downloaded) = try await download([tree.lastPathComponent, single.lastPathComponent], to: destination, wire: wire)
        XCTAssertEqual(down.nodes.count, 10)
        try await run(down, downloaded, policy: .overwriteExistingFiles)
        XCTAssertEqual(downloaded.state, .finished); XCTAssertTrue(downloaded.summary?.allSuccessful == true); XCTAssertFalse(downloaded.hasCredentials)
        for node in down.nodes {
            let relative = node.relativePath.map(\.name).joined(separator: "/")
            if node.kind == .regularFile { XCTAssertEqual(try Data(contentsOf: wire.root.appendingPathComponent(relative)), try Data(contentsOf: destination.appendingPathComponent(relative))) }
            else { XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(relative).path)) }
        }
        XCTAssertEqual(try Data(contentsOf: localTree.appendingPathComponent("local-extra.txt")), localExtra)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: localTree.appendingPathComponent("空目录").path).isEmpty)
        try evidence(wire, stage: "download-merge-overwrite", plan: down, queue: downloaded, base: destination, start: start)
        let beforeDownloadSkip = try contentCount(wire); start = try wire.commands().count
        let (skipDown, skippedDown) = try await download([tree.lastPathComponent, single.lastPathComponent], to: destination, wire: wire)
        try await run(skipDown, skippedDown, policy: .skipExistingFiles)
        XCTAssertEqual(skippedDown.summary?.skipped, 5); XCTAssertEqual(skippedDown.summary?.succeeded, 5)
        XCTAssertEqual(try contentCount(wire), beforeDownloadSkip); XCTAssertFalse(skippedDown.summary?.allSuccessful ?? true)
        try evidence(wire, stage: "download-skip-existing", plan: skipDown, queue: skippedDown, base: destination, start: start)

        start = try wire.commands().count
        let (preview, cancelledPreview) = try await upload([tree, single], wire: wire)
        var previewHistory = 0
        cancelledPreview.onHistoryRecord = { _ in previewHistory += 1 }
        cancelledPreview.cancelAll(); cancelledPreview.startOrContinue()
        XCTAssertEqual(previewHistory, 0)
        XCTAssertEqual(cancelledPreview.state, .finished); XCTAssertTrue(cancelledPreview.taskResults.isEmpty); XCTAssertNil(cancelledPreview.summary)
        XCTAssertFalse(cancelledPreview.hasCredentials); XCTAssertEqual(try contentCount(wire), beforeDownloadSkip)
        XCTAssertFalse(try wire.commands().dropFirst(start).contains { ["MKD", "MKDIR", "STOR", "RETR", "OPEN"].contains($0["command"] ?? "") })
        XCTAssertTrue(preview.canStart)
    }
    private func partialUpload(_ wire: Wire) async throws {
        let base = try folder(), first = base.appendingPathComponent("a-success.bin"), denied = base.appendingPathComponent("拒绝写入"), tail = base.appendingPathComponent("z-waiting.bin")
        try FileManager.default.createDirectory(at: denied.appendingPathComponent("blocked-child"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: first); try Data([4]).write(to: denied.appendingPathComponent("blocked-child/child.bin")); try Data([5]).write(to: tail)
        let start = try wire.commands().count
        let (plan, queue) = try await upload([first, denied, tail], wire: wire)
        try await run(plan, queue); XCTAssertEqual(queue.state, .paused)
        XCTAssertEqual(queue.summary?.failed, 1); XCTAssertTrue(queue.hasCredentials)
        queue.skip(); XCTAssertEqual(queue.summary?.blocked, 1)
        queue.cancelAll(); try await wait { !queue.isLocked }
        XCTAssertEqual(queue.summary?.succeeded, 2); XCTAssertEqual(queue.summary?.failed, 1)
        XCTAssertEqual(queue.summary?.blocked, 1); XCTAssertEqual(queue.summary?.cancelled, 1)
        XCTAssertEqual(queue.summary?.successfulBytes, 3); XCTAssertFalse(queue.summary?.allSuccessful ?? true)
        XCTAssertEqual(try Data(contentsOf: wire.root.appendingPathComponent(first.lastPathComponent)), Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wire.root.appendingPathComponent("拒绝写入/blocked-child/child.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wire.root.appendingPathComponent(tail.lastPathComponent).path))
        let deniedCreates = try wire.commands().dropFirst(start).filter { ($0["command"] == "MKD" && $0["argument"] == "blocked-child") || ($0["command"] == "MKDIR" && $0["path"] == "/拒绝写入/blocked-child") }
        XCTAssertEqual(deniedCreates.count, 1, "Denied directory must not be retried automatically")
        try evidence(wire, stage: "upload-denial-blocked-cancel", plan: plan, queue: queue, base: wire.root, start: start)
    }
    private func partialDownload(_ wire: Wire) async throws {
        let name = "部分 下载%#", remote = wire.root.appendingPathComponent(name), destination = try folder()
        try FileManager.default.createDirectory(at: remote.appendingPathComponent("空目录"), withIntermediateDirectories: true)
        for file in ["a-ok.bin", "denied.bin", "z-tail.bin"] { try Data([1, 2, 3]).write(to: remote.appendingPathComponent(file)) }
        let start = try wire.commands().count
        let (plan, queue) = try await download([name], to: destination, wire: wire)
        try await run(plan, queue); XCTAssertEqual(queue.state, .paused); XCTAssertEqual(queue.summary?.failed, 1)
        let failed = queue.taskResults
        queue.cancelAll(); try await wait { !queue.isLocked }
        XCTAssertEqual(queue.summary?.succeeded, 2); XCTAssertEqual(queue.summary?.failed, 1); XCTAssertEqual(queue.summary?.cancelled, 2)
        XCTAssertEqual(queue.summary?.successfulBytes, 3); XCTAssertFalse(queue.summary?.allSuccessful ?? true)
        for (id, result) in failed { XCTAssertEqual(queue.taskResults[id], result) }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(name + "/a-ok.bin")), Data([1, 2, 3]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent(name).path), ["a-ok.bin"])
        try evidence(wire, stage: "download-denial-partial-cancel", plan: plan, queue: queue, base: destination, start: start)
    }
    private func cancellation(_ wire: Wire) async throws {
        let name = "取消 下载%#", remote = wire.root.appendingPathComponent(name), destination = try folder()
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try Data(repeating: 128, count: 65536).write(to: remote.appendingPathComponent("slow.bin"))
        try Data([1]).write(to: remote.appendingPathComponent("z-tail.bin"))
        let start = try wire.commands().count
        let (plan, queue) = try await download([name], to: destination, wire: wire)
        XCTAssertTrue(queue.chooseConflictPolicy(.ask, planID: plan.id)); queue.startOrContinue()
        try await wait {
            try wire.commands().dropFirst(start).contains { ($0["command"] == "RETR" && $0["argument"] == "slow.bin") || ($0["command"] == "OPEN" && $0["path"] == "/" + name + "/slow.bin") }
        }
        let began = ProcessInfo.processInfo.systemUptime
        queue.cancelAll(); try await wait({ !queue.isLocked }, seconds: 3)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 2)
        XCTAssertEqual(queue.summary?.succeeded, 1); XCTAssertEqual(queue.summary?.cancelled, 2); XCTAssertEqual(queue.summary?.successfulBytes, 0)
        XCTAssertFalse(queue.hasCredentials); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent(name).path).isEmpty)
        let results = queue.taskResults
        try await Task.sleep(nanoseconds: 100_000_000); XCTAssertEqual(queue.taskResults, results)
        try evidence(wire, stage: "download-active-cancel", plan: plan, queue: queue, base: destination, start: start)
    }
    private func uploadCancellation(_ wire: Wire) async throws {
        let base = try folder(), directory = base.appendingPathComponent("取消 上传%#")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([1]).write(to: directory.appendingPathComponent("waiting.bin"))
        let remoteRoot = try path(["等待确认"], wire)
        var start = try wire.commands().count
        let (directoryPlan, directoryQueue) = try await upload([directory], to: remoteRoot, wire: wire)
        XCTAssertTrue(directoryQueue.chooseConflictPolicy(.ask, planID: directoryPlan.id)); directoryQueue.startOrContinue()
        try await wait {
            try wire.commands().dropFirst(start).contains { ($0["command"] == "MKD" && $0["argument"] == directory.lastPathComponent) || ($0["command"] == "MKDIR" && $0["path"] == "/等待确认/" + directory.lastPathComponent) }
        }
        var began = ProcessInfo.processInfo.systemUptime
        directoryQueue.cancelAll(); try await wait({ !directoryQueue.isLocked }, seconds: 3)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 2)
        XCTAssertEqual(directoryQueue.summary?.cancelled, 2); XCTAssertEqual(directoryQueue.summary?.succeeded, 0)
        XCTAssertFalse(directoryQueue.hasCredentials)
        XCTAssertFalse(try wire.commands().dropFirst(start).contains { ["STOR", "RETR", "OPEN"].contains($0["command"] ?? "") })
        try evidence(wire, stage: "upload-directory-active-cancel", plan: directoryPlan, queue: directoryQueue, base: wire.root.appendingPathComponent("等待确认"), start: start)

        let file = base.appendingPathComponent("active-upload.bin"), tail = base.appendingPathComponent("never-send.bin")
        try Data(repeating: 42, count: 65536).write(to: file); try Data([2]).write(to: tail)
        start = try wire.commands().count
        let (filePlan, fileQueue) = try await upload([file, tail], to: remoteRoot, wire: wire)
        XCTAssertTrue(fileQueue.chooseConflictPolicy(.ask, planID: filePlan.id)); fileQueue.startOrContinue()
        try await wait { fileQueue.items.first?.state == .awaitingCompletion }
        began = ProcessInfo.processInfo.systemUptime
        fileQueue.cancelAll(); try await wait({ !fileQueue.isLocked }, seconds: 3)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 2)
        XCTAssertEqual(fileQueue.summary?.cancelled, 2); XCTAssertEqual(fileQueue.summary?.succeeded, 0)
        XCTAssertEqual(fileQueue.summary?.successfulBytes, 0); XCTAssertFalse(fileQueue.hasCredentials)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wire.root.appendingPathComponent("等待确认/never-send.bin").path))
        try evidence(wire, stage: "upload-file-final-confirmation-cancel", plan: filePlan, queue: fileQueue, base: wire.root.appendingPathComponent("等待确认"), start: start)
    }
    private func typeConflict(_ wire: Wire) async throws {
        let base = try folder(), source = base.appendingPathComponent("类型冲突 %#")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data([1]).write(to: source.appendingPathComponent("child.bin"))
        try Data("keep".utf8).write(to: wire.root.appendingPathComponent(source.lastPathComponent))
        let roots = [try LocalSourceRoot(url: source)]; defer { roots.forEach { $0.endAccess() } }
        let commandStart = try wire.commands().count, start = try contentCount(wire)
        let scanned = try await LocalTransferScanner().scan(roots: roots, destination: .root, encoding: wire.mode.encoding, cancellation: FTPCancellationToken())
        let plan = try await TransferRetryPlanner().inspectTargets(scanned, client: wire.client, endpoint: wire.endpoint, credentials: wire.credentials, destination: nil, cancellation: FTPCancellationToken())
        XCTAssertFalse(plan.canStart); XCTAssertTrue(plan.issues.contains { $0.reason == .typeConflict })
        let queue = BatchTransferQueue(client: wire.client, executor: TransferExecutor())
        XCTAssertThrowsError(try queue.prepare(plan: plan, endpoint: wire.endpoint, remoteRoot: .root, encoding: wire.mode.encoding, credentials: wire.credentials, sources: [plan.roots[0].id: roots[0]]))
        XCTAssertEqual(try contentCount(wire), start); XCTAssertEqual(try Data(contentsOf: wire.root.appendingPathComponent(source.lastPathComponent)), Data("keep".utf8))
        let name = "下载 类型冲突%#", remote = wire.root.appendingPathComponent(name), destination = try folder()
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try Data([1]).write(to: remote.appendingPathComponent("child.bin"))
        try Data("keep local".utf8).write(to: destination.appendingPathComponent(name))
        let listing = try await wire.client.list(endpoint: wire.endpoint, path: .root, encoding: wire.mode.encoding, credentials: wire.credentials, cancellation: FTPCancellationToken())
        let entry = try XCTUnwrap(listing.entries.first { $0.name == name })
        let root = try LocalDestinationRoot(url: destination); defer { root.endAccess() }
        let remotePlan = try await RemoteTransferScanner(client: wire.client).scan(endpoint: wire.endpoint, selections: [.init(entry: entry, path: path([name], wire), encoding: listing.encoding)], destination: root, credentials: wire.credentials, cancellation: FTPCancellationToken())
        let blocked = try await TransferRetryPlanner().inspectTargets(remotePlan, client: wire.client, endpoint: wire.endpoint, credentials: wire.credentials, destination: root, cancellation: FTPCancellationToken())
        XCTAssertFalse(blocked.canStart); XCTAssertTrue(blocked.issues.contains { $0.reason == .typeConflict })
        XCTAssertThrowsError(try queue.prepare(plan: blocked, endpoint: wire.endpoint, remoteRoot: .root, encoding: wire.mode.encoding, credentials: wire.credentials, destination: root))
        XCTAssertEqual(try contentCount(wire), start); XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(name)), Data("keep local".utf8))
        let commands = Array(try wire.commands().dropFirst(commandStart))
        XCTAssertFalse(commands.contains { ["MKD", "MKDIR", "STOR", "RETR", "OPEN", "DELE", "RNFR", "RNTO", "SITE", "REMOVE", "RMDIR", "RENAME", "SETSTAT", "FSETSTAT"].contains($0["command"] ?? "") })
        let result: [String: Any] = ["mode": wire.mode.label, "stage": "bidirectional-type-conflict", "upload_can_start": plan.canStart, "download_can_start": blocked.canStart, "upload_issues": plan.issues.map { String(describing: $0.reason) }, "download_issues": blocked.issues.map { String(describing: $0.reason) }, "original_targets_preserved": true, "commands": commands]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "collection-matrix-" + wire.mode.label + "-bidirectional-type-conflict"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
