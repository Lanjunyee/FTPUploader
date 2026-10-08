import Foundation
import Darwin

/// Owns only the temporary file it created. Never truncates the user's destination.
final class LocalDownload {
    struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let seconds: Int
        let nanos: Int
    }
    enum CommitError: Error { case confirmationRequired }
    let destination: URL
    let temporary: URL
    private let temporaryDirectory: URL
    private var handle: FileHandle?
    private(set) var byteCount: Int64 = 0
    private var closed = false
    private var committed = false
    private var temporaryIdentity: Identity?
    private let scoped: Bool
    private(set) var authorizedIdentity: Identity?
    private let write: (FileHandle, Data) throws -> Void
    private let close: (FileHandle) throws -> Void
    private let rename: (String, String, Bool) throws -> Void

    static func identity(_ url: URL) throws -> Identity? {
        var value = stat()
        if lstat(url.path, &value) != 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (value.st_mode & S_IFMT) == S_IFREG else {
            throw FTPError.localFile("保存目标必须是普通文件，不能是文件夹或符号链接。")
        }
        return Identity(device: value.st_dev, inode: value.st_ino, size: value.st_size,
                        seconds: value.st_mtimespec.tv_sec, nanos: value.st_mtimespec.tv_nsec)
    }

    init(destination: URL, authorizedIdentity: Identity? = nil,
         write: @escaping (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) },
         close: @escaping (FileHandle) throws -> Void = { try $0.synchronize(); try $0.close() },
         rename: @escaping (String, String, Bool) throws -> Void = { source, target, replace in
             let sourceURL = URL(fileURLWithPath: source), targetURL = URL(fileURLWithPath: target)
             if replace {
                 _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: sourceURL)
             } else {
                 do { try FileManager.default.moveItem(at: sourceURL, to: targetURL) }
                 catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                     throw POSIXError(.EEXIST)
                 }
             }
         }) throws {
        self.destination = destination; self.authorizedIdentity = authorizedIdentity
        self.write = write; self.close = close; self.rename = rename
        scoped = destination.startAccessingSecurityScopedResource()
        do {
            temporaryDirectory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                             appropriateFor: destination, create: true)
        } catch {
            if scoped { destination.stopAccessingSecurityScopedResource() }
            throw error
        }
        temporary = temporaryDirectory.appendingPathComponent(".ftpuploader-" + UUID().uuidString + ".part")
        do {
            let current = try Self.identity(destination)
            if current != nil && current != authorizedIdentity { throw CommitError.confirmationRequired }
            let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            temporaryIdentity = try Self.identity(temporary)
        } catch {
            try? handle?.close(); handle = nil
            try? FileManager.default.removeItem(at: temporaryDirectory)
            if scoped { destination.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func receive(_ bytes: Data) throws {
        guard !closed, let handle else { throw FTPError.localFile("下载临时文件已经关闭。") }
        try write(handle, bytes); byteCount += Int64(bytes.count)
    }

    func closeFile() throws {
        guard !closed, let handle else { return }
        try close(handle)
        self.handle = nil; closed = true
    }

    /// Called only after a separate confirmation that names this exact destination.
    func authorizeCurrentTarget() throws { authorizedIdentity = try Self.identity(destination) }

    func commit() throws {
        guard closed, !committed else { throw FTPError.localFile("下载尚未关闭或已经提交。") }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var failure: Error?
        coordinator.coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { url in
            do {
                let owned = try Self.identity(temporary)
                guard let owned, let original = temporaryIdentity, owned.inode == original.inode, owned.device == original.device else {
                    throw FTPError.localFile("临时文件已被替换，未提交目标：" + temporary.path)
                }
                let current = try Self.identity(url)
                guard current == authorizedIdentity else { throw CommitError.confirmationRequired }
                do { try rename(temporary.path, url.path, current != nil) }
                catch let error as POSIXError where error.code == .EEXIST {
                    throw CommitError.confirmationRequired
                }
                committed = true
            } catch { failure = error }
        }
        if let coordinationError { throw coordinationError }
        if let failure { throw failure }
    }

    func cleanUp() throws {
        var closeError: Error?
        if let handle { do { try handle.close() } catch { closeError = error }; self.handle = nil }
        closed = true
        if !committed {
            do {
                if let current = try Self.identity(temporary) {
                    guard let original = temporaryIdentity, current.inode == original.inode, current.device == original.device else {
                        throw FTPError.localFile("临时文件已被替换，未删除该位置的文件。")
                    }
                    try FileManager.default.removeItem(at: temporary)
                }
            } catch { throw FTPError.localFile("无法清理本次下载临时文件：\(temporary.path)。\(error.localizedDescription)") }
        }
        do {
            if FileManager.default.fileExists(atPath: temporaryDirectory.path) {
                // Remove the directory only when empty; never recursively erase an unexpected file.
                if rmdir(temporaryDirectory.path) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
        } catch { throw FTPError.localFile("无法清理本次下载临时目录：\(temporaryDirectory.path)。\(error.localizedDescription)") }
        if let closeError { throw FTPError.localFile("关闭临时文件失败：\(temporary.path)。\(closeError.localizedDescription)") }
    }
    deinit {
        try? cleanUp()
        if scoped { destination.stopAccessingSecurityScopedResource() }
    }
}
