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
}

private struct SystemKeychain: KeychainAccess {
    func read(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

final class PasswordStore: PasswordStoring {
    private struct Record: Codable { let identity: FTPIdentity; let password: String }
    private let service: String
    private let access: KeychainAccess
    private let queue = DispatchQueue(label: "local.ftpuploader.passwords", qos: .userInitiated)

    init(service: String = "local.schoolftpuploader.ftp-sites", access: KeychainAccess? = nil) {
        self.service = service; self.access = access ?? SystemKeychain()
    }

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }

    private func perform<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func password(for site: FTPSite) async throws -> String? {
        try await perform { [self] in
            var request = query(site.id)
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
    }

    func save(_ password: String, for site: FTPSite) async throws {
        _ = try FTPCredentials.account(username: site.username, password: password)
        guard site.loginMode == .account && site.rememberPassword else { throw SiteError.invalid("此站点未开启记住密码。") }
        try await perform { [self] in
            let data = try JSONEncoder().encode(Record(identity: site.identity, password: password))
            let request = query(site.id)
            let status = access.update(request, attributes: [kSecValueData as String: data])
            if status == errSecItemNotFound {
                var attributes = request
                attributes[kSecValueData as String] = data
                try check(access.add(attributes), action: "保存")
            } else { try check(status, action: "保存") }
        }
    }

    func remove(id: UUID) async throws {
        try await perform { [self] in
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
