import Foundation
import Darwin

struct LocalRootIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let kind: RemoteEntry.Kind
    init(_ value: stat) {
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
        switch value.st_mode & S_IFMT {
        case S_IFREG: kind = .regularFile
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symbolicLink
        default: kind = .other
        }
    }
}

/// An injected pair is useful for verifying the exact selected-root authorization lifetime.
struct LocalSecurityScope {
    let start: (URL) -> Bool
    let stop: (URL) -> Void
    static let system = LocalSecurityScope(start: { $0.startAccessingSecurityScopedResource() },
                                          stop: { $0.stopAccessingSecurityScopedResource() })
}

/// Memory-only ownership of a selected root and its no-follow descriptor. Never a bookmark.
/// Retain this object through scanning, preview, pauses and execution; release only after cleanup.
class LocalRootAccess: @unchecked Sendable {
    let url: URL
    let identity: LocalRootIdentity
    private let scope: LocalSecurityScope
    private let hasScope: Bool
    private let lock = NSLock()
    private var storage: Int32
    private var users = 0
    private var closing = false
    var descriptor: Int32 { lock.lock(); defer { lock.unlock() }; return storage }

    /// Immutable descriptor lease; its strong owner and usage count defer scope release.
    final class Lease: @unchecked Sendable {
        let descriptor: Int32
        let owner: LocalRootAccess
        fileprivate init(owner: LocalRootAccess, descriptor: Int32) {
            self.owner = owner; self.descriptor = descriptor
        }
        deinit { owner.releaseLease() }
    }

    func lease() throws -> Lease {
        lock.lock(); defer { lock.unlock() }
        guard !closing, storage >= 0 else { throw FTPError.localFile("根授权已释放。") }
        users += 1
        return Lease(owner: self, descriptor: storage)
    }

    fileprivate init(url: URL, destination: Bool, scope: LocalSecurityScope) throws {
        guard url.isFileURL else { throw FTPError.localFile("请选择本地文件或目录。") }
        self.url = url
        self.scope = scope
        hasScope = scope.start(url)
        let fd = url.withUnsafeFileSystemRepresentation { name -> Int32 in
            guard let name else { return -1 }
            return Darwin.open(name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        var value = stat()
        guard fd >= 0, fstat(fd, &value) == 0 else {
            if fd >= 0 { Darwin.close(fd) }
            if hasScope { scope.stop(url) }
            throw FTPError.localFile("无法读取所选根，或根是符号链接。")
        }
        let identity = LocalRootIdentity(value)
        guard identity.kind == .directory || (!destination && identity.kind == .regularFile) else {
            Darwin.close(fd)
            if hasScope { scope.stop(url) }
            throw FTPError.localFile(destination ? "请选择普通目录作为保存根。" : "来源必须是普通文件或目录。")
        }
        self.identity = identity
        storage = fd
    }

    func validateIdentity() throws {
        lock.lock(); defer { lock.unlock() }
        var opened = stat(), current = stat()
        guard storage >= 0, fstat(storage, &opened) == 0,
              url.withUnsafeFileSystemRepresentation({ name in name.map { lstat($0, &current) } ?? -1 }) == 0,
              LocalRootIdentity(opened) == identity, LocalRootIdentity(current) == identity else {
            throw FTPError.localFile("所选根已变化或授权已释放，请重新选择。")
        }
    }

    /// Requests release without blocking the main thread; active leases defer actual cleanup.
    func endAccess() {
        lock.lock()
        closing = true
        let fd = takeClosingDescriptor()
        lock.unlock()
        closeAndStop(fd)
    }
    private func releaseLease() {
        lock.lock()
        users -= 1
        let fd = takeClosingDescriptor()
        lock.unlock()
        closeAndStop(fd)
    }
    private func takeClosingDescriptor() -> Int32 {
        guard closing, users == 0, storage >= 0 else { return -1 }
        let fd = storage; storage = -1
        return fd
    }
    private func closeAndStop(_ fd: Int32) {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        if hasScope { scope.stop(url) }
    }
    deinit { endAccess() }
}

final class LocalSourceRoot: LocalRootAccess, @unchecked Sendable {
    init(url: URL, scope: LocalSecurityScope = .system) throws {
        try super.init(url: url, destination: false, scope: scope)
    }
}

final class LocalDestinationRoot: LocalRootAccess, @unchecked Sendable {
    init(url: URL, scope: LocalSecurityScope = .system) throws {
        try super.init(url: url, destination: true, scope: scope)
    }
}
