import Foundation
import CoreFoundation

enum FTPTextEncoding: Equatable {
    case utf8
    case gb18030

    var foundationEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .gb18030:
            let value = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(value))
        }
    }

    func decode(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: foundationEncoding),
              text.data(using: foundationEncoding, allowLossyConversion: false) == data else {
            throw FTPError.incompatibleEncoding
        }
        return text
    }

    func encode(_ text: String) throws -> Data {
        guard let data = text.data(using: foundationEncoding, allowLossyConversion: false),
              try decode(data) == text else { throw FTPError.incompatibleEncoding }
        return data
    }

    static func detect(_ data: Data) throws -> FTPTextEncoding {
        for encoding in [FTPTextEncoding.utf8, .gb18030] {
            if (try? encoding.decode(data)) != nil { return encoding }
        }
        throw FTPError.incompatibleEncoding
    }
}


enum FTPEncodingPolicy: String, Codable, CaseIterable {
    case automatic, utf8, gb18030
    var title: String {
        switch self {
        case .automatic: return "自动"
        case .utf8: return "UTF-8"
        case .gb18030: return "GB18030"
        }
    }
    var explicitEncoding: FTPTextEncoding? {
        switch self {
        case .automatic: return nil
        case .utf8: return .utf8
        case .gb18030: return .gb18030
        }
    }
}
