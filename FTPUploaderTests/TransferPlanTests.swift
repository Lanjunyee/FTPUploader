import XCTest

final class TransferPlanTests: XCTestCase {
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
        XCTAssertEqual(Set(Mirror(reflecting: plan).children.compactMap(\.label)), ["id", "direction", "roots", "nodes", "issues", "existingTargetIDs"])
        XCTAssertTrue(plan.existingTargetIDs.isEmpty)
    }
}
