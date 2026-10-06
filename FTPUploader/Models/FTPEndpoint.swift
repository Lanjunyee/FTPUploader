import Foundation

struct FTPEndpoint: Equatable {
    let host: String
    let port: Int
    let initialPath: RemotePath

    var authority: String {
        let formatted = host.contains(":") ? "[\(host)]" : host
        return port == 21 ? formatted : "\(formatted):\(port)"
    }
    var display: String { "ftp://\(authority)" }

    init(address: String) throws {
        guard !address.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw FieldIssue(field: .address, message: "服务器地址不能包含换行或控制字符。")
        }
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw FieldIssue(field: .address, message: "请输入 FTP 服务器地址。") }
        let supplied = trimmed.contains("://") ? trimmed : "ftp://" + trimmed
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
        guard let url = URLComponents(string: authorityURL), url.scheme?.lowercased() == "ftp" else {
            throw FieldIssue(field: .address, message: "首版支持 ftp:// 地址，请检查地址格式。")
        }
        guard url.user == nil, url.password == nil else {
            throw FieldIssue(field: .address, message: "请使用不含账号密码的 FTP 地址，登录信息请在独立字段填写。")
        }
        guard let rawHost = url.host, !rawHost.isEmpty,
              !rawHost.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              !rawHost.contains("%"), !rawHost.contains("\\") else {
            throw FieldIssue(field: .address, message: "请输入有效的服务器主机名或 IP 地址。")
        }
        let serverPort = url.port ?? 21
        guard (1...65535).contains(serverPort), !authorityURL.hasSuffix(":") else {
            throw FieldIssue(field: .address, message: "端口必须在 1 到 65535 之间。")
        }
        var path = RemotePath.root
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
            let encoding = try FTPTextEncoding.detect(data)
            path = try path.appending(name: encoding.decode(data), bytes: data)
        }
        host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        port = serverPort
        initialPath = path
    }

    func directoryURL(_ path: RemotePath) -> String { display + path.encodedDirectory }
    func fileURL(_ path: RemotePath, name: String, encoding: FTPTextEncoding) throws -> String {
        display + (try path.encodedFile(name: name, encoding: encoding))
    }
}
