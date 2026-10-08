import Foundation
import CryptoKit

final class SelectedLocalFile {
    let url: URL
    private(set) var size: Int64 = 0
    private(set) var hasScopedAccess = false
    private(set) var isAccessActive = false
    var name: String { url.lastPathComponent }

    init(url: URL) throws {
        self.url = url
        try beginAccessAndValidate()
    }

    func beginAccessAndValidate() throws {
        if !hasScopedAccess { hasScopedAccess = url.startAccessingSecurityScopedResource() }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                throw FTPError.localFile("请选择一个普通文件，文件夹不能上传。")
            }
            let handle = try FileHandle(forReadingFrom: url)
            try handle.close()
            size = Int64(values.fileSize ?? 0)
            isAccessActive = true
        } catch {
            endAccess()
            if let error = error as? FTPError { throw error }
            throw FTPError.localFile(error.localizedDescription)
        }
    }

    struct Snapshot: Equatable {
        let size: Int64
        let modified: Date?
        let inode: UInt64
        let digest: Data
    }

    func snapshot() throws -> Snapshot {
        try beginAccessAndValidate()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return Snapshot(size: size, modified: attributes[.modificationDate] as? Date,
                        inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                        digest: Data(hash.finalize()))
    }

    func endAccess() {
        isAccessActive = false
        if hasScopedAccess {
            url.stopAccessingSecurityScopedResource()
            hasScopedAccess = false
        }
    }

    deinit { endAccess() }
}
