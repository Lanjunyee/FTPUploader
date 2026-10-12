import XCTest

/// Reusable deterministic scale inputs. Node count includes directory nodes.
/// No real endpoint, credential, or user path is captured in benchmark data.
enum TransferScaleInput {
    static func name(_ index: Int) -> String { String(format: "item-%05d 中文 %%#", index) }

    static func plan(nodeCount: Int, depth: Int = 1, encoding: FTPTextEncoding = .utf8) throws -> TransferPlan {
        precondition(nodeCount >= depth && depth >= 1)
        let components = try (0..<depth).map { index in
            let name = index == 0 ? "scale 中文 %#" : String(format: "directory-%02d", index)
            return RemotePath.Component(name: name, bytes: try encoding.encode(name))
        }
        let root = TransferPlan.Root(source: .remote(RemotePath(components: [components[0]]), encoding), kind: .directory)
        var nodes: [TransferPlan.Node] = []
        var parent: UUID?
        func add(_ path: [RemotePath.Component], kind: RemoteEntry.Kind, size: Int64?) {
            let node = TransferPlan.Node(rootID: root.id, kind: kind,
                source: .remote(RemotePath(components: path), encoding),
                target: .local(URL(fileURLWithPath: "/benchmark-destination/" + path.map(\.name).joined(separator: "/"))),
                relativePath: path, parentID: parent, size: size, snapshot: .remote(kind: kind, size: size))
            nodes.append(node)
            if kind == .directory { parent = node.id }
        }
        for index in 0..<depth { add(Array(components.prefix(index + 1)), kind: .directory, size: nil) }
        for index in 0..<(nodeCount - depth) {
            let leaf = name(index)
            add(components + [.init(name: leaf, bytes: try encoding.encode(leaf))], kind: .regularFile, size: 4096)
        }
        return TransferPlan(direction: .download, roots: [root], nodes: nodes.reversed())
    }

    static func directory(at base: URL, fileCount: Int, depth: Int = 1) throws -> URL {
        precondition(depth > 0)
        var directory = base.appendingPathComponent("scale 中文 %#")
        for index in 1..<depth { directory.appendPathComponent(String(format: "directory-%02d", index)) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<fileCount { try Data([0, 255, 42]).write(to: directory.appendingPathComponent(name(index))) }
        return base.appendingPathComponent("scale 中文 %#")
    }

    /// Bounded allocation, deterministic binary contents; no giant in-memory Data.
    static func largeFile(at url: URL, bytes: Int = 64 * 1024 * 1024) throws {
        precondition(bytes >= 0)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw POSIXError(.EIO) }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        let block = Data((0..<(1024 * 1024)).map { UInt8($0 % 256) })
        var remaining = bytes
        while remaining > 0 {
            let count = min(remaining, block.count)
            try output.write(contentsOf: block.prefix(count)); remaining -= count
        }
        try output.close()
    }
}

