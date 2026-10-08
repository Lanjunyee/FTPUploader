import Foundation

enum FileTransport: String, Codable, CaseIterable {
    case ftp, ftpsExplicit, ftpsImplicit, sftp
    var title: String {
        switch self {
        case .ftp: return "FTP（不加密）"
        case .ftpsExplicit: return "FTPS（显式 TLS）"
        case .ftpsImplicit: return "FTPS（隐式 TLS）"
        case .sftp: return "SFTP（SSH）"
        }
    }
    var defaultPort: Int { self == .sftp ? 22 : (self == .ftpsImplicit ? 990 : 21) }
    var scheme: String { self == .sftp ? "sftp" : (self == .ftpsImplicit ? "ftps" : "ftp") }
    var requiresTLS: Bool { self == .ftpsExplicit || self == .ftpsImplicit }
}

struct FTPEndpoint: Equatable {
    let transport: FileTransport
    let host: String
    let port: Int
    let initialPath: RemotePath
    let initialSegments: [FTPInitialPathSegment]
    var hasRawInitialPath: Bool { initialSegments.contains { $0.hasEscapedBytes } && !initialSegments.contains { $0.hasNonASCIIText } }

    var authority: String {
        let formatted = host.contains(":") ? "[\(host)]" : host
        return port == transport.defaultPort ? formatted : "\(formatted):\(port)"
    }
    var display: String { "\(transport.scheme)://\(authority)" }

    init(address: String, transport selected: FileTransport? = nil) throws {
        guard !address.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw FieldIssue(field: .address, message: "服务器地址不能包含换行或控制字符。")
        }
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw FieldIssue(field: .address, message: "请输入 FTP 服务器地址。") }
        let supplied = trimmed.contains("://") ? trimmed : "\((selected ?? .ftp).scheme)://" + trimmed
        guard !supplied.contains("?"), !supplied.contains("#") else {
            throw FieldIssue(field: .address, message: "地址不能包含查询或片段；文件夹名中的 # 请写成 %23。")
        }
        // Parse the authority separately: Foundation re-escapes existing percent
        // sequences when a URL also contains unescaped Unicode or spaces.
        let schemeEnd = supplied.range(of: "://")!.upperBound
        let remainder = supplied[schemeEnd...]
        let slash = remainder.firstIndex(of: "/") ?? supplied.endIndex
        let authorityURL = String(supplied[..<slash])
        let rawPath = String(supplied[slash...])
        guard let url = URLComponents(string: authorityURL), let scheme = url.scheme?.lowercased(),
              ["ftp", "ftps", "sftp"].contains(scheme) else {
            throw FieldIssue(field: .address, message: "支持 ftp://、ftps:// 和 sftp:// 地址，请检查地址格式。")
        }
        let inferred: FileTransport = scheme == "sftp" ? .sftp : (scheme == "ftps" ? .ftpsImplicit : .ftp)
        let resolved = selected ?? inferred
        guard scheme == resolved.scheme else {
            throw FieldIssue(field: .address, message: "地址协议与所选协议冲突，请核对协议和地址。")
        }
        guard url.user == nil, url.password == nil else {
            throw FieldIssue(field: .address, message: "请使用不含账号密码的 FTP 地址，登录信息请在独立字段填写。")
        }
        guard let rawHost = url.host, !rawHost.isEmpty,
              !rawHost.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              !rawHost.contains("%"), !rawHost.contains("\\") else {
            throw FieldIssue(field: .address, message: "请输入有效的服务器主机名或 IP 地址。")
        }
        let serverPort = url.port ?? resolved.defaultPort
        guard (1...65535).contains(serverPort), !authorityURL.hasSuffix(":") else {
            throw FieldIssue(field: .address, message: "端口必须在 1 到 65535 之间。")
        }
        var path = RemotePath.root
        var segments: [FTPInitialPathSegment] = []
        for segment in rawPath.split(separator: "/", omittingEmptySubsequences: true) {
            // RemotePath owns the percent-encoding rules; keep its reason but
            // report it against the address field the user must fix.
            let data: Data
            do { data = try RemotePath.percentDecode(String(segment)) }
            catch let error as FTPError {
                if case .invalidAddress(let message) = error {
                    throw FieldIssue(field: .address, message: message)
                }
                throw error
            }
            segments.append(try FTPInitialPathSegment(String(segment)))
            let encoding = resolved == .sftp ? FTPTextEncoding.utf8 : try FTPTextEncoding.detect(data)
            if resolved == .sftp && String(data: data, encoding: .utf8) == nil { throw FTPError.incompatibleEncoding }
            path = try path.appending(name: encoding.decode(data), bytes: data)
        }
        host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        transport = resolved
        port = serverPort
        initialPath = path
        initialSegments = segments
    }

    func initialPath(using encoding: FTPTextEncoding) throws -> RemotePath {
        var path = RemotePath.root
        for segment in initialSegments {
            let bytes = try segment.encoded(using: encoding)
            path = try path.appending(name: encoding.decode(bytes), bytes: bytes)
        }
        return path
    }

    func directoryURL(_ path: RemotePath) -> String { display + path.encodedDirectory }
    func fileURL(_ path: RemotePath, name: String, encoding: FTPTextEncoding) throws -> String {
        display + (try path.encodedFile(name: name, encoding: encoding))
    }
}
