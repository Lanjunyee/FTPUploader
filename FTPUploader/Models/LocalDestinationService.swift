import Foundation
import Darwin

/// Directory work is anchored to selected-root descriptors, never to a concatenated write path.
@MainActor
final class LocalDestinationService {
    enum DirectoryResult: Equatable { case created, reused }
    final class Parent {
        let descriptor: Int32
        let relativePath: [String]
        let identity: LocalRootIdentity
        private let lease: LocalRootAccess.Lease
        fileprivate init(descriptor: Int32, path: [String], identity: LocalRootIdentity, lease: LocalRootAccess.Lease) {
            self.descriptor = descriptor; relativePath = path; self.identity = identity; self.lease = lease
        }
        deinit { Darwin.close(descriptor) }
    }
    private let root: LocalDestinationRoot
    private let ancestors: [(String, LocalRootIdentity)]
    private var knownDirectories: [[String]: LocalRootIdentity] = [:]
    private let beforeMutation: (() throws -> Void)?

    init(root: LocalDestinationRoot, beforeMutation: (() throws -> Void)? = nil) throws {
        self.root = root; self.beforeMutation = beforeMutation
        try root.validateIdentity()
        // Resolve only the selected root's initial path aliases, then pin every real ancestor
        // with no-follow descriptors and verify the endpoint is the already-authorized inode.
        let resolved = root.url.withUnsafeFileSystemRepresentation { name in name.flatMap { realpath($0, nil) } }
        guard let resolved else { throw Self.failure() }
        defer { free(resolved) }
        // Foundation canonical URLs shorten /private/var back to /var; use the POSIX bytes.
        let components = String(cString: resolved).split(separator: "/").map(String.init)
        var fd = Darwin.open("/", O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure() }
        defer { Darwin.close(fd) }
        var ancestry: [(String, LocalRootIdentity)] = []
        for name in components {
            let next = name.withCString { openat(fd, $0, O_SEARCH | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else { throw Self.failure() }
            Darwin.close(fd); fd = next
            ancestry.append((name, try Self.identity(fd)))
        }
        guard try Self.identity(fd) == root.identity else { throw Self.failure() }
        ancestors = ancestry
        knownDirectories[[]] = root.identity
    }

    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"),
              name.utf8.count <= 255,
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw FTPError.localFile("名称不能安全映射到本地目的根。")
        }
    }
    private static func failure() -> FTPError { .localFile("保存根或目录祖先发生变化、是链接或类型不符，未继续写入。") }
    private static func identity(_ fd: Int32) throws -> LocalRootIdentity {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { throw failure() }
        return LocalRootIdentity(value)
    }

    private func validateRoot() throws {
        try root.validateIdentity()
        var fd = Darwin.open("/", O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure() }
        defer { Darwin.close(fd) }
        for (name, expected) in ancestors {
            let next = name.withCString { openat(fd, $0, O_SEARCH | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else { throw Self.failure() }
            Darwin.close(fd); fd = next
            guard try Self.identity(fd) == expected else { throw Self.failure() }
        }
    }

    private func openDirectory(_ path: [String]) throws -> Parent {
        try path.forEach(Self.validateName)
        let lease = try root.lease()
        try validateRoot()
        var fd = dup(lease.descriptor)
        guard fd >= 0 else { throw Self.failure() }
        var handedOff = false
        defer { if !handedOff { Darwin.close(fd) } }
        var prefix: [String] = []
        for name in path {
            let next = name.withCString { openat(fd, $0, O_SEARCH | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else { throw Self.failure() }
            Darwin.close(fd); fd = next
            prefix.append(name)
            let identity = try Self.identity(fd)
            if let expected = knownDirectories[prefix], expected != identity { throw Self.failure() }
            knownDirectories[prefix] = identity
        }
        let result = Parent(descriptor: fd, path: path, identity: try Self.identity(fd), lease: lease)
        handedOff = true
        return result
    }

    /// Snapshot existing ancestors during preparation. This method is read-only.
    func prepareDirectory(_ path: [String]) throws { _ = try openDirectory(path) }
    func parent(of path: [String]) throws -> Parent {
        guard let name = path.last else { throw Self.failure() }
        try Self.validateName(name)
        return try openDirectory(Array(path.dropLast()))
    }
    func validate(_ parent: Parent) throws {
        let current = try openDirectory(parent.relativePath)
        guard current.identity == parent.identity, try Self.identity(parent.descriptor) == parent.identity else {
            throw Self.failure()
        }
    }

    /// Read-only type inspection for retry previews; missing parents are tracked by the caller.
    func targetKind(_ path: [String]) throws -> RemoteEntry.Kind? {
        let parent = try self.parent(of: path)
        var value = stat()
        guard fstatat(parent.descriptor, path.last!, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw Self.failure()
        }
        let kind = LocalRootIdentity(value).kind
        if kind == .directory { try prepareDirectory(path) }
        try validate(parent)
        return kind
    }

    func fileIdentity(_ path: [String]) throws -> LocalDownload.Identity? {
        let parent = try self.parent(of: path)
        return try LocalDownload.Anchor.identity(fd: parent.descriptor, name: path.last!)
    }

    /// Missing parents are not created here; directory tasks must have completed first.
    func download(_ path: [String], authorizedIdentity: LocalDownload.Identity? = nil,
                  write: @escaping (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) },
                  close: @escaping (FileHandle) throws -> Void = { try $0.synchronize(); try $0.close() },
                  operations: LocalDownload.Anchor.Operations = .init()) throws -> LocalDownload {
        let parent = try self.parent(of: path)
        try beforeMutation?()
        try validate(parent)
        let destination = path.reduce(root.url) { $0.appendingPathComponent($1) }
        let anchor = try LocalDownload.Anchor(destination: destination, parentDescriptor: parent.descriptor,
            validateParent: { try self.validate(parent) }, operations: operations)
        return try LocalDownload(destination: destination, anchor: anchor, authorizedIdentity: authorizedIdentity,
                                 write: write, close: close)
    }

    /// Only creates the named node. Missing parents must be explicit preceding directory tasks.
    func createDirectory(_ path: [String]) throws -> DirectoryResult {
        guard let name = path.last else { throw Self.failure() }
        try Self.validateName(name)
        let parent = try self.parent(of: path)
        try beforeMutation?()
        try validate(parent)
        var value = stat()
        let existing = name.withCString { fstatat(parent.descriptor, $0, &value, AT_SYMLINK_NOFOLLOW) }
        if existing == 0 {
            let identity = LocalRootIdentity(value)
            guard identity.kind == .directory else { throw Self.failure() }
            if let expected = knownDirectories[path], expected != identity { throw Self.failure() }
            knownDirectories[path] = identity
            return .reused
        }
        guard errno == ENOENT else { throw Self.failure() }
        let created = name.withCString { mkdirat(parent.descriptor, $0, 0o755) }
        if created != 0 && errno != EEXIST { throw Self.failure() }
        let child = name.withCString { openat(parent.descriptor, $0, O_SEARCH | O_NOFOLLOW | O_CLOEXEC) }
        guard child >= 0 else { throw Self.failure() }
        defer { Darwin.close(child) }
        let identity = try Self.identity(child)
        if let expected = knownDirectories[path], expected != identity { throw Self.failure() }
        try validate(parent)
        knownDirectories[path] = identity
        return created == 0 ? .created : .reused
    }
}