private final class ScaleListingClient: FTPServing {
    let counts = TransferDiagnostics()
    let listings: [[Data]: DirectoryListing]
    init(plan: TransferPlan) {
        var entries: [[Data]: [RemoteEntry]] = [:]
        for node in plan.nodes {
            guard case .remote(let path, _) = node.target, let parent = path.parent,
                  let name = path.components.last else { continue }
            entries[parent.components.map(\.bytes), default: []].append(
                RemoteEntry(name: name.name, rawName: name.bytes, kind: node.kind, size: node.size))
        }
        listings = entries.mapValues { DirectoryListing(entries: $0, encoding: .utf8) }
    }
    func list(endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding?, credentials: FTPCredentials,
              cancellation: FTPCancellationToken) async throws -> DirectoryListing {
        try cancellation.checkCancellation(); counts.record(.listings)
        return listings[path.components.map(\.bytes)] ?? DirectoryListing(entries: [], encoding: .utf8)
    }
    func checkUploadTarget(endpoint: FTPEndpoint, path: RemotePath, name: String, encoding: FTPTextEncoding,
                           credentials: FTPCredentials, cancellation: FTPCancellationToken) async throws -> RemoteEntry? {
        let listing = try await list(endpoint: endpoint, path: path, encoding: encoding, credentials: credentials, cancellation: cancellation)
        let raw = try encoding.encode(name)
        return listing.entries.first { $0.rawName == raw }
    }
    func upload(endpoint: FTPEndpoint, path: RemotePath, file: URL, encoding: FTPTextEncoding,
                credentials: FTPCredentials, cancellation: FTPCancellationToken, progress: @escaping (Int64, Int64) -> Void) async throws {
        XCTFail("Preview must not write"); throw POSIXError(.EPERM)
    }
    func download(endpoint: FTPEndpoint, path: RemotePath, credentials: FTPCredentials, cancellation: FTPCancellationToken,
                  receive: @escaping (Data) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws {
        XCTFail("Preview must not read contents"); throw POSIXError(.EPERM)
    }
    func createDirectory(endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding,
                         credentials: FTPCredentials, cancellation: FTPCancellationToken) async throws {
        XCTFail("Preview must not create directories"); throw POSIXError(.EPERM)
    }
}

final class TransferScaleInputTests: XCTestCase {
    @MainActor
    func testReleasePlanAndPreviewBaseline() async throws {
        for count in [1_000, 10_000] {
            for depth in [1, 8] {
                let start = ProcessInfo.processInfo.systemUptime
                let input = try TransferScaleInput.plan(nodeCount: count, depth: depth)
                let roots = input.roots.map { TransferPlan.Root(id: $0.id, source: .local(URL(fileURLWithPath: "/benchmark-source")), kind: $0.kind) }
                let plan = TransferPlan(direction: .upload, roots: roots, nodes: input.nodes.map { node in
                    .init(id: node.id, rootID: node.rootID, kind: node.kind, source: node.target, target: node.source,
                          relativePath: node.relativePath, parentID: node.parentID, size: node.size,
                          snapshot: node.kind == .directory ? .localDirectory(device: 1, inode: 1) :
                            .localFile(.init(size: node.size!, modified: nil, inode: 1, digest: Data())))
                })
                let planSeconds = ProcessInfo.processInfo.systemUptime - start
                XCTAssertTrue(plan.canStart)
                let client = ScaleListingClient(plan: plan)
                let previewStart = ProcessInfo.processInfo.systemUptime
                let checked = try await TransferRetryPlanner().inspectTargets(plan, client: client,
                    endpoint: FTPEndpoint(address: "127.0.0.1:2121"), credentials: .anonymous,
                    destination: nil, cancellation: FTPCancellationToken())
                let previewSeconds = ProcessInfo.processInfo.systemUptime - previewStart
                XCTAssertTrue(checked.canStart); XCTAssertEqual(checked.existingTargetIDs.count, count)
                XCTAssertEqual(client.counts.snapshot["listings"], Int64(depth + 1), "One query per accessible parent, not per node")
                var usage = rusage(); XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
                let result: [String: Any] = ["case": "controlled-preview", "nodes": count, "depth": depth,
                    "plan_seconds": planSeconds, "preview_seconds": previewSeconds,
                    "peak_rss_bytes": usage.ru_maxrss, "counters": client.counts.snapshot]
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                print("HARDENING_BASELINE " + String(decoding: data, as: UTF8.self))
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "hardening-scale-\(count)-\(depth)"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }

    func testThousandAndTenThousandNodePlansPreserveOrderingTotalsAndRawPaths() throws {
        for count in [1_000, 10_000] {
            for depth in [1, 8] {
                for encoding in [FTPTextEncoding.utf8, .gb18030] {
                    let plan = try TransferScaleInput.plan(nodeCount: count, depth: depth, encoding: encoding)
                    XCTAssertTrue(plan.canStart, "\(plan.issues)")
                    XCTAssertEqual(plan.nodes.count, count)
                    XCTAssertEqual(plan.totalSize, Int64((count - depth) * 4096))
                    XCTAssertEqual(plan.nodes.prefix(depth).map(\.kind), Array(repeating: .directory, count: depth))
                    let files = Array(plan.nodes.dropFirst(depth))
                    XCTAssertEqual(files.map { $0.relativePath.last!.name }, (0..<(count - depth)).map(TransferScaleInput.name))
                    for node in plan.nodes {
                        guard case .remote(let source, let actualEncoding) = node.source else { return XCTFail() }
                        XCTAssertEqual(source.components, node.relativePath)
                        XCTAssertEqual(actualEncoding, encoding)
                        for part in source.components { XCTAssertEqual(part.bytes, try encoding.encode(part.name)) }
                    }
                }
            }
        }
    }

    func testNodeAndDepthLimitInputsAreBlockedWithoutTruncation() throws {
        let nodes = try TransferScaleInput.plan(nodeCount: 10_001)
        XCTAssertFalse(nodes.canStart)
        XCTAssertEqual(nodes.nodes.count, 10_001)
        XCTAssertEqual(nodes.issues.filter { $0.reason == .nodeLimit }.count, 1)
        let exact = try TransferScaleInput.plan(nodeCount: 64, depth: 64)
        XCTAssertTrue(exact.canStart)
        let deep = try TransferScaleInput.plan(nodeCount: 65, depth: 65)
        XCTAssertFalse(deep.canStart)
        XCTAssertEqual(deep.nodes.count, 65)
        XCTAssertEqual(deep.issues.filter { $0.reason == .depthLimit }.count, 1)
    }

    func testFlatNestedAndLargeBinaryInputs() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        for depth in [1, 8] {
            let container = base.appendingPathComponent("depth-\(depth)")
            let root = try TransferScaleInput.directory(at: container, fileCount: 1_000, depth: depth)
            var leaf = root
            for index in 1..<depth { leaf.appendPathComponent(String(format: "directory-%02d", index)) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: leaf.path).sorted(), (0..<1_000).map(TransferScaleInput.name))
            XCTAssertEqual(try Data(contentsOf: leaf.appendingPathComponent(TransferScaleInput.name(999))), Data([0, 255, 42]))
        }
        let large = base.appendingPathComponent("large.bin")
        try TransferScaleInput.largeFile(at: large)
        let counts = TransferDiagnostics()
        let source = try SelectedLocalFile(url: large, diagnostics: counts)
        defer { source.endAccess() }
        let snapshot = try await source.snapshot()
        XCTAssertEqual(snapshot.size, 64 * 1024 * 1024)
        XCTAssertEqual(counts.snapshot["hashPasses"], 1)
        XCTAssertEqual(counts.snapshot["hashBytes"], snapshot.size)
    }
}

final class TransferPlanTests: XCTestCase {
    func testIndexedNodesRootsParentsAndDirectoriesMatchLegacyLookupsWithoutRebuilding() throws {
        for count in [1_000, 10_000] {
            let input = try TransferScaleInput.plan(nodeCount: count, depth: 8)
            let roots = input.roots.map { root in
                TransferPlan.Root(id: root.id, source: input.index.nodesByRoot[root.id]!.first!.target, kind: root.kind)
            }
            let nodes = input.nodes.enumerated().map { offset, node in
                TransferPlan.Node(id: node.id, rootID: node.rootID, kind: node.kind, source: node.target, target: node.source,
                    relativePath: node.relativePath, parentID: node.parentID, size: node.size,
                    snapshot: node.kind == .directory ? .localDirectory(device: 1, inode: UInt64(offset + 1)) :
                        .localFile(.init(size: node.size!, modified: nil, inode: UInt64(offset + 1), digest: Data())))
            }
            let counts = TransferDiagnostics(), plan = TransferPlan(direction: .upload, roots: roots, nodes: nodes, diagnostics: counts)
            XCTAssertTrue(plan.canStart); XCTAssertEqual(plan.nodes.map(\.id), input.nodes.map(\.id))
            var legacyDirectories: [[String]: (UInt64, UInt64)] = [:]
            for node in plan.nodes {
                if case .localDirectory(let device, let inode) = node.snapshot { legacyDirectories[node.relativePath.dropFirst().map(\.name)] = (device, inode) }
            }
            for node in plan.nodes {
                XCTAssertEqual(plan.index.node(id: node.id), plan.nodes.first { $0.id == node.id })
                XCTAssertTrue(plan.index.contains(node))
                XCTAssertEqual(plan.index.root(id: node.rootID), roots.first { $0.id == node.rootID })
                XCTAssertEqual(plan.nodes[plan.index.positionByID[node.id]!], node)
                XCTAssertEqual(plan.index.localDirectories(rootID: node.rootID).mapValues { [$0.0, $0.1] }, legacyDirectories.mapValues { [$0.0, $0.1] })
            }
            for node in plan.nodes where node.kind == .directory {
                XCTAssertEqual(plan.index.childrenByParent[node.id] ?? [], plan.nodes.filter { $0.parentID == node.id })
            }
            XCTAssertEqual(plan.index.nodesByRoot[roots[0].id], plan.nodes)
            XCTAssertEqual(counts.snapshot["planIndexNodes"], Int64(count), "Only one construction pass, not one per lookup")
            XCTAssertEqual(counts.snapshot["planNodeLookups"], Int64(count * 2))
            XCTAssertEqual(counts.snapshot["planRootLookups"], Int64(count))
            XCTAssertEqual(counts.snapshot["planDirectoryLookups"], Int64(count))
            XCTAssertEqual(counts.snapshot["planRootKeys"], 1)
        }
    }
    func testPrecomputedRootKeysPreserveLegacyOverlapOrderAcrossDomains() throws {
        let remote = try RemotePath.root.appending(name: "tree", bytes: Data("tree".utf8))
        let child = try remote.appending(name: "child", bytes: Data("child".utf8))
        let roots: [TransferPlan.Root] = [
            .init(source: .local(URL(fileURLWithPath: "/tmp/root-reference/tree")), kind: .directory),
            .init(source: .remote(child, .utf8), kind: .regularFile),
            .init(source: .local(URL(fileURLWithPath: "/tmp/root-reference/tree/child")), kind: .regularFile),
            .init(source: .remote(remote, .utf8), kind: .directory),
            .init(source: .local(URL(fileURLWithPath: "/tmp/root-reference/tree/other/../child")), kind: .regularFile),
            .init(source: .remote(child, .gb18030), kind: .regularFile)
        ]
        func segments(_ location: TransferPlan.Location) -> [Data] {
            switch location {
            case .local(let url): return url.standardizedFileURL.pathComponents.map { Data($0.utf8) }
            case .remote(let path, _): return path.components.map(\.bytes)
            }
        }
        var expected: [TransferPlan.Issue] = []
        for (index, root) in roots.enumerated() {
            for previous in roots.prefix(index) {
                switch (root.source, previous.source) {
                case (.local, .local), (.remote, .remote): break
                default: continue
                }
                let a = segments(root.source), b = segments(previous.source)
                if a == b || (previous.kind == .directory && a.starts(with: b)) || (root.kind == .directory && b.starts(with: a)) {
                    let path: String
                    switch root.source { case .local(let url): path = url.path; case .remote(let remote, _): path = remote.display }
                    expected.append(.init(rootID: root.id, nodeID: nil, path: path, reason: .overlappingRoots))
                }
            }
        }
        let counts = TransferDiagnostics()
        let plan = TransferPlan(direction: .download, roots: roots, nodes: [], diagnostics: counts)
        XCTAssertEqual(plan.issues, expected)
        XCTAssertEqual(counts.snapshot["planRootKeys"], Int64(roots.count))
        XCTAssertEqual(counts.snapshot["planNodeMembershipChecks"], 0)
    }
    private func remote(_ names: [String]) -> RemotePath {
        RemotePath(components: names.map { .init(name: $0, bytes: Data($0.utf8)) })
    }
    private func node(_ root: TransferPlan.Root, _ names: [String], kind: RemoteEntry.Kind = .regularFile,
                      parent: UUID? = nil, target: TransferPlan.Location? = nil) -> TransferPlan.Node {
        let path = remote(names)
        return TransferPlan.Node(rootID: root.id, kind: kind, source: .remote(path, .utf8),
            target: target ?? .local(URL(fileURLWithPath: "/destination/" + names.joined(separator: "/"))),
            relativePath: path.components, parentID: parent, size: 0, snapshot: .remote(kind: kind, size: 0))
    }
    func testStableRootAndRawByteOrderPreservesEmptyDirectoriesAndParents() {
        let first = TransferPlan.Root(source: .remote(remote(["z"]), .utf8), kind: .directory)
        let second = TransferPlan.Root(source: .remote(remote(["a"]), .utf8), kind: .regularFile)
        let parent = node(first, ["z"], kind: .directory)
        let lower = node(first, ["z", "a"], parent: parent.id)
        let upper = node(first, ["z", "Z"], parent: parent.id)
        let empty = node(first, ["z", "empty"], kind: .directory, parent: parent.id)
        let last = node(second, ["a"])
        let plan = TransferPlan(direction: .download, roots: [first, second], nodes: [last, empty, lower, parent, upper])
        XCTAssertEqual(plan.nodes.map(\.id), [parent.id, upper.id, lower.id, empty.id, last.id])
        // Z/a have different folded keys; all nodes, including the empty directory, are retained.
        XCTAssertTrue(plan.canStart)
        XCTAssertNil(empty.size)
        XCTAssertEqual(plan.nodes.first?.parentID, nil)
    }
    func testOverlappingLocalAndRemoteRootsInEitherSelectionOrder() {
        for local in [false, true] {
            let parent: TransferPlan.Location = local ? .local(URL(fileURLWithPath: "/source/tree")) : .remote(remote(["tree"]), .utf8)
            let child: TransferPlan.Location = local ? .local(URL(fileURLWithPath: "/source/tree/file")) : .remote(remote(["tree", "file"]), .utf8)
            let a = TransferPlan.Root(source: parent, kind: .directory)
            let b = TransferPlan.Root(source: child, kind: .regularFile)
            for roots in [[a, b], [b, a], [a, a]] {
                let plan = TransferPlan(direction: local ? .upload : .download, roots: roots, nodes: [])
                XCTAssertTrue(plan.issues.contains { $0.reason == .overlappingRoots })
                XCTAssertFalse(plan.canStart)
            }
        }
    }
    func testDuplicateTargetsAndTypeConflicts() {
        let a = TransferPlan.Root(source: .remote(remote(["a"]), .utf8), kind: .regularFile)
        let b = TransferPlan.Root(source: .remote(remote(["b"]), .utf8), kind: .regularFile)
        let target = TransferPlan.Location.local(URL(fileURLWithPath: "/destination/same"))
        for kind in [RemoteEntry.Kind.regularFile, .directory] {
            let plan = TransferPlan(direction: .download, roots: [a, b], nodes: [node(a, ["a"], target: target), node(b, ["b"], kind: kind, target: target)])
            XCTAssertTrue(plan.issues.contains { $0.reason == (kind == .regularFile ? .duplicateTarget : .typeConflict) })
            XCTAssertFalse(plan.canStart)
        }
    }
    func testConservativeLocalCaseAndUnicodeAliases() {
        for names in [["File", "file"], ["é", "e\u{301}"]] {
            let roots = names.map { TransferPlan.Root(source: .remote(remote([$0]), .utf8), kind: .regularFile) }
            let plan = TransferPlan(direction: .download, roots: roots, nodes: zip(roots, names).map { node($0, [$1]) })
            XCTAssertTrue(plan.issues.contains { $0.reason == .localAlias })
            XCTAssertFalse(plan.canStart)
        }
    }
    func testUnsafeTypesNamesAndMissingDependenciesBlockPlan() {
        let root = TransferPlan.Root(source: .remote(remote(["tree"]), .utf8), kind: .directory)
        let nodes = [node(root, ["tree", "file"], parent: UUID()), node(root, ["tree:bad"]), node(root, ["link"], kind: .symbolicLink)]
        let plan = TransferPlan(direction: .download, roots: [root], nodes: nodes)
        for reason in [TransferPlan.Issue.Reason.invalidDependency, .invalidName, .unsupportedType] {
            XCTAssertTrue(plan.issues.contains { $0.reason == reason })
        }
        XCTAssertFalse(plan.canStart)
    }
    func testUnknownSizesOverflowAndDirectoryOnlyTotals() {
        let a = TransferPlan.Root(source: .remote(remote(["a"]), .utf8), kind: .regularFile)
        let b = TransferPlan.Root(source: .remote(remote(["b"]), .utf8), kind: .regularFile)
        func sized(_ root: TransferPlan.Root, _ name: String, _ size: Int64?) -> TransferPlan.Node {
            let item = node(root, [name])
            return .init(rootID: root.id, kind: .regularFile, source: item.source, target: item.target,
                         relativePath: item.relativePath, size: size, snapshot: .remote(kind: .regularFile, size: size))
        }
        let unknown = TransferPlan(direction: .download, roots: [a], nodes: [sized(a, "a", nil)])
        XCTAssertNil(unknown.totalSize); XCTAssertTrue(unknown.canStart)
        let overflow = TransferPlan(direction: .download, roots: [a, b], nodes: [sized(a, "a", Int64.max), sized(b, "b", 1)])
        XCTAssertNil(overflow.totalSize); XCTAssertFalse(overflow.canStart)
        XCTAssertTrue(overflow.issues.contains { $0.reason == .sizeOverflow })
        let exact = TransferPlan(direction: .download, roots: [a, b], nodes: [sized(a, "a", Int64.max - 1), sized(b, "b", 1)])
        XCTAssertEqual(exact.totalSize, Int64.max); XCTAssertTrue(exact.canStart)
        let directories = TransferPlan(direction: .download, roots: [a], nodes: [node(a, ["a"], kind: .directory)])
        XCTAssertEqual(directories.totalSize, 0); XCTAssertTrue(directories.canStart)
    }

