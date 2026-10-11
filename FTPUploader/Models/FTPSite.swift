import Foundation

enum FTPLoginMode: String, Codable, CaseIterable, Sendable {
    case anonymous, account
    var title: String { self == .anonymous ? "匿名" : "账号密码" }
}

enum AuthenticationMethod: String, Codable, CaseIterable, Sendable {
    case password, privateKey
    var title: String { self == .password ? "账户密码" : "私钥文件" }
}

struct FTPCredentials: CustomStringConvertible, CustomDebugStringConvertible, Sendable {
    let mode: FTPLoginMode
    let username: String
    let password: String
    var privateKey: PrivateKeyMaterial? = nil
    var passphrase: String? = nil
    var authenticationMethod: AuthenticationMethod { privateKey == nil ? .password : .privateKey }

    static func key(username: String, material: PrivateKeyMaterial, passphrase: String?) throws -> FTPCredentials {
        _ = try account(username: username, password: "")
        guard passphrase?.contains("\0") != true else { throw FieldIssue(field: .passphrase, message: "私钥口令不能包含空字符。") }
        return FTPCredentials(mode: .account, username: username, password: "", privateKey: material, passphrase: passphrase)
    }

    func sameAuthentication(as other: FTPCredentials) -> Bool {
        mode == other.mode && username == other.username && authenticationMethod == other.authenticationMethod
            && password == other.password && privateKey?.digest == other.privateKey?.digest && passphrase == other.passphrase
    }

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
        var result = text
        for secret in [password, passphrase ?? "", privateKey.flatMap { String(data: $0.bytes, encoding: .utf8) } ?? ""] where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "[redacted]")
        }
        return result
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
    var transport = FileTransport.ftp
    var authenticationMethod = AuthenticationMethod.password

    private enum CodingKeys: String, CodingKey { case host, port, username, mode, transport, authenticationMethod }
    init(host: String, port: Int, username: String, mode: FTPLoginMode, transport: FileTransport = .ftp, authenticationMethod: AuthenticationMethod = .password) {
        self.host = host; self.port = port; self.username = username; self.mode = mode; self.transport = transport; self.authenticationMethod = authenticationMethod
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(host: try values.decode(String.self, forKey: .host), port: try values.decode(Int.self, forKey: .port),
                  username: try values.decode(String.self, forKey: .username), mode: try values.decode(FTPLoginMode.self, forKey: .mode),
                  transport: try values.decodeIfPresent(FileTransport.self, forKey: .transport) ?? .ftp,
                  authenticationMethod: try values.decodeIfPresent(AuthenticationMethod.self, forKey: .authenticationMethod) ?? .password)
    }
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
    var encodingPolicy = FTPEncodingPolicy.automatic
    var transport = FileTransport.ftp
    var authenticationMethod = AuthenticationMethod.password
    var privateKeyReference: PrivateKeyReference? = nil

    var identity: FTPIdentity { FTPIdentity(host: host.lowercased(), port: port, username: username, mode: loginMode, transport: transport, authenticationMethod: authenticationMethod) }
    var address: String {
        let authority = host.contains(":") ? "[\(host)]" : host
        return "\(transport.scheme)://\(authority):\(port)\(initialDirectory)"
    }
    func validate() throws {
        let endpoint = try FTPEndpoint(address: address, transport: transport)
        guard endpoint.host == host, endpoint.port == port, !name.isEmpty,
              loginMode == .account || (!rememberPassword && username.isEmpty) else { throw SiteError.storage }
        guard transport != .sftp || (loginMode == .account && encodingPolicy == .utf8) else { throw SiteError.invalid("SFTP 需要账户密码和 UTF-8 编码。") }
        guard authenticationMethod != .privateKey || (transport == .sftp && loginMode == .account && !rememberPassword && privateKeyReference != nil) else {
            throw FieldIssue(field: .privateKey, message: "私钥认证仅适用于 SFTP，请选择私钥文件。")
        }
        if loginMode == .account { _ = try FTPCredentials.account(username: username, password: "") }
    }
}

