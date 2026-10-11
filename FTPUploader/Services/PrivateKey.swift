import Foundation
import CryptoKit

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
    init(start: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stop: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
         create: @escaping (URL) throws -> Data = { try $0.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) },
         restore: @escaping (Data) throws -> (URL, Bool) = { bookmark in
             var stale = false
             let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
             return (url, stale)
         }, readBytes: @escaping (FileHandle, Int) throws -> Data = { try $0.read(upToCount: $1) ?? Data() }) {
        self.start = start; self.stop = stop; self.create = create; self.restore = restore; self.readBytes = readBytes
    }
    func read(_ url: URL) throws -> PrivateKeyMaterial {
        let scoped = start(url)
        defer { if scoped { stop(url) } }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= Self.limit else {
                throw FieldIssue(field: .privateKey, message: "请选择非空、可读且不超过 1 MiB 的普通私钥文件。")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let bytes = try readBytes(handle, Self.limit + 1)
            let after = try FileManager.default.attributesOfItem(atPath: url.path)
            guard bytes.count == size.intValue, bytes.count <= Self.limit,
                  attributes[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber,
                  attributes[.modificationDate] as? Date == after[.modificationDate] as? Date,
                  after[.size] as? NSNumber == size else {
                throw FieldIssue(field: .privateKey, message: "读取期间私钥发生变化，请重新选择。")
            }
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