    func testUploadSnapshotAndRemoteBytesRemainMemoryOnly() throws {
        let root = TransferPlan.Root(source: .local(URL(fileURLWithPath: "/source/中文")), kind: .regularFile)
        let bytes = try FTPTextEncoding.gb18030.encode("中文")
        let path = RemotePath(components: [.init(name: "中文", bytes: bytes)])
        let snapshot = SelectedLocalFile.Snapshot(size: 0, modified: nil, inode: 1, digest: Data([1, 2]))
        let item = TransferPlan.Node(rootID: root.id, kind: .regularFile, source: root.source,
            target: .remote(path, .gb18030), relativePath: path.components, size: 0, snapshot: .localFile(snapshot))
        let plan = TransferPlan(direction: .upload, roots: [root], nodes: [item])
        XCTAssertTrue(plan.canStart)
        XCTAssertEqual(plan.nodes[0].snapshot, .localFile(snapshot))
        XCTAssertEqual(plan.nodes[0].target, .remote(path, .gb18030))
        XCTAssertEqual(Set(Mirror(reflecting: plan).children.compactMap(\.label)), ["id", "direction", "roots", "nodes", "index", "issues", "existingTargetIDs"])
        XCTAssertEqual(Set(Mirror(reflecting: plan.index).children.compactMap(\.label)),
            ["nodesByRoot", "childrenByParent", "positionByID", "nodesByID", "duplicateNodes", "rootsByID", "directoriesByRoot", "diagnostics"])
        XCTAssertFalse((plan as Any) is any Encodable)
        XCTAssertFalse((plan.index as Any) is any Encodable)
        XCTAssertFalse(Mirror(reflecting: plan.index).children.contains { $0.value is FTPCredentials || $0.value is FTPCancellationToken })
        XCTAssertEqual(plan.index.node(id: item.id)?.snapshot, .localFile(snapshot))
        XCTAssertEqual(plan.index.node(id: item.id)?.target, .remote(path, .gb18030))
        XCTAssertTrue(plan.existingTargetIDs.isEmpty)
    }
}