extension FTPSite {
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, initialDirectory, loginMode, username, rememberPassword, encodingPolicy, transport, authenticationMethod, privateKeyReference
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(UUID.self, forKey: .id), name: try values.decode(String.self, forKey: .name),
                  host: try values.decode(String.self, forKey: .host), port: try values.decode(Int.self, forKey: .port),
                  initialDirectory: try values.decode(String.self, forKey: .initialDirectory),
                  loginMode: try values.decode(FTPLoginMode.self, forKey: .loginMode),
                  username: try values.decode(String.self, forKey: .username),
                  rememberPassword: try values.decode(Bool.self, forKey: .rememberPassword),
                  encodingPolicy: try values.decodeIfPresent(FTPEncodingPolicy.self, forKey: .encodingPolicy) ?? .automatic,
                  transport: try values.decodeIfPresent(FileTransport.self, forKey: .transport) ?? .ftp,
                  authenticationMethod: try values.decodeIfPresent(AuthenticationMethod.self, forKey: .authenticationMethod) ?? .password,
                  privateKeyReference: try values.decodeIfPresent(PrivateKeyReference.self, forKey: .privateKeyReference))
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
    var encodingPolicy = FTPEncodingPolicy.automatic
    var transport = FileTransport.ftp
    var authenticationMethod = AuthenticationMethod.password
    var privateKeyReference: PrivateKeyReference?
    var privateKeySelection: PrivateKeySelection?
    var passphrase: String?
    var password: String?

    init() {}
    init(site: FTPSite) {
        id = site.id; name = site.name; host = site.host; port = String(site.port)
        initialDirectory = site.initialDirectory; loginMode = site.loginMode
        username = site.username; rememberPassword = site.rememberPassword; encodingPolicy = site.encodingPolicy; transport = site.transport
        authenticationMethod = site.authenticationMethod; privateKeyReference = site.privateKeyReference
    }

    func configuration(keyAccess: PrivateKeyAccessing = PrivateKeyAccess()) throws -> FTPSite {
        let server: FTPEndpoint
        do { server = try FTPEndpoint(address: host, transport: transport) }
        catch let issue as FieldIssue { throw FieldIssue(field: .server, message: issue.message) }
        catch { throw FieldIssue(field: .server, message: error.localizedDescription) }
        guard server.initialPath.components.isEmpty, server.port == transport.defaultPort else {
            throw FieldIssue(field: .server, message: "服务器字段请只填写主机名或 IP；端口和目录请使用下方独立字段。")
        }
        guard let portNumber = Int(port), (1...65535).contains(portNumber) else {
            throw FieldIssue(field: .port, message: "端口请填写 1 到 65535 之间的数字。")
        }
        let authority = server.host.contains(":") ? "[\(server.host)]" : server.host
        let directory = initialDirectory.isEmpty ? "/" : (initialDirectory.hasPrefix("/") ? initialDirectory : "/" + initialDirectory)
        let endpoint: FTPEndpoint
        do { endpoint = try FTPEndpoint(address: "\(transport.scheme)://\(authority):\(portNumber)\(directory)", transport: transport) }
        catch let issue as FieldIssue { throw FieldIssue(field: .initialDirectory, message: issue.message) }
        catch { throw FieldIssue(field: .initialDirectory, message: error.localizedDescription) }
        if loginMode == .account {
            _ = try FTPCredentials.account(username: username, password: password ?? "")
        }
        let site = FTPSite(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? server.host : name,
                           host: endpoint.host, port: portNumber, initialDirectory: directory.hasSuffix("/") ? directory : directory + "/",
                           loginMode: loginMode, username: loginMode == .account ? username : "",
                           rememberPassword: loginMode == .account && authenticationMethod == .password && rememberPassword, encodingPolicy: encodingPolicy, transport: transport,
                           authenticationMethod: authenticationMethod, privateKeyReference: authenticationMethod == .privateKey ? (try privateKeySelection?.reference(access: keyAccess) ?? privateKeyReference) : nil)
        try site.validate()
        return site
    }
}
