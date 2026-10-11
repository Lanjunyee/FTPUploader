import Foundation

struct RemoteEntry: Identifiable, Equatable {
    let name: String
    let rawName: Data
    enum Kind: Int, Equatable {
        case unknown = 0, regularFile, directory, symbolicLink, other
    }
    let kind: Kind
    let size: Int64?
    var kindTitle: String {
        switch kind {
        case .directory: return "文件夹"
        case .regularFile: return "文件"
        case .symbolicLink: return "符号链接"
        case .other: return "特殊项目"
        case .unknown: return "未知类型"
        }
    }
    func information(in location: String) -> String {
        let sizeTitle = kind != .regularFile ? "不适用" :
            size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "未知大小"
        return "名称：\(name)\n类型：\(kindTitle)\n大小：\(sizeTitle)\n所在目录：\(location)"
    }
    var kindSymbol: String {
        switch kind {
        case .directory: return "folder.fill"
        case .regularFile: return "doc"
        case .symbolicLink: return "link"
        case .other: return "cube"
        case .unknown: return "questionmark.square"
        }
    }
    var isDirectory: Bool { kind == .directory }
    var id: Data { rawName }

    init(name: String, rawName: Data, kind: Kind, size: Int64?) {
        self.name = name
        self.rawName = rawName
        self.kind = kind
        self.size = kind == .regularFile ? size : nil
    }

    init(name: String, rawName: Data, isDirectory: Bool, size: Int64?) {
        self.init(name: name, rawName: rawName, kind: isDirectory ? .directory : .regularFile, size: size)
    }
}

struct DirectoryListing {
    let entries: [RemoteEntry]
    let encoding: FTPTextEncoding
}
