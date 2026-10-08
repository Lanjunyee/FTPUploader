import Foundation
import CryptoKit

struct SSHHostIdentity: Equatable, Identifiable {
    let host: String
    let port: Int
    let key: Data
    var id: String { "\(host.lowercased()):\(port)|\(fingerprint)" }
    var fingerprint: String { "SHA256:" + Data(SHA256.hash(data: key)).base64EncodedString().replacingOccurrences(of: "=", with: "") }
    var keyType: String {
        guard key.count >= 4 else { return "未知密钥" }
        let count = key.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= key.count - 4 else { return "未知密钥" }
        return String(data: key.subdata(in: 4..<(4 + count)), encoding: .utf8) ?? "未知密钥"
    }
}

enum HostTrustError: LocalizedError {
    case unknown(SSHHostIdentity), changed(SSHHostIdentity), storage
    var errorDescription: String? {
        switch self {
        case .unknown: return "此 SFTP 服务器尚未信任，请先核对主机指纹；尚未发送账户密码。"
        case .changed: return "SFTP 主机密钥已变化，已阻止认证与传输。请向服务器管理员核实，不会自动替换已信任密钥。"
        case .storage: return "无法读取或保存 SFTP 主机信任记录，已阻止认证；原记录不会被静默覆盖。"
        }
    }
}

protocol HostTrustStoring {
    func verify(_ identity: SSHHostIdentity) throws
    func trust(_ identity: SSHHostIdentity) throws
    func reset(host: String, port: Int) throws
}

final class HostTrustStore: HostTrustStoring, @unchecked Sendable {
    private struct Record: Codable { let host: String; let port: Int; let key: Data }
    private let url: URL
    private let lock = NSLock()
    private let write: (Data, URL) throws -> Void
    init(url: URL? = nil, write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FTPUploader/known-hosts.json")
        self.write = write
    }
    private func records() throws -> [Record] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: url))
            guard records.allSatisfy({ !$0.host.isEmpty && (1...65535).contains($0.port) && !$0.key.isEmpty }),
                  Set(records.map { "\($0.host.lowercased()):\($0.port)" }).count == records.count else { throw HostTrustError.storage }
            return records
        } catch { throw HostTrustError.storage }
    }
    private func save(_ records: [Record]) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(JSONEncoder().encode(records), url)
        } catch { throw HostTrustError.storage }
    }
    func verify(_ identity: SSHHostIdentity) throws {
        lock.lock(); defer { lock.unlock() }
        guard let record = try records().first(where: { $0.host == identity.host.lowercased() && $0.port == identity.port }) else {
            throw HostTrustError.unknown(identity)
        }
        guard record.key == identity.key else { throw HostTrustError.changed(identity) }
    }
    func trust(_ identity: SSHHostIdentity) throws {
        lock.lock(); defer { lock.unlock() }
        var records = try records()
        if let record = records.first(where: { $0.host == identity.host.lowercased() && $0.port == identity.port }) {
            guard record.key == identity.key else { throw HostTrustError.changed(identity) }
            return
        }
        records.append(Record(host: identity.host.lowercased(), port: identity.port, key: identity.key))
        try save(records)
    }
    func reset(host: String, port: Int) throws {
        lock.lock(); defer { lock.unlock() }
        let records = try records()
        try save(records.filter { $0.host != host.lowercased() || $0.port != port })
    }
}
