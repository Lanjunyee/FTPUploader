import Foundation
import Security

protocol PasswordStoring {
    func password(for site: FTPSite) async throws -> String?
    func save(_ password: String, for site: FTPSite) async throws
    func remove(id: UUID) async throws
}

// The synchronous system boundary is injectable for failure and isolation tests.
protocol KeychainAccess {
    func read(_ query: [String: Any]) -> (OSStatus, Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
    func accounts(service: String) -> (OSStatus, [String]?)
}

extension KeychainAccess {
    // Unknown/custom backends must not silently skip orphan discovery.
    func accounts(service: String) -> (OSStatus, [String]?) { (errSecUnimplemented, nil) }
}

private struct SystemKeychain: KeychainAccess {
    func read(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
    func accounts(service: String) -> (OSStatus, [String]?) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return (status, nil) }
        guard let records = result as? [[String: Any]] else { return (errSecDecode, nil) }
        let accounts = records.compactMap { $0[kSecAttrAccount as String] as? String }
        guard accounts.count == records.count else { return (errSecDecode, nil) }
        return (status, accounts)
    }
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

final class PasswordStore: PasswordStoring {
    private struct Record: Codable { let identity: FTPIdentity; let password: String }
    /// Memory-only full record payloads, not Codable and never a diagnostic source.
    struct Snapshot: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
        let siteID: UUID
        fileprivate let legacy: Data?
        fileprivate let current: Data?
        var hasLegacy: Bool { legacy != nil }
        var hasCurrent: Bool { current != nil }
        var description: String { "PasswordSnapshot([redacted])" }
        var debugDescription: String { description }
    }
    private struct Recovery: Codable, Equatable {
        let version: Int
        let transactionID: UUID
        let siteID: UUID
        let legacy: Data?
        let current: Data?
        var snapshot: Snapshot { Snapshot(siteID: siteID, legacy: legacy, current: current) }
    }
    private let service: String
    private let access: KeychainAccess
    private let queue = DispatchQueue(label: "local.ftpuploader.passwords", qos: .userInitiated)

    init(service: String = "local.schoolftpuploader.ftp-sites", access: KeychainAccess? = nil) {
        self.service = service; self.access = access ?? SystemKeychain()
    }

