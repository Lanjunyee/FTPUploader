import Foundation

struct RemotePath: Equatable {
    struct Component: Equatable {
        let name: String
        let bytes: Data
    }

    var components: [Component] = []
    static let root = RemotePath()

    var display: String { "/" + components.map(\.name).joined(separator: "/") }
    var parent: RemotePath? {
        components.isEmpty ? nil : RemotePath(components: Array(components.dropLast()))
    }
    var encodedDirectory: String {
        components.isEmpty ? "/" : "/" + components.map { Self.percentEncode($0.bytes) }.joined(separator: "/") + "/"
    }

    func appending(name: String, bytes: Data) throws -> RemotePath {
        try Self.validateName(bytes)
        return RemotePath(components: components + [Component(name: name, bytes: bytes)])
    }

    func encodedFile(name: String, encoding: FTPTextEncoding) throws -> String {
        let bytes = try encoding.encode(name)
        try Self.validateName(bytes)
        return encodedDirectory + Self.percentEncode(bytes)
    }

    static func validateName(_ data: Data) throws {
        guard !data.isEmpty, data != Data(".".utf8), data != Data("..".utf8),
              !data.contains(where: { $0 < 32 || $0 == 127 || $0 == 47 }) else {
            throw FTPError.invalidName
        }
    }

    static func percentEncode(_ data: Data) -> String {
        data.map { byte in
            switch byte {
            case 65...90, 97...122, 48...57, 45, 46, 95, 126:
                return String(UnicodeScalar(byte))
            default:
                return String(format: "%%%02X", byte)
            }
        }.joined()
    }

    static func percentDecode(_ text: String) throws -> Data {
        let source = Array(text.utf8)
        var output = Data()
        var index = 0
        while index < source.count {
            if source[index] == 37 {
                guard index + 2 < source.count,
                      let hi = hex(source[index + 1]), let lo = hex(source[index + 2]) else {
                    throw FTPError.invalidAddress("地址包含无效的百分号编码。")
                }
                output.append(hi * 16 + lo)
                index += 3
            } else {
                output.append(source[index])
                index += 1
            }
        }
        return output
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }
}


/// User text is encoded only after policy resolution; escaped octets are kept
/// separate and are never decoded and then silently transcoded.
struct FTPInitialPathSegment: Equatable {
    enum Fragment: Equatable { case text(String), bytes(Data) }
    let fragments: [Fragment]
    let source: String

    init(_ source: String) throws {
        self.source = source
        var fragments: [Fragment] = []
        var literal = ""
        var escaped = Data()
        let chars = Array(source)
        var index = 0
        while index < chars.count {
            if chars[index] == "%" {
                if !literal.isEmpty { fragments.append(.text(literal)); literal = "" }
                guard index + 2 < chars.count else { throw FTPError.invalidAddress("地址包含无效的百分号编码。") }
                escaped.append(try RemotePath.percentDecode(String(chars[index...index + 2])))
                index += 3
            } else {
                if !escaped.isEmpty { fragments.append(.bytes(escaped)); escaped = Data() }
                literal.append(chars[index]); index += 1
            }
        }
        if !literal.isEmpty { fragments.append(.text(literal)) }
        if !escaped.isEmpty { fragments.append(.bytes(escaped)) }
        self.fragments = fragments
    }
    var hasEscapedBytes: Bool { fragments.contains { if case .bytes = $0 { return true }; return false } }
    var hasNonASCIIText: Bool {
        fragments.contains { if case .text(let text) = $0 { return text.utf8.contains { $0 >= 128 } }; return false }
    }
    func encoded(using encoding: FTPTextEncoding) throws -> Data {
        var data = Data()
        for fragment in fragments {
            switch fragment {
            case .text(let text): data.append(try encoding.encode(text))
            case .bytes(let bytes): data.append(bytes)
            }
        }
        try RemotePath.validateName(data)
        return data
    }
}
