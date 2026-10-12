import Foundation

/// Planning data is memory-only: no credentials, bookmarks, or Codable conformance.
struct TransferPlan {
    enum Location: Equatable {
        case local(URL)
        case remote(RemotePath, FTPTextEncoding)
    }
    struct Root: Identifiable, Equatable {
        let id: UUID
        let source: Location
        let kind: RemoteEntry.Kind
        init(id: UUID = UUID(), source: Location, kind: RemoteEntry.Kind) {
            self.id = id; self.source = source; self.kind = kind
        }
    }
    enum SourceSnapshot: Equatable {
        case localFile(SelectedLocalFile.Snapshot)
        case localDirectory(device: UInt64, inode: UInt64)
        case remote(kind: RemoteEntry.Kind, size: Int64?)
    }
    struct Node: Identifiable, Equatable {
        let id: UUID
        let rootID: UUID
        let kind: RemoteEntry.Kind
        let source: Location
        let target: Location
        let relativePath: [RemotePath.Component]
        let parentID: UUID?
        let size: Int64?
        let snapshot: SourceSnapshot
        init(id: UUID = UUID(), rootID: UUID, kind: RemoteEntry.Kind, source: Location,
             target: Location, relativePath: [RemotePath.Component], parentID: UUID? = nil,
             size: Int64? = nil, snapshot: SourceSnapshot) {
            self.id = id; self.rootID = rootID; self.kind = kind; self.source = source
            self.target = target; self.relativePath = relativePath; self.parentID = parentID
            self.size = kind == .regularFile ? size : nil; self.snapshot = snapshot
        }
    }
    /// Immutable indexes follow the same ordered node/root arrays as legacy first/filter lookups.
    struct Index {
        let nodesByRoot: [UUID: [Node]]
        let childrenByParent: [UUID: [Node]]
        let positionByID: [UUID: Int]
        private let nodesByID: [UUID: Node]
        private let duplicateNodes: [UUID: [Node]]
        private let rootsByID: [UUID: Root]
        private let directoriesByRoot: [UUID: [[String]: (UInt64, UInt64)]]
        private let diagnostics: TransferDiagnostics?

