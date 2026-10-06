import Foundation

final class SelectedLocalFile {
    let url: URL
    private(set) var size: Int64 = 0
    private var hasScopedAccess = false
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
        } catch {
            endAccess()
            if let error = error as? FTPError { throw error }
            throw FTPError.localFile(error.localizedDescription)
        }
    }

    func endAccess() {
        if hasScopedAccess {
            url.stopAccessingSecurityScopedResource()
            hasScopedAccess = false
        }
    }

    deinit { endAccess() }
}
