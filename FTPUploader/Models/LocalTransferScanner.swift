import Foundation
import Darwin

/// One read-only phase, with fixed transport/authentication and predeclared plan lookups.
/// Never passed to execution. Only requested entries survive full-list validation.
@MainActor
final class PreviewListingCache {
    struct Lookup {
        let path: RemotePath
        let encoding: FTPTextEncoding?
        let rawName: Data
    }
    struct Match { let entry: RemoteEntry?; let encoding: FTPTextEncoding }
    private struct Key: Hashable {
        let transport: String
        let host: String
        let port: Int
        let authentication: UUID
        let generation: UUID
        let path: [Data]
        let encoding: String
    }
    private struct Context {
        let client: FTPServing
        let endpoint: FTPEndpoint
        let credentials: FTPCredentials
        let cancellation: FTPCancellationToken
        let targetInspection: Bool
    }
    private struct IndexedListing {
        let entries: [Data: RemoteEntry]
        let encoding: FTPTextEncoding
    }
    private let authentication = UUID()
    private var context: Context?
    private var requested: [Key: Set<Data>] = [:]
    private var listings: [Key: IndexedListing] = [:]
    private var failures: [Key: Error] = [:]
    private var inFlight: [Key: Task<IndexedListing, Error>] = [:]
    var cachedDirectoryCount: Int { listings.count }
    var retainedEntryCount: Int { listings.values.reduce(0) { $0 + $1.entries.count } }

    init(client: FTPServing, endpoint: FTPEndpoint, credentials: FTPCredentials,
         cancellation: FTPCancellationToken, lookups: [Lookup], targetInspection: Bool = false) throws {
        guard lookups.count <= TransferPlan.maximumNodes else { throw FTPError.localFile("预览核对清单超过限制。") }
        context = Context(client: client, endpoint: endpoint, credentials: credentials, cancellation: cancellation, targetInspection: targetInspection)
        for lookup in lookups {
            try RemotePath.validateName(lookup.rawName)
            requested[key(lookup, context: context!), default: []].insert(lookup.rawName)
        }
    }

    func close() {
        if !inFlight.isEmpty { context?.cancellation.cancel() }
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll(); listings.removeAll(); failures.removeAll(); requested.removeAll(); context = nil
    }

    private func key(_ lookup: Lookup, context: Context) -> Key {
        Key(transport: context.endpoint.transport.rawValue, host: context.endpoint.host, port: context.endpoint.port,
            authentication: authentication, generation: context.cancellation.id, path: lookup.path.components.map(\.bytes),
            encoding: lookup.encoding.map { $0 == .utf8 ? "utf8" : "gb18030" } ?? "automatic")
    }

    func match(_ lookup: Lookup) async throws -> Match {
        guard let context else { throw CancellationError() }
        do { try context.cancellation.checkCancellation() }
        catch { close(); throw error }
        let key = key(lookup, context: context)
        guard let names = requested[key], names.contains(lookup.rawName) else {
            throw FTPError.localFile("预览查询不属于本次固定清单。")
        }
        if let value = listings[key] { return Match(entry: value.entries[lookup.rawName], encoding: value.encoding) }
        if let error = failures[key] { throw error }
        let task: Task<IndexedListing, Error>
        if let pending = inFlight[key] { task = pending }
        else {
            task = Task {
                let listing: DirectoryListing
                if context.targetInspection {
                    guard let encoding = lookup.encoding else { throw FTPError.invalidName }
                    listing = try await context.client.listPreviewTargets(endpoint: context.endpoint, path: lookup.path,
                        encoding: encoding, credentials: context.credentials, cancellation: context.cancellation)
                } else {
                    listing = try await context.client.list(endpoint: context.endpoint, path: lookup.path,
                        encoding: lookup.encoding, credentials: context.credentials, cancellation: context.cancellation)
                }
                try context.cancellation.checkCancellation()
                return IndexedListing(entries: try listing.indexed(names: names, cancellation: context.cancellation), encoding: listing.encoding)
            }
            inFlight[key] = task
        }
        defer { inFlight.removeValue(forKey: key) }
        do {
            let value = try await task.value
            try context.cancellation.checkCancellation()
            guard self.context != nil else { throw CancellationError() }
            listings[key] = value
            return Match(entry: value.entries[lookup.rawName], encoding: value.encoding)
        } catch {
            if context.cancellation.isCancelled || error is CancellationError { close(); throw CancellationError() }
            if self.context != nil { failures[key] = error }
            throw error
        }
    }
}

