import Foundation

struct RemoteEntry: Identifiable, Equatable {
    let name: String
    let rawName: Data
    let isDirectory: Bool
    let size: Int64?
    var id: Data { rawName }
}

struct DirectoryListing {
    let entries: [RemoteEntry]
    let encoding: FTPTextEncoding
}
