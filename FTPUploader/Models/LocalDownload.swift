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
    private var scoped: Bool
    private let scope: LocalSecurityScope?
    private(set) var authorizedIdentity: Identity?
    private let write: (FileHandle, Data) throws -> Void
    private let close: (FileHandle) throws -> Void
    private let rename: ((String, String, Bool) throws -> Void)?
    private let anchor: Anchor?
    private var failed = false
    private var cleanupFinished = false

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
         scope: LocalSecurityScope = .system,
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
        self.write = write; self.close = close; self.rename = rename; anchor = nil
        self.scope = scope
        scoped = scope.start(destination)
        do {
            temporaryDirectory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                             appropriateFor: destination, create: true)
        } catch {
            if scoped { scoped = false; scope.stop(destination) }
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
            cleanupFinished = true
            if scoped { scoped = false; scope.stop(destination) }
            throw error
        }
    }

    /// Collection downloads borrow the selected-root lease held by the anchor's validator.
    init(destination: URL, anchor: Anchor, authorizedIdentity: Identity? = nil,
         write: @escaping (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) },
         close: @escaping (FileHandle) throws -> Void = { try $0.synchronize(); try $0.close() }) throws {
        self.destination = destination; self.anchor = anchor; self.authorizedIdentity = authorizedIdentity
        self.write = write; self.close = close; rename = nil; scoped = false; scope = nil
        temporaryDirectory = anchor.directoryURL; temporary = anchor.fileURL
        do {
            try anchor.validateParent()
            let current = try anchor.targetIdentity()
            if current != nil && current != authorizedIdentity { throw CommitError.confirmationRequired }
            let fd = openat(anchor.directoryDescriptor, Anchor.fileName,
                            O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Anchor.posixFailure() }
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            temporaryIdentity = try anchor.fileIdentity()
        } catch {
            try? handle?.close(); handle = nil
            try? anchor.cleanDirectory()
            anchor.release()
            throw error
        }
    }

    func receive(_ bytes: Data) throws {
        guard !closed, !failed, let handle else { throw FTPError.localFile("下载临时文件已经关闭或写入失败。") }
        do { try write(handle, bytes); byteCount += Int64(bytes.count) }
        catch { failed = true; throw error }
    }

    func closeFile() throws {
        guard !closed, let handle else { return }
        do { try close(handle) }
        catch { failed = true; throw error }
        self.handle = nil; closed = true
    }

    /// Called only after a separate confirmation that names this exact destination.
    func currentTargetIdentity() throws -> Identity? {
        guard !cleanupFinished else { throw FTPError.localFile("下载接收器已清理，不能继续核对目标。") }
        if let anchor { try anchor.validateParent(); return try anchor.targetIdentity() }
        return try Self.identity(destination)
    }
    func authorizeCurrentTarget() throws { authorizedIdentity = try currentTargetIdentity() }
    /// Confirmation binds to the identity shown, not whatever appears while the dialog waits.
    func authorizeTarget(_ identity: Identity?) { authorizedIdentity = identity }

    func commit() throws {
        guard closed, !committed, !failed, !cleanupFinished else { throw FTPError.localFile("下载尚未关闭、写入/关闭失败或已经提交。") }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var failure: Error?
        coordinator.coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { url in
            do {
                if let anchor {
                    // Coordination URL changes never redirect the descriptor-based commit.
                    guard url.standardizedFileURL == destination.standardizedFileURL else {
                        throw FTPError.localFile("文件协调改变了保存目标，请重新选择。")
                    }
                    try anchor.validateParent()
                }
                let owned = try anchor.map { try $0.fileIdentity() } ?? Self.identity(temporary)
                guard let owned, let original = temporaryIdentity, owned.inode == original.inode, owned.device == original.device else {
                    throw FTPError.localFile("临时文件已被替换，未提交目标：" + temporary.path)
                }
                let current = try anchor.map { try $0.targetIdentity() } ?? Self.identity(url)
                guard current == authorizedIdentity else { throw CommitError.confirmationRequired }
                do {
                    if let anchor { try anchor.move(replace: current != nil) }
                    else if let rename { try rename(temporary.path, url.path, current != nil) }
                }
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
        guard !cleanupFinished else { return }
        // A terminal attempt, even one reporting cleanup failure, owns the release.
        // Retained backend callbacks must not keep security scope or anchor fds alive.
        cleanupFinished = true
        defer { anchor?.release(); releaseScope() }
        var closeError: Error?
        if let handle { do { try handle.close() } catch { closeError = error }; self.handle = nil }
        closed = true
        if !committed {
            do {
                if let current = try anchor.map({ try $0.fileIdentity() }) ?? Self.identity(temporary) {
                    guard let original = temporaryIdentity, current.inode == original.inode, current.device == original.device else {
                        throw FTPError.localFile("临时文件已被替换，未删除该位置的文件。")
                    }
                    if let anchor { try anchor.removeFile() }
                    else { try FileManager.default.removeItem(at: temporary) }
                }
            } catch { throw FTPError.localFile("无法清理本次下载临时文件：\(temporary.path)。\(error.localizedDescription)") }
        }
        do {
            if let anchor { try anchor.cleanDirectory() }
            else if FileManager.default.fileExists(atPath: temporaryDirectory.path) {
                // Remove the directory only when empty; never recursively erase an unexpected file.
                if rmdir(temporaryDirectory.path) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
        } catch { throw FTPError.localFile("无法清理本次下载临时目录：\(temporaryDirectory.path)。\(error.localizedDescription)") }
        if let closeError { throw FTPError.localFile("关闭临时文件失败：\(temporary.path)。\(closeError.localizedDescription)") }
    }
    private func releaseScope() {
        guard scoped else { return }
        scoped = false
        scope?.stop(destination)
    }
    deinit { try? cleanUp() }

    /// Same-volume private replacement directory. Every mutation uses directory descriptors.
    /// Parent validation/commit are called on the collection coordinator's actor, not by receive.
    final class Anchor {
        struct Operations {
            var move: (Int32, String, Int32, String, UInt32) throws -> Void = { fromFD, from, toFD, to, flags in
                guard renameatx_np(fromFD, from, toFD, to, flags) == 0 else { throw posixFailure() }
            }
            var remove: (Int32, String, Int32) throws -> Void = { fd, name, flags in
                guard unlinkat(fd, name, flags) == 0 else { throw posixFailure() }
            }
        }
        static let fileName = "payload.part"
        private(set) var directoryDescriptor: Int32
        let directoryURL: URL
        var fileURL: URL { directoryURL.appendingPathComponent(Self.fileName) }
        private var parentValidator: (() throws -> Void)?
        private var parentDescriptor: Int32
        private let targetName: String
        private let directoryName: String
        private let directoryIdentity: LocalRootIdentity
        private let operations: Operations
        private var directoryRemoved = false

        init(destination: URL, parentDescriptor: Int32, validateParent: @escaping () throws -> Void,
             operations: Operations = Operations()) throws {
            try validateParent()
            let parent = dup(parentDescriptor)
            guard parent >= 0 else { throw Self.posixFailure() }
            let name = ".ftpuploader-" + UUID().uuidString
            guard mkdirat(parent, name, 0o700) == 0 else {
                let error = Self.posixFailure(); Darwin.close(parent); throw error
            }
            let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else {
                let error = Self.posixFailure(); Darwin.close(parent); throw error
            }
            var value = stat()
            guard fstat(directory, &value) == 0 else {
                let error = Self.posixFailure(); Darwin.close(directory); Darwin.close(parent); throw error
            }
            self.parentDescriptor = parent; directoryDescriptor = directory
            directoryName = name; targetName = destination.lastPathComponent
            directoryURL = destination.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
            directoryIdentity = LocalRootIdentity(value)
            parentValidator = validateParent; self.operations = operations
        }
        static func posixFailure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        static func identity(fd: Int32, name: String) throws -> Identity? {
            var value = stat()
            if fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { return nil }
                throw posixFailure()
            }
            guard value.st_mode & S_IFMT == S_IFREG else {
                throw FTPError.localFile("保存目标或临时文件不是普通文件，未继续操作。")
            }
            return Identity(device: value.st_dev, inode: value.st_ino, size: value.st_size,
                            seconds: value.st_mtimespec.tv_sec, nanos: value.st_mtimespec.tv_nsec)
        }
        private func checkOpen() throws {
            guard directoryDescriptor >= 0, parentDescriptor >= 0 else {
                throw FTPError.localFile("下载锚点已释放，不能继续操作。")
            }
        }
        func validateParent() throws {
            try checkOpen()
            guard let parentValidator else { throw FTPError.localFile("下载锚点已释放。") }
            try parentValidator()
        }
        func targetIdentity() throws -> Identity? { try checkOpen(); return try Self.identity(fd: parentDescriptor, name: targetName) }
        func fileIdentity() throws -> Identity? { try checkOpen(); return try Self.identity(fd: directoryDescriptor, name: Self.fileName) }
        func move(replace: Bool) throws {
            try checkOpen()
            // No fallback on unsupported flags/filesystems. Existing-file replacement has the
            // documented non-cooperating last-check race; this is not an inode compare-and-swap.
            let flags = UInt32(RENAME_NOFOLLOW_ANY) | (replace ? 0 : UInt32(RENAME_EXCL))
            try operations.move(directoryDescriptor, Self.fileName, parentDescriptor, targetName, flags)
        }
        func removeFile() throws { try checkOpen(); try operations.remove(directoryDescriptor, Self.fileName, 0) }
        func cleanDirectory() throws {
            try checkOpen()
            guard !directoryRemoved else { return }
            var value = stat()
            if fstatat(parentDescriptor, directoryName, &value, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { directoryRemoved = true; return }
                throw Self.posixFailure()
            }
            guard LocalRootIdentity(value) == directoryIdentity else {
                throw FTPError.localFile("本次临时目录已被替换，未删除该位置的对象。")
            }
            try operations.remove(parentDescriptor, directoryName, AT_REMOVEDIR)
            directoryRemoved = true
        }
        /// Terminal cleanup must not depend on retained receive/progress callbacks being destroyed.
        func release() {
            if directoryDescriptor >= 0 { Darwin.close(directoryDescriptor); directoryDescriptor = -1 }
            if parentDescriptor >= 0 { Darwin.close(parentDescriptor); parentDescriptor = -1 }
            parentValidator = nil
        }
        deinit { release() }
    }
}