    private func query(_ id: UUID, legacy: Bool = false) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: legacy ? service : service + ".v2", kSecAttrAccount as String: id.uuidString]
    }

    private func perform<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func read(_ site: FTPSite, legacy: Bool) throws -> String? {
        var request = query(site.id, legacy: legacy)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = access.read(request)
        if status == errSecItemNotFound { return nil }
        try check(status, action: "读取")
        guard let data, let record = try? JSONDecoder().decode(Record.self, from: data),
              record.identity == site.identity else {
            throw SiteError.credentials("保存的密码与当前站点身份不符，请重新输入密码。")
        }
        return try FTPCredentials.account(username: site.username, password: record.password).password
    }

    private func write(_ password: String, site: FTPSite) throws {
        let data = try JSONEncoder().encode(Record(identity: site.identity, password: password))
        let request = query(site.id)
        let status = access.update(request, attributes: [kSecValueData as String: data])
        if status == errSecItemNotFound {
            var attributes = request
            attributes[kSecValueData as String] = data
            try check(access.add(attributes), action: "保存")
        } else { try check(status, action: "保存") }
        guard try raw(request) == data else { throw SiteError.credentials("站点密码写入核对失败，请重试或恢复。") }
    }

    private func raw(_ request: [String: Any]) throws -> Data? {
        var request = request
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = access.read(request)
        if status == errSecItemNotFound { return nil }
        try check(status, action: "读取恢复")
        guard let data else { throw SiteError.credentials("钥匙串恢复记录不完整，原记录已保留。") }
        return data
    }
    private func validate(_ snapshot: Snapshot) throws {
        for bytes in [snapshot.legacy, snapshot.current].compactMap({ $0 }) {
            guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(object.keys) == ["identity", "password"],
                  let identity = object["identity"] as? [String: Any],
                  Set(identity.keys).isSubset(of: ["host", "port", "username", "mode", "transport", "authenticationMethod"]),
                  let record = try? JSONDecoder().decode(Record.self, from: bytes),
                  record.identity.mode == .account, record.identity.authenticationMethod == .password else {
                throw SiteError.credentials("钥匙串密码记录无效，未创建或应用恢复材料。")
            }
            _ = try FTPCredentials.account(username: record.identity.username, password: record.password)
        }
    }
    private func recoveryQuery(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service + ".recovery-v1", kSecAttrAccount as String: id.uuidString]
    }
    private func recoveryRecord(_ id: UUID) throws -> Recovery? {
        guard let bytes = try raw(recoveryQuery(id)) else { return nil }
        guard let record = try? JSONDecoder().decode(Recovery.self, from: bytes), record.version == 1,
              record.transactionID == id else { throw SiteError.credentials("钥匙串事务恢复材料无效，原件已保留。") }
        try validate(record.snapshot)
        return record
    }
    func capture(id: UUID) async throws -> Snapshot {
        try await perform { [self] in
            let snapshot = Snapshot(siteID: id, legacy: try raw(query(id, legacy: true)), current: try raw(query(id)))
            try validate(snapshot); return snapshot
        }
    }
    func saveRecovery(_ snapshot: Snapshot, transactionID: UUID) async throws {
        try await perform { [self] in
            try validate(snapshot)
            let record = Recovery(version: 1, transactionID: transactionID, siteID: snapshot.siteID,
                                  legacy: snapshot.legacy, current: snapshot.current)
            if let existing = try recoveryRecord(transactionID) {
                guard existing == record else { throw SiteError.credentials("此事务已有不同恢复材料，未覆盖原件。") }
            } else {
                var attributes = recoveryQuery(transactionID)
                attributes[kSecValueData as String] = try JSONEncoder().encode(record)
                try check(access.add(attributes), action: "保存恢复")
            }
            guard try recoveryRecord(transactionID) == record else { throw SiteError.credentials("事务恢复材料核对失败，未开始更新。") }
        }
    }
    func loadRecovery(transactionID: UUID, siteID: UUID) async throws -> Snapshot? {
        try await perform { [self] in
            guard let record = try recoveryRecord(transactionID) else { return nil }
            guard record.siteID == siteID else { throw SiteError.credentials("恢复材料与站点不符，未应用该记录。") }
            return record.snapshot
        }
    }
    /// Idempotent compensation. If any operation fails, the recovery item remains for retry.
    func restore(_ snapshot: Snapshot, id: UUID) async throws {
        try await perform { [self] in
            guard snapshot.siteID == id else { throw SiteError.credentials("恢复材料与站点不符，未修改凭据。") }
            try validate(snapshot)
            for (legacy, bytes) in [(true, snapshot.legacy), (false, snapshot.current)] {
                let request = query(id, legacy: legacy)
                if let bytes {
                    let status = access.update(request, attributes: [kSecValueData as String: bytes])
                    if status == errSecItemNotFound {
                        var attributes = request; attributes[kSecValueData as String] = bytes
                        try check(access.add(attributes), action: "还原")
                    } else { try check(status, action: "还原") }
                } else {
                    let status = access.delete(request)
                    if status != errSecItemNotFound { try check(status, action: "还原并移除") }
                }
            }
            guard try raw(query(id, legacy: true)) == snapshot.legacy,
                  try raw(query(id)) == snapshot.current else { throw SiteError.credentials("旧凭据还原核对失败，请重试恢复。") }
        }
    }
    func removeRecovery(transactionID: UUID) async throws {
        try await perform { [self] in
            let status = access.delete(recoveryQuery(transactionID))
            if status != errSecItemNotFound { try check(status, action: "清理恢复") }
            guard try raw(recoveryQuery(transactionID)) == nil else {
                throw SiteError.credentials("恢复项清理核对失败，请重试清理。")
            }
        }
    }

    /// Enumerates only transaction account ids, never returns secrets or unrelated services.
    func recoveryIDs() async throws -> Set<UUID> {
        try await perform { [self] in
            let (status, accounts) = access.accounts(service: service + ".recovery-v1")
            if status == errSecItemNotFound { return [] }
            try check(status, action: "核对恢复项")
            guard let accounts else { throw SiteError.credentials("无法核对恢复项，原件已保留。") }
            let ids = accounts.compactMap(UUID.init(uuidString:))
            guard ids.count == accounts.count, Set(ids).count == ids.count,
                  zip(accounts, ids).allSatisfy({ $0.0 == $0.1.uuidString }) else {
                throw SiteError.credentials("恢复项标识无效，原件已保留。")
            }
            return Set(ids)
        }
    }
    func verifyCommittedCredentials(siteID: UUID, site: FTPSite?, exists: Bool) async throws {
        try await perform { [self] in
            guard try raw(query(siteID, legacy: true)) == nil else { throw SiteError.credentials("旧凭据尚未清理，事务未完成。") }
            if exists {
                guard let site, site.id == siteID, site.rememberPassword,
                      try read(site, legacy: false) != nil else { throw SiteError.credentials("提交凭据与站点不符，事务未完成。") }
            } else {
                guard try raw(query(siteID)) == nil else { throw SiteError.credentials("凭据移除尚未完成，事务未完成。") }
            }
        }
    }

    private func removeLegacy(_ id: UUID) throws {
        let status = access.delete(query(id, legacy: true))
        if status != errSecItemNotFound { try check(status, action: "迁移并清理旧") }
    }

    func readOnlyPassword(for site: FTPSite) async throws -> String? {
        guard site.authenticationMethod == .password else { return nil }
        return try await perform { [self] in
            if let current = try read(site, legacy: false) { return current }
            // A legacy identity has no protocol; it may authorize only plain FTP.
            guard site.transport == .ftp else { return nil }
            return try read(site, legacy: true)
        }
    }
    /// Loading a connection is strictly read-only. Explicit SiteManager saves migrate
    /// legacy records inside the same prepared/committed transaction as configuration.
    func password(for site: FTPSite) async throws -> String? {
        try await readOnlyPassword(for: site)
    }

    func save(_ password: String, for site: FTPSite) async throws {
        _ = try FTPCredentials.account(username: site.username, password: password)
        guard site.loginMode == .account && site.authenticationMethod == .password && site.rememberPassword else { throw SiteError.invalid("此站点未开启记住密码。") }
        try await perform { [self] in
            try write(password, site: site)
            try removeLegacy(site.id)
        }
    }

    func remove(id: UUID) async throws {
        try await perform { [self] in
            // Preserve the source when legacy cleanup fails.
            try removeLegacy(id)
            let status = access.delete(query(id))
            if status != errSecItemNotFound { try check(status, action: "移除") }
        }
    }

    private func check(_ status: OSStatus, action: String) throws {
        guard status != errSecSuccess else { return }
        let reason: String
        switch status {
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            reason = "系统未允许访问钥匙串"
        default: reason = "钥匙串返回错误 \(status)"
        }
        throw SiteError.credentials("无法\(action)站点密码：\(reason)。请重试，或手动输入密码用于本次连接。")
    }
}
