import Foundation

struct RemoteTransferScanner {
    struct Selection {
        let entry: RemoteEntry
        let path: RemotePath
        let encoding: FTPTextEncoding
    }
    let client: FTPServing

    func scan(endpoint: FTPEndpoint, selections: [Selection], destination: LocalDestinationRoot,
              credentials: FTPCredentials, cancellation: FTPCancellationToken,
              discovered: @escaping (Int) -> Void = { _ in }) async throws -> TransferPlan {
        let lease = try destination.lease()
        defer { withExtendedLifetime(lease) {} }
        try destination.validateIdentity()
        let roots = selections.map { TransferPlan.Root(source: .remote($0.path, $0.encoding), kind: $0.entry.kind) }
        var nodes: [TransferPlan.Node] = []
        var issues: [TransferPlan.Issue] = []
        func issue(_ root: UUID, _ path: RemotePath, _ reason: TransferPlan.Issue.Reason) {
            issues.append(.init(rootID: root, nodeID: nil, path: path.display, reason: reason))
        }
        func visit(_ entry: RemoteEntry, path: RemotePath, encoding: FTPTextEncoding,
                   root: UUID, relative: [RemotePath.Component], parent: UUID?) async throws {
            try cancellation.checkCancellation()
            guard nodes.count < TransferPlan.maximumNodes else { issue(root, path, .nodeLimit); return }
            guard relative.count < TransferPlan.maximumDepth else { issue(root, path, .depthLimit); return }
            guard entry.kind == .directory || entry.kind == .regularFile else {
                issue(root, path, .unsupportedType); return
            }
            do {
                try RemotePath.validateName(entry.rawName)
                guard try encoding.decode(entry.rawName) == entry.name,
                      !entry.name.contains(":"), !entry.name.contains("/"),
                      !entry.name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                    issue(root, path, .invalidName); return
                }
            } catch { issue(root, path, .invalidName); return }
            let relative = relative + [.init(name: entry.name, bytes: entry.rawName)]
            let target = relative.reduce(destination.url) { $0.appendingPathComponent($1.name) }
            let node = TransferPlan.Node(rootID: root, kind: entry.kind, source: .remote(path, encoding),
                target: .local(target), relativePath: relative, parentID: parent, size: entry.size,
                snapshot: .remote(kind: entry.kind, size: entry.size))
            nodes.append(node); discovered(nodes.count)
            guard entry.kind == .directory else { return }
            do {
                let listing = try await client.list(endpoint: endpoint, path: path, encoding: nil,
                                                     credentials: credentials, cancellation: cancellation)
                try cancellation.checkCancellation()
                var listingBytes = 0
                for child in listing.entries {
                    guard child.rawName.count <= TransferPlan.maximumListingBytes - listingBytes else {
                        issue(root, path, .listingLimit); return
                    }
                    listingBytes += child.rawName.count
                }
                var names = Set<Data>()
                for child in listing.entries.sorted(by: { $0.rawName.lexicographicallyPrecedes($1.rawName) }) {
                    guard names.insert(child.rawName).inserted else { issue(root, path, .duplicateTarget); continue }
                    let childPath: RemotePath
                    do { childPath = try path.appending(name: child.name, bytes: child.rawName) }
                    catch { issue(root, path, .invalidName); continue }
                    try await visit(child, path: childPath, encoding: listing.encoding,
                                    root: root, relative: relative, parent: node.id)
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                try cancellation.checkCancellation()
                issue(root, path, .unreadable)
            }
        }
        for (selection, root) in zip(selections, roots) {
            guard selection.path.components.last?.bytes == selection.entry.rawName else {
                issue(root.id, selection.path, .invalidName); continue
            }
            try await visit(selection.entry, path: selection.path, encoding: selection.encoding,
                            root: root.id, relative: [], parent: nil)
        }
        try cancellation.checkCancellation()
        try destination.validateIdentity()
        return TransferPlan(direction: .download, roots: roots, nodes: nodes, issues: issues)
    }
}