/// Retry refreshes a fixed confirmed list, never enumerates a source tree.
struct TransferRetryPlanner {
    static func remap(_ plan: TransferPlan) -> TransferPlan {
        let rootIDs = Dictionary(uniqueKeysWithValues: plan.roots.map { ($0.id, UUID()) })
        let nodeIDs = Dictionary(uniqueKeysWithValues: plan.nodes.map { ($0.id, UUID()) })
        return TransferPlan(direction: plan.direction,
            roots: plan.roots.map { .init(id: rootIDs[$0.id]!, source: $0.source, kind: $0.kind) },
            nodes: plan.nodes.map { node in
                .init(id: nodeIDs[node.id]!, rootID: rootIDs[node.rootID]!, kind: node.kind,
                      source: node.source, target: node.target, relativePath: node.relativePath,
                      parentID: node.parentID.flatMap { nodeIDs[$0] }, size: node.size, snapshot: node.snapshot)
            })
    }

    func upload(_ plan: TransferPlan, sources: [UUID: LocalSourceRoot],
                cancellation: FTPCancellationToken) async throws -> TransferPlan {
        let leases = try sources.mapValues { try $0.lease() }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    var nodes: [TransferPlan.Node] = []
                    var directories: [UUID: [[String]: (UInt64, UInt64)]] = [:]
                    for node in plan.nodes {
                        try cancellation.checkCancellation()
                        guard let root = sources[node.rootID], leases[node.rootID] != nil,
                              case .local = node.source else {
                            throw FTPError.localFile("重试来源根与清单不符。")
                        }
                        try root.validateIdentity()
                        let path = node.relativePath.dropFirst().map(\.name)
                        var known = directories[node.rootID] ?? [:]
                        if root.identity.kind == .directory {
                            known[[]] = (root.identity.device, root.identity.inode)
                        }
                        if node.kind == .directory, let name = path.last {
                            let parent = try SelectedLocalFile.openSource(root: root, path: Array(path.dropLast()),
                                directories: known, directory: true)
                            defer { Darwin.close(parent) }
                            var value = stat()
                            guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0,
                                  value.st_mode & S_IFMT == S_IFDIR else {
                                throw FTPError.localFile("重试目录消失或类型变化。")
                            }
                            known[path] = (UInt64(value.st_dev), UInt64(value.st_ino))
                        }
                        let fd = try SelectedLocalFile.openSource(root: root, path: path, directories: known,
                                                                 directory: node.kind == .directory)
                        defer { Darwin.close(fd) }
                        let snapshot: TransferPlan.SourceSnapshot
                        let size: Int64?
                        if node.kind == .directory {
                            var value = stat()
                            guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else {
                                throw FTPError.localFile("重试来源类型变化。")
                            }
                            snapshot = .localDirectory(device: UInt64(value.st_dev), inode: UInt64(value.st_ino))
                            size = nil; directories[node.rootID] = known
                        } else {
                            let value = try SelectedLocalFile.snapshot(descriptor: fd, cancellation: cancellation)
                            snapshot = .localFile(value); size = value.size
                        }
                        let checked = try SelectedLocalFile.openSource(root: root, path: path, directories: known,
                                                                      directory: node.kind == .directory)
                        defer { Darwin.close(checked) }
                        var before = stat(), after = stat()
                        guard fstat(fd, &before) == 0, fstat(checked, &after) == 0,
                              LocalRootIdentity(before) == LocalRootIdentity(after) else {
                            throw FTPError.localFile("重试核对期间来源被替换。")
                        }
                        nodes.append(.init(id: node.id, rootID: node.rootID, kind: node.kind, source: node.source,
                            target: node.target, relativePath: node.relativePath, parentID: node.parentID,
                            size: size, snapshot: snapshot))
                    }
                    try cancellation.checkCancellation()
                    try leases.values.forEach { try $0.owner.validateIdentity() }
                    continuation.resume(returning: TransferPlan(id: plan.id, direction: .upload, roots: plan.roots, nodes: nodes))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    @MainActor
    func inspectTargets(_ plan: TransferPlan, client: FTPServing, endpoint: FTPEndpoint,
                        credentials: FTPCredentials, destination: LocalDestinationRoot?,
                        cancellation: FTPCancellationToken) async throws -> TransferPlan {
        let lookups = try plan.nodes.compactMap { node -> PreviewListingCache.Lookup? in
            guard case .remote(let path, let encoding) = node.target else { return nil }
            guard let parent = path.parent, let name = path.components.last,
                  try encoding.encode(name.name) == name.bytes else { throw FTPError.invalidName }
            return .init(path: parent, encoding: encoding, rawName: name.bytes)
        }
        let cache = try PreviewListingCache(client: client, endpoint: endpoint, credentials: credentials,
            cancellation: cancellation, lookups: lookups, targetInspection: true)
        defer { cache.close() }
        var missing = Set<UUID>(), existing = Set<UUID>(), issues = plan.issues
        let local = try destination.map { try LocalDestinationService(root: $0) }
        for node in plan.nodes {
            try cancellation.checkCancellation()
            if let parent = node.parentID, missing.contains(parent) {
                if node.kind == .directory { missing.insert(node.id) }
                continue
            }
            let kind: RemoteEntry.Kind?
            switch node.target {
            case .remote(let path, let encoding):
                guard let parent = path.parent, let name = path.components.last else { throw FTPError.invalidName }
                let match = try await cache.match(.init(path: parent, encoding: encoding, rawName: name.bytes))
                kind = match.entry?.kind
            case .local:
                guard let local else { throw FTPError.localFile("重试目的根未授权。") }
                kind = try local.targetKind(node.relativePath.map(\.name))
            }
            if let kind {
                existing.insert(node.id)
                if kind != node.kind {
                    issues.append(.init(rootID: node.rootID, nodeID: node.id,
                        path: node.relativePath.map(\.name).joined(separator: "/"), reason: .typeConflict))
                    // Do not traverse a conflicting directory target.
                    if node.kind == .directory { missing.insert(node.id) }
                }
            } else if node.kind == .directory { missing.insert(node.id) }
        }
        try cancellation.checkCancellation()
        return TransferPlan(id: plan.id, direction: plan.direction, roots: plan.roots, nodes: plan.nodes,
                            issues: issues, existingTargetIDs: existing)
    }

    @MainActor
    func download(_ plan: TransferPlan, client: FTPServing, endpoint: FTPEndpoint,
                  credentials: FTPCredentials, cancellation: FTPCancellationToken) async throws -> TransferPlan {
        let lookups = try plan.nodes.map { node -> PreviewListingCache.Lookup in
            guard case .remote(let path, let encoding) = node.source,
                  let parent = path.parent, let name = path.components.last else { throw FTPError.invalidName }
            return .init(path: parent, encoding: encoding, rawName: name.bytes)
        }
        let cache = try PreviewListingCache(client: client, endpoint: endpoint, credentials: credentials,
            cancellation: cancellation, lookups: lookups)
        defer { cache.close() }
        var nodes: [TransferPlan.Node] = []
        for node in plan.nodes {
            try cancellation.checkCancellation()
            guard case .remote(let path, let encoding) = node.source,
                  let parent = path.parent, let name = path.components.last else { throw FTPError.invalidName }
            let match = try await cache.match(.init(path: parent, encoding: encoding, rawName: name.bytes))
            try cancellation.checkCancellation()
            guard let entry = match.entry, entry.kind == node.kind,
                  try match.encoding.decode(entry.rawName) == name.name else {
                throw FTPError.localFile("重试来源消失、重名、编码或类型变化。")
            }
            nodes.append(.init(id: node.id, rootID: node.rootID, kind: node.kind,
                source: .remote(path, match.encoding), target: node.target, relativePath: node.relativePath,
                parentID: node.parentID, size: entry.size, snapshot: .remote(kind: entry.kind, size: entry.size)))
        }
        try cancellation.checkCancellation()
        return TransferPlan(id: plan.id, direction: .download, roots: plan.roots, nodes: nodes)
    }
}

/// Serial background, read-only scanner. The caller retains selected-root authorization
/// through preview/execution; this operation additionally retains it until scanning stops.
struct LocalTransferScanner {
    func scan(roots: [LocalSourceRoot], destination: RemotePath, encoding: FTPTextEncoding,
              cancellation: FTPCancellationToken, discovered: @escaping (Int) -> Void = { _ in }) async throws -> TransferPlan {
        let leases = try roots.map { try $0.lease() }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    var worker = Worker(leases: leases, destination: destination, encoding: encoding, cancellation: cancellation, discovered: discovered)
                    continuation.resume(returning: try worker.scan())
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private struct Worker {
        let leases: [LocalRootAccess.Lease]
        let destination: RemotePath
        let encoding: FTPTextEncoding
        let cancellation: FTPCancellationToken
        let discovered: (Int) -> Void
        var nodes: [TransferPlan.Node] = []
        var issues: [TransferPlan.Issue] = []
        var visited = Set<LocalIdentityKey>()
        struct LocalIdentityKey: Hashable { let device: UInt64; let inode: UInt64 }

        mutating func scan() throws -> TransferPlan {
            let selections = leases.map { TransferPlan.Root(source: .local($0.owner.url), kind: $0.owner.identity.kind) }
            for (lease, selection) in zip(leases, selections) {
                let root = lease.owner
                try cancellation.checkCancellation()
                do {
                    try root.validateIdentity()
                    try visit(lease.descriptor, url: root.url, root: selection, relative: [], parent: nil)
                    try root.validateIdentity()
                } catch is CancellationError { throw CancellationError() }
                catch { issue(selection.id, nil, root.url, .changedSource) }
            }
            try cancellation.checkCancellation()
            return TransferPlan(direction: .upload, roots: selections, nodes: nodes, issues: issues)
        }

        mutating func issue(_ root: UUID, _ node: UUID?, _ url: URL, _ reason: TransferPlan.Issue.Reason) {
            issues.append(.init(rootID: root, nodeID: node, path: url.path, reason: reason))
        }

        mutating func visit(_ fd: Int32, url: URL, root: TransferPlan.Root,
                            relative: [RemotePath.Component], parent: UUID?) throws {
            try cancellation.checkCancellation()
            guard nodes.count < TransferPlan.maximumNodes else { issue(root.id, nil, url, .nodeLimit); return }
            guard relative.count < TransferPlan.maximumDepth else { issue(root.id, nil, url, .depthLimit); return }
            var value = stat()
            guard fstat(fd, &value) == 0 else { issue(root.id, nil, url, .unreadable); return }
            let identity = LocalRootIdentity(value)
            guard identity.kind == .regularFile || identity.kind == .directory else {
                issue(root.id, nil, url, .unsupportedType); return
            }
            let component: RemotePath.Component
            do {
                let name = url.lastPathComponent
                let bytes = try encoding.encode(name)
                try RemotePath.validateName(bytes)
                component = .init(name: name, bytes: bytes)
            } catch { issue(root.id, nil, url, .invalidName); return }
            let path = relative + [component]
            let target = RemotePath(components: destination.components + path)
            let snapshot: TransferPlan.SourceSnapshot
            if identity.kind == .directory {
                guard visited.insert(LocalIdentityKey(device: identity.device, inode: identity.inode)).inserted else {
                    issue(root.id, nil, url, .cycle); return
                }
                snapshot = .localDirectory(device: identity.device, inode: identity.inode)
            } else {
                do { snapshot = .localFile(try SelectedLocalFile.snapshot(descriptor: fd, cancellation: cancellation)) }
                catch is CancellationError { throw CancellationError() }
                catch { issue(root.id, nil, url, .changedSource); return }
            }
            let node = TransferPlan.Node(rootID: root.id, kind: identity.kind, source: .local(url),
                target: .remote(target, encoding), relativePath: path, parentID: parent,
                size: identity.kind == .regularFile ? value.st_size : nil, snapshot: snapshot)
            nodes.append(node); discovered(nodes.count)
            guard identity.kind == .directory else { return }
            let names: [Data]
            do { names = try directoryNames(fd) }
            catch is CancellationError { throw CancellationError() }
            catch ScanFailure.nodeLimit { issue(root.id, node.id, url, .nodeLimit); return }
            catch ScanFailure.listingLimit { issue(root.id, node.id, url, .listingLimit); return }
            catch { issue(root.id, node.id, url, .unreadable); return }
            for bytes in names.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                try cancellation.checkCancellation()
                guard let name = String(data: bytes, encoding: .utf8) else {
                    issue(root.id, node.id, url, .invalidName); continue
                }
                let child = url.appendingPathComponent(name)
                var before = stat()
                let checked = name.withCString { fstatat(fd, $0, &before, AT_SYMLINK_NOFOLLOW) }
                guard checked == 0 else { issue(root.id, node.id, child, .unreadable); continue }
                let childIdentity = LocalRootIdentity(before)
                guard childIdentity.kind == .directory || childIdentity.kind == .regularFile else {
                    issue(root.id, node.id, child, .unsupportedType); continue
                }
                let childFD = name.withCString { openat(fd, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
                guard childFD >= 0 else { issue(root.id, node.id, child, .unreadable); continue }
                defer { Darwin.close(childFD) }
                var opened = stat()
                guard fstat(childFD, &opened) == 0, LocalRootIdentity(opened) == childIdentity else {
                    issue(root.id, node.id, child, .changedSource); continue
                }
                try visit(childFD, url: child, root: root, relative: path, parent: node.id)
                var after = stat()
                guard name.withCString({ fstatat(fd, $0, &after, AT_SYMLINK_NOFOLLOW) }) == 0,
                      LocalRootIdentity(after) == childIdentity else {
                    issue(root.id, node.id, child, .changedSource); continue
                }
            }
            var after = stat()
            if fstat(fd, &after) != 0 || LocalRootIdentity(after) != identity ||
               value.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec || value.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec {
                issue(root.id, node.id, url, .changedSource)
            }
        }

        enum ScanFailure: Error { case listingLimit, nodeLimit }
        func directoryNames(_ fd: Int32) throws -> [Data] {
            let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard copy >= 0 else { throw FTPError.localFile("无法读取来源目录。") }
            guard let directory = fdopendir(copy) else {
                Darwin.close(copy); throw FTPError.localFile("无法读取来源目录。")
            }
            defer { closedir(directory) }
            rewinddir(directory)
            var names: [Data] = []
            var totalBytes = 0
            while true {
                try cancellation.checkCancellation()
                errno = 0
                guard let entry = readdir(directory) else {
                    guard errno == 0 else { throw FTPError.localFile("来源目录列表不完整。") }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: UInt8.self, capacity: Int(entry.pointee.d_namlen)) {
                        Data(bytes: $0, count: Int(entry.pointee.d_namlen))
                    }
                }
                if name != Data(".".utf8) && name != Data("..".utf8) {
                    guard name.count <= TransferPlan.maximumListingBytes - totalBytes else { throw ScanFailure.listingLimit }
                    totalBytes += name.count
                    names.append(name)
                    guard names.count <= TransferPlan.maximumNodes else { throw ScanFailure.nodeLimit }
                }
            }
            return names
        }
    }
}
