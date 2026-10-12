import Foundation
import CryptoKit
import Darwin

// Only a file authorization and a digest are serializable, never key bytes.
struct PrivateKeyReference: Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let bookmark: Data
    let name: String
    let digest: Data
    var description: String { "PrivateKeyReference([redacted])" }
    var debugDescription: String { description }
}

final class PrivateKeyMaterial: CustomStringConvertible, CustomDebugStringConvertible, Sendable {
    let bytes: Data
    let digest: Data
    init(_ bytes: Data) { self.bytes = bytes; digest = Data(SHA256.hash(data: bytes)) }
    var description: String { "PrivateKeyMaterial([redacted])" }
    var debugDescription: String { description }
}

protocol PrivateKeyAccessing {
    func read(_ url: URL) throws -> PrivateKeyMaterial
    func bookmark(_ url: URL) throws -> Data
    func resolve(_ bookmark: Data) throws -> URL
}

final class PrivateKeyAccess: PrivateKeyAccessing {
    static let limit = 1024 * 1024
    private let start: (URL) -> Bool
    private let stop: (URL) -> Void
    private let create: (URL) throws -> Data
    private let restore: (Data) throws -> (URL, Bool)
    private let readBytes: (FileHandle, Int) throws -> Data
    private let openFile: (URL, Int32) throws -> Int32

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; mode = value.st_mode
            size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
        }
    }
    /// Search-only ancestor descriptors never enumerate directories or broaden scope.
    /// Initial path aliases may resolve, but their identities and the real chain are pinned.
    private struct Ancestors {
        let originalPaths: [(String, LocalRootIdentity)]
        let components: [String]
        let identities: [LocalRootIdentity]

        init(parent: URL) throws {
            let path = parent.path
            let parts = path.split(separator: "/").map(String.init)
            var paths: [(String, LocalRootIdentity)] = []
            for count in 0...parts.count {
                let prefix = "/" + parts.prefix(count).joined(separator: "/")
                paths.append((prefix, try Self.pathIdentity(prefix)))
            }
            let resolved = path.withCString { realpath($0, nil) }
            guard let resolved else { throw PrivateKeyAccess.changed() }
            defer { free(resolved) }
            // Use POSIX bytes: Foundation may shorten /private/var to /var again.
            components = String(cString: resolved).split(separator: "/").map(String.init)
            identities = try Self.walk(components)
            originalPaths = paths
            try validate()
        }
        private static func pathIdentity(_ path: String) throws -> LocalRootIdentity {
            var value = stat()
            guard path.withCString({ lstat($0, &value) }) == 0,
                  value.st_mode & S_IFMT == S_IFDIR || value.st_mode & S_IFMT == S_IFLNK else {
                throw PrivateKeyAccess.changed()
            }
            return LocalRootIdentity(value)
        }
        private static func walk(_ components: [String]) throws -> [LocalRootIdentity] {
            var fd = Darwin.open("/", O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw PrivateKeyAccess.changed() }
            defer { Darwin.close(fd) }
            func identity() throws -> LocalRootIdentity {
                var value = stat()
                guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { throw PrivateKeyAccess.changed() }
                return LocalRootIdentity(value)
            }
            var result = [try identity()]
            for name in components {
                let next = name.withCString { openat(fd, $0, O_SEARCH | O_NOFOLLOW | O_CLOEXEC) }
                guard next >= 0 else { throw PrivateKeyAccess.changed() }
                Darwin.close(fd); fd = next
                result.append(try identity())
            }
            return result
        }
        func validate() throws {
            for (path, expected) in originalPaths {
                guard try Self.pathIdentity(path) == expected else { throw PrivateKeyAccess.changed() }
            }
            guard try Self.walk(components) == identities else { throw PrivateKeyAccess.changed() }
        }
    }
    private static func changed() -> FieldIssue {
        FieldIssue(field: .privateKey, message: "读取期间私钥发生变化，请重新选择。")
    }
    private static func validate(_ value: stat) throws -> FileIdentity {
        guard value.st_mode & S_IFMT == S_IFREG, value.st_size > 0, value.st_size <= limit else {
            throw FieldIssue(field: .privateKey, message: "请选择非空、可读且不超过 1 MiB 的普通私钥文件。")
        }
        return FileIdentity(value)
    }
    private static func pathIdentity(_ url: URL) throws -> FileIdentity {
        var value = stat()
        guard url.withUnsafeFileSystemRepresentation({ $0.map { lstat($0, &value) } ?? -1 }) == 0 else { throw changed() }
        return try validate(value)
    }
    private static func descriptorIdentity(_ descriptor: Int32) throws -> FileIdentity {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw changed() }
        return try validate(value)
    }
    init(start: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stop: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
         create: @escaping (URL) throws -> Data = { try $0.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) },
         restore: @escaping (Data) throws -> (URL, Bool) = { bookmark in
             var stale = false
             let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
             return (url, stale)
         }, readBytes: @escaping (FileHandle, Int) throws -> Data = { try $0.read(upToCount: $1) ?? Data() },
         openFile: @escaping (URL, Int32) throws -> Int32 = { url, flags in
             url.withUnsafeFileSystemRepresentation { $0.map { Darwin.open($0, flags) } ?? -1 }
         }) {
        self.start = start; self.stop = stop; self.create = create; self.restore = restore; self.readBytes = readBytes
        self.openFile = openFile
    }
    func read(_ url: URL) throws -> PrivateKeyMaterial {
        let scoped = start(url)
        defer { if scoped { stop(url) } }
        do {
            guard url.isFileURL else { throw Self.changed() }
            let initial = try Self.pathIdentity(url)
            let ancestors = try Ancestors(parent: url.deletingLastPathComponent())
            let descriptor = try openFile(url, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw Self.changed() }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            guard try Self.descriptorIdentity(descriptor) == initial else { throw Self.changed() }
            try ancestors.validate()
            // One extra byte detects growth; each allocation and the final buffer are bounded.
            var bytes = Data()
            while bytes.count <= Self.limit {
                let requested = min(64 * 1024, Self.limit + 1 - bytes.count)
                let chunk = try readBytes(handle, requested)
                guard chunk.count <= requested else { throw Self.changed() }
                if chunk.isEmpty { break }
                bytes.append(chunk)
            }
            guard bytes.count == initial.size, bytes.count <= Self.limit,
                  try Self.descriptorIdentity(descriptor) == initial,
                  try Self.pathIdentity(url) == initial else { throw Self.changed() }
            try ancestors.validate()
            guard let text = String(data: bytes, encoding: .utf8),
                  ["-----BEGIN OPENSSH PRIVATE KEY-----", "-----BEGIN RSA PRIVATE KEY-----",
                   "-----BEGIN PRIVATE KEY-----", "-----BEGIN ENCRYPTED PRIVATE KEY-----"].contains(where: { text.hasPrefix($0) }) else {
                throw FieldIssue(field: .privateKey, message: "私钥格式不支持或文件损坏。支持 OpenSSH Ed25519/RSA 和 PEM RSA；不能选择公钥文件。")
            }
            if text.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") {
                let body = text.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
                guard let decoded = Data(base64Encoded: body), Self.supportedOpenSSH(decoded) else {
                    throw FieldIssue(field: .privateKey, message: "OpenSSH 私钥损坏或类型不支持。支持 Ed25519 和 RSA。")
                }
            }
            return PrivateKeyMaterial(bytes)
        } catch let issue as FieldIssue { throw issue }
        catch { throw FieldIssue(field: .privateKey, message: "无法读取私钥，请重新选择文件并检查访问权限。") }
    }
    private static func supportedOpenSSH(_ data: Data) -> Bool {
        let magic = Data("openssh-key-v1\0".utf8)
        guard data.starts(with: magic) else { return false }
        var offset = magic.count
        func string() -> Data? {
            guard offset + 4 <= data.count else { return nil }
            let length = data[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) }; offset += 4
            guard length <= data.count - offset else { return nil }
            defer { offset += length }
            return Data(data[offset..<offset+length])
        }
        guard string() != nil, string() != nil, string() != nil, offset + 4 <= data.count else { return false }
        let keys = data[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) }; offset += 4
        guard keys == 1, let publicKey = string(), publicKey.count >= 4 else { return false }
        let length = publicKey.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length <= publicKey.count - 4 else { return false }
        return ["ssh-rsa", "ssh-ed25519"].contains(String(decoding: publicKey[4..<4+length], as: UTF8.self))
    }
    func bookmark(_ url: URL) throws -> Data {
        let scoped = start(url)
        defer { if scoped { stop(url) } }
        do { return try create(url) }
        catch { throw FieldIssue(field: .privateKey, message: "无法保存私钥文件授权，请重新选择。") }
    }
    func resolve(_ bookmark: Data) throws -> URL {
        do {
            let (url, stale) = try restore(bookmark)
            guard !stale else { throw FieldIssue(field: .privateKey, message: "私钥文件授权已失效，请重新选择。") }
            return url
        } catch let issue as FieldIssue { throw issue }
        catch { throw FieldIssue(field: .privateKey, message: "无法恢复私钥文件授权，请重新选择。") }
    }
}

struct PrivateKeySelection: CustomStringConvertible, CustomDebugStringConvertible {
    let url: URL
    let digest: Data
    var name: String { url.lastPathComponent }
    var description: String { "PrivateKeySelection([redacted])" }
    var debugDescription: String { description }
    static func select(_ url: URL, access: PrivateKeyAccessing = PrivateKeyAccess()) throws -> Self {
        let material = try access.read(url)
        return Self(url: url, digest: material.digest)
    }
    func material(access: PrivateKeyAccessing = PrivateKeyAccess()) throws -> PrivateKeyMaterial {
        let material = try access.read(url)
        guard material.digest == digest else { throw FieldIssue(field: .privateKey, message: "私钥内容已变化，请重新选择以确认新密钥，并重新输入口令。") }
        return material
    }
    func reference(access: PrivateKeyAccessing = PrivateKeyAccess()) throws -> PrivateKeyReference {
        _ = try material(access: access)
        return PrivateKeyReference(bookmark: try access.bookmark(url), name: name, digest: digest)
    }
}