        init(nodes: [Node], roots: [Root], diagnostics: TransferDiagnostics?) {
            var byID: [UUID: Node] = [:], duplicates: [UUID: [Node]] = [:], positions: [UUID: Int] = [:]
            var byRoot: [UUID: [Node]] = [:], children: [UUID: [Node]] = [:]
            var directories: [UUID: [[String]: (UInt64, UInt64)]] = [:]
            for (position, node) in nodes.enumerated() {
                diagnostics?.record(.planIndexNodes)
                if byID[node.id] == nil { byID[node.id] = node; positions[node.id] = position }
                else { duplicates[node.id, default: []].append(node) }
                byRoot[node.rootID, default: []].append(node)
                if let parent = node.parentID { children[parent, default: []].append(node) }
                if case .localDirectory(let device, let inode) = node.snapshot {
                    directories[node.rootID, default: [:]][node.relativePath.dropFirst().map(\.name)] = (device, inode)
                }
            }
            nodesByID = byID; duplicateNodes = duplicates; positionByID = positions
            nodesByRoot = byRoot; childrenByParent = children; directoriesByRoot = directories
            rootsByID = Dictionary(roots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            self.diagnostics = diagnostics
        }
        func node(id: UUID) -> Node? { diagnostics?.record(.planNodeLookups); return nodesByID[id] }
        func contains(_ node: Node) -> Bool { self.node(id: node.id) == node || duplicateNodes[node.id]?.contains(node) == true }
        func root(id: UUID) -> Root? { diagnostics?.record(.planRootLookups); return rootsByID[id] }
        func localDirectories(rootID: UUID) -> [[String]: (UInt64, UInt64)] {
            diagnostics?.record(.planDirectoryLookups)
            return directoriesByRoot[rootID] ?? [:]
        }
    }
    struct Issue: Equatable {
        enum Reason: Equatable {
            case overlappingRoots, duplicateTarget, typeConflict, localAlias, invalidName
            case unsupportedType, invalidDependency, invalidDirection, unreadable, changedSource
            case nodeLimit, depthLimit, listingLimit, sizeOverflow, invalidSize, cycle, incomplete
        }
        let rootID: UUID
        let nodeID: UUID?
        let path: String
        let reason: Reason
    }
    let id: UUID
    let direction: TransferDirection
    let roots: [Root]
    let nodes: [Node]
    let index: Index
    let issues: [Issue]
    /// Read-only preview findings, never an overwrite grant.
    let existingTargetIDs: Set<UUID>
    var canStart: Bool { !nodes.isEmpty && issues.isEmpty }
    var totalSize: Int64? {
        var total: Int64 = 0
        for node in nodes where node.kind == .regularFile {
            guard let size = node.size, size >= 0 else { return nil }
            let (next, overflow) = total.addingReportingOverflow(size)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }
    static let maximumNodes = 10_000
    static let maximumDepth = 64
    static let maximumListingBytes = 16 * 1024 * 1024

    init(id: UUID = UUID(), direction: TransferDirection, roots: [Root], nodes: [Node], issues: [Issue] = [],
         existingTargetIDs: Set<UUID> = [], diagnostics: TransferDiagnostics? = nil) {
        self.id = id; self.direction = direction; self.roots = roots
        let ordered = Self.ordered(nodes, roots: roots)
        self.nodes = ordered
        self.index = Index(nodes: ordered, roots: roots, diagnostics: diagnostics)
        self.issues = issues + Self.validate(direction: direction, roots: roots, nodes: nodes, diagnostics: diagnostics)
        self.existingTargetIDs = existingTargetIDs
    }

    /// Root selection order, then raw-byte path order (prefix parents before children).
    private static func ordered(_ nodes: [Node], roots: [Root]) -> [Node] {
        let order = Dictionary(roots.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: min)
        return nodes.sorted { a, b in
            let left = order[a.rootID] ?? Int.max, right = order[b.rootID] ?? Int.max
            if left != right { return left < right }
            for (x, y) in zip(a.relativePath, b.relativePath) where x.bytes != y.bytes {
                return x.bytes.lexicographicallyPrecedes(y.bytes)
            }
            return a.relativePath.count < b.relativePath.count
        }
    }

    private static func path(_ location: Location) -> String {
        switch location {
        case .local(let url): return url.path
        case .remote(let path, _): return path.display
        }
    }
    private static func segments(_ location: Location) -> [Data] {
        switch location {
        case .local(let url): return url.standardizedFileURL.pathComponents.map { Data($0.utf8) }
        case .remote(let path, _): return path.components.map(\.bytes)
        }
    }
    private static func sameDomain(_ a: Location, _ b: Location) -> Bool {
        switch (a, b) {
        case (.local, .local), (.remote, .remote): return true
        default: return false
        }
    }
    private static func aliasKey(_ location: Location) -> [String]? {
        guard case .local(let url) = location else { return nil }
        return url.standardizedFileURL.pathComponents.map {
            $0.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
    }
    private static func validate(direction: TransferDirection, roots: [Root], nodes: [Node], diagnostics: TransferDiagnostics?) -> [Issue] {
        var issues: [Issue] = []
        func add(_ root: UUID, _ node: UUID?, _ location: Location, _ reason: Issue.Reason) {
            issues.append(Issue(rootID: root, nodeID: node, path: path(location), reason: reason))
        }
        let rootKeys = roots.map { root in
            diagnostics?.record(.planRootKeys)
            return segments(root.source)
        }
        let rootIDs = Set(roots.map(\.id))
        for (i, root) in roots.enumerated() {
            for (j, previous) in roots.prefix(i).enumerated() where sameDomain(root.source, previous.source) {
                let a = rootKeys[i], b = rootKeys[j]
                if a == b || (previous.kind == .directory && a.starts(with: b)) || (root.kind == .directory && b.starts(with: a)) {
                    add(root.id, nil, root.source, .overlappingRoots)
                }
            }
        }
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var targets: [[Data]: Node] = [:]
        var aliases: [[String]: Node] = [:]
        var total: Int64 = 0
        for (index, node) in nodes.enumerated() {
            if index >= maximumNodes { add(node.rootID, node.id, node.source, .nodeLimit) }
            if node.relativePath.count > maximumDepth { add(node.rootID, node.id, node.source, .depthLimit) }
            if node.kind == .regularFile, let size = node.size {
                if size < 0 { add(node.rootID, node.id, node.source, .invalidSize) }
                else {
                    let (next, overflow) = total.addingReportingOverflow(size)
                    if overflow { add(node.rootID, node.id, node.source, .sizeOverflow) }
                    else { total = next }
                }
            }
            if node.kind != .directory && node.kind != .regularFile {
                add(node.rootID, node.id, node.source, .unsupportedType)
            }
            switch (direction, node.source, node.target) {
            case (.upload, .local, .remote), (.download, .remote, .local): break
            default: add(node.rootID, node.id, node.target, .invalidDirection)
            }
            diagnostics?.record(.planNodeMembershipChecks)
            if !rootIDs.contains(node.rootID) || node.relativePath.isEmpty {
                add(node.rootID, node.id, node.source, .invalidDependency)
            }
            for component in node.relativePath {
                if (try? RemotePath.validateName(component.bytes)) == nil ||
                    (direction == .download && (component.name.contains(":") || component.name.contains("/") || component.name == "." || component.name == ".." || component.name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 })) {
                    add(node.rootID, node.id, node.target, .invalidName)
                }
            }
            if let parentID = node.parentID {
                guard let parent = byID[parentID], parent.kind == .directory,
                      parent.rootID == node.rootID, node.relativePath.count == parent.relativePath.count + 1,
                      Array(node.relativePath.dropLast()) == parent.relativePath else {
                    add(node.rootID, node.id, node.target, .invalidDependency); continue
                }
            } else if node.relativePath.count != 1 {
                add(node.rootID, node.id, node.target, .invalidDependency)
            }
            let key = segments(node.target)
            if let previous = targets[key] {
                add(node.rootID, node.id, node.target, previous.kind == node.kind ? .duplicateTarget : .typeConflict)
            } else { targets[key] = node }
            if let alias = aliasKey(node.target) {
                if let previous = aliases[alias],
                   segments(previous.target) != key || previous.relativePath.map(\.bytes) != node.relativePath.map(\.bytes) {
                    add(node.rootID, node.id, node.target, .localAlias)
                } else { aliases[alias] = node }
            }
        }
        return issues
    }
}
