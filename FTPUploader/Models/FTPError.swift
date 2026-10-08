import Foundation

/// The form field a local validation failure belongs to. Views use it to place
/// the reason next to the owning control and to focus the first invalid field,
/// instead of guessing the field from the error text.
enum FTPFormField: Hashable {
    case address, username, password, server, port, initialDirectory
}

/// A local input failure tied to one field. `errorDescription` is the existing
/// user-facing Chinese reason, so callers that only read the message are unchanged.
struct FieldIssue: Error, Equatable, LocalizedError {
    let field: FTPFormField
    let message: String

    var errorDescription: String? { message }
}

enum FTPError: Error, LocalizedError {
    case invalidAddress(String)
    case security(String)
    case invalidName
    case incompatibleListing
    case incompatibleEncoding
    case localFile(String)
    case uploadTargetConflict
    case initialPath(String, String)
    case transport(code: Int32, response: Int, message: String, upload: Bool, mode: FTPLoginMode = .anonymous)

    var errorDescription: String? {
        switch self {
        case .invalidAddress(let message): return message
        case .security(let message): return message
        case .invalidName: return "文件或目录名称包含无法安全访问的字符。"
        case .incompatibleListing: return "无法识别服务器的目录格式，当前目录尚未加载。"
        case .incompatibleEncoding: return "无法正确转换服务器的文件名编码，请核对服务器兼容性。"
        case .initialPath(let segment, let reason): return "无法进入初始目录的“\(segment)”：\(reason)"
        case .uploadTargetConflict: return "目标存在同名目录，不能上传此文件。"
        case .localFile(let message): return "无法读取所选文件：\(message)"
        case let .transport(code, response, message, upload, mode):
            let title: String
            if response == 530 {
                title = mode == .anonymous ? "服务器拒绝匿名访问" : "账户登录失败，服务器拒绝认证"
            } else if response >= 400 {
                title = "服务器拒绝此次操作"
            } else if upload {
                title = "未能确认上传成功"
            } else {
                title = "无法连接或读取目录，请检查服务器地址和网络连接"
            }
            let detail = response > 0 ? "FTP \(response)" : "连接错误 \(code)"
            return "\(title)（\(detail)）。\(message)"
        }
    }

    var responseCode: Int? {
        if case .transport(_, let response, _, _, _) = self { return response }
        return nil
    }
}
