import Foundation

enum FTPLoginMode: String, Codable, CaseIterable {
    case anonymous, account
    var title: String { self == .anonymous ? "匿名" : "账号密码" }
}

struct FTPCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    let mode: FTPLoginMode
    let username: String
    let password: String

    static let anonymous = FTPCredentials(mode: .anonymous, username: "anonymous", password: "anonymous@")
    var description: String { "FTPCredentials(\(mode.rawValue), [redacted])" }
    var debugDescription: String { description }

    static func account(username: String, password: String?) throws -> FTPCredentials {
        guard !username.isEmpty else { throw FieldIssue(field: .username, message: "请输入用户名。") }
        guard let password else { throw FieldIssue(field: .password, message: "请输入密码，或明确选择使用空密码。") }
        guard !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw FieldIssue(field: .username, message: "用户名不能包含换行或控制字符。")
        }
        guard !password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw FieldIssue(field: .password, message: "密码不能包含换行或控制字符。")
        }
        return FTPCredentials(mode: .account, username: username, password: password)
    }

    func redacting(_ text: String) -> String {
        password.isEmpty ? text : text.replacingOccurrences(of: password, with: "[redacted]")
    }
}

enum SiteError: LocalizedError {
    case invalid(String), storage, credentials(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .storage: return "无法读取或保存站点配置，原数据已保留。手动连接仍可使用。"
        case .credentials(let message): return message
        }
    }
}

struct FTPIdentity: Codable, Equatable {
    let host: String
    let port: Int
    let username: String
    let mode: FTPLoginMode
}

struct FTPSite: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    let host: String
    let port: Int
    let initialDirectory: String
    let loginMode: FTPLoginMode
    let username: String
    let rememberPassword: Bool

    var identity: FTPIdentity { FTPIdentity(host: host.lowercased(), port: port, username: username, mode: loginMode) }
    var address: String {
        let authority = host.contains(":") ? "[\(host)]" : host
        return "ftp://\(authority):\(port)\(initialDirectory)"
    }
    func validate() throws {
        let endpoint = try FTPEndpoint(address: address)
        guard endpoint.host == host, endpoint.port == port, !name.isEmpty,
              loginMode == .account || (!rememberPassword && username.isEmpty) else { throw SiteError.storage }
        if loginMode == .account { _ = try FTPCredentials.account(username: username, password: "") }
    }
}

// Draft passwords are deliberately not Codable. nil means no password obtained;
// an empty string means the user explicitly supplied an empty password.
struct SiteDraft {
    var id = UUID()
    var name = ""
    var host = ""
    var port = "21"
    var initialDirectory = "/"
    var loginMode = FTPLoginMode.anonymous
    var username = ""
    var rememberPassword = false
    var password: String?

    init() {}
    init(site: FTPSite) {
        id = site.id; name = site.name; host = site.host; port = String(site.port)
        initialDirectory = site.initialDirectory; loginMode = site.loginMode
        username = site.username; rememberPassword = site.rememberPassword
    }

    func configuration() throws -> FTPSite {
        let server: FTPEndpoint
        do { server = try FTPEndpoint(address: host) }
        catch let issue as FieldIssue { throw FieldIssue(field: .server, message: issue.message) }
        catch { throw FieldIssue(field: .server, message: error.localizedDescription) }
        guard server.initialPath.components.isEmpty, server.port == 21 else {
            throw FieldIssue(field: .server, message: "服务器字段请只填写主机名或 IP；端口和目录请使用下方独立字段。")
        }
        guard let portNumber = Int(port), (1...65535).contains(portNumber) else {
            throw FieldIssue(field: .port, message: "端口请填写 1 到 65535 之间的数字。")
        }
        let authority = server.host.contains(":") ? "[\(server.host)]" : server.host
        let directory = initialDirectory.isEmpty ? "/" : (initialDirectory.hasPrefix("/") ? initialDirectory : "/" + initialDirectory)
        let endpoint: FTPEndpoint
        do { endpoint = try FTPEndpoint(address: "ftp://\(authority):\(portNumber)\(directory)") }
        catch let issue as FieldIssue { throw FieldIssue(field: .initialDirectory, message: issue.message) }
        catch { throw FieldIssue(field: .initialDirectory, message: error.localizedDescription) }
        if loginMode == .account {
            _ = try FTPCredentials.account(username: username, password: password ?? "")
        }
        let site = FTPSite(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? server.host : name,
                           host: endpoint.host, port: portNumber, initialDirectory: endpoint.initialPath.encodedDirectory,
                           loginMode: loginMode, username: loginMode == .account ? username : "",
                           rememberPassword: loginMode == .account && rememberPassword)
        try site.validate()
        return site
    }
}
