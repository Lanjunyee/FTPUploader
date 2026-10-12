import Foundation
import CryptoKit
import Darwin

final class SelectedLocalFile {
    let url: URL
    private(set) var size: Int64 = 0
    private(set) var hasScopedAccess = false
    private(set) var isAccessActive = false
    var name: String { url.lastPathComponent }

    private let diagnostics: TransferDiagnostics?

    init(url: URL, diagnostics: TransferDiagnostics? = nil) throws {
        self.diagnostics = diagnostics
        self.url = url
        try beginAccessAndValidate()
    }

    func beginAccessAndValidate() throws {
        if !hasScopedAccess { hasScopedAccess = url.startAccessingSecurityScopedResource() }
        do {
            let fd = try Self.openFile(url)
            defer { Darwin.close(fd) }
            var value = stat()
            guard fstat(fd, &value) == 0 else { throw FTPError.localFile("无法检查来源文件。") }
            size = value.st_size
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
        let device: UInt64
        init(size: Int64, modified: Date?, inode: UInt64, digest: Data, device: UInt64 = 0) {
            self.size = size; self.modified = modified; self.inode = inode
            self.digest = digest; self.device = device
        }
    }

    private static func openFile(_ url: URL) throws -> Int32 {
        let fd = url.withUnsafeFileSystemRepresentation { name in
            name.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) } ?? -1
        }
        var value = stat()
        guard fd >= 0, fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG else {
            if fd >= 0 { Darwin.close(fd) }
            throw FTPError.localFile("请选择可读取的普通文件，不能是目录或符号链接。")
        }
        return fd
    }

    /// Scope stays held by the caller until this background operation has stopped.
    func snapshot(cancellation: FTPCancellationToken = FTPCancellationToken()) async throws -> Snapshot {
        try cancellation.checkCancellation()
        try beginAccessAndValidate()
        let url = self.url, diagnostics = self.diagnostics
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try cancellation.checkCancellation()
                    let fd = try Self.openFile(url)
                    defer { Darwin.close(fd) }
                    continuation.resume(returning: try Self.snapshot(descriptor: fd, cancellation: cancellation, diagnostics: diagnostics))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Descriptor belongs to the caller. Never follows a path or loads the whole file.
    static func snapshot(descriptor: Int32, cancellation: FTPCancellationToken,
                         didRead: ((Int64) -> Void)? = nil,
                         diagnostics: TransferDiagnostics? = nil) throws -> Snapshot {
        var before = stat(), after = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw FTPError.localFile("无法读取普通来源文件。") }
        diagnostics?.record(.hashPasses)
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        var total: Int64 = 0
        while true {
            try cancellation.checkCancellation()
            let count = Darwin.pread(descriptor, &buffer, buffer.count, off_t(total))
            if count < 0 {
                if errno == EINTR { continue }
                throw FTPError.localFile("来源文件读取失败。")
            }
            if count == 0 { break }
            total += Int64(count)
            hash.update(data: Data(buffer.prefix(count)))
            diagnostics?.record(.hashBytes, count: Int64(count))
            didRead?(total)
        }
        try cancellation.checkCancellation()
        guard fstat(descriptor, &after) == 0,
              LocalRootIdentity(before) == LocalRootIdentity(after), before.st_size == after.st_size,
              total == before.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw FTPError.localFile("计算快照期间来源文件发生变化，请重新核对。")
        }
        return Snapshot(size: total,
            modified: Date(timeIntervalSince1970: Double(before.st_mtimespec.tv_sec) + Double(before.st_mtimespec.tv_nsec) / 1_000_000_000),
            inode: UInt64(before.st_ino), digest: Data(hash.finalize()), device: UInt64(before.st_dev))
    }

    /// Hash and transport share this exact descriptor; no backend reopens its display URL.
    func verifiedSource(matching expected: Snapshot, cancellation: FTPCancellationToken,
                        didVerifyDescriptor: ((Int32) -> Void)? = nil) async throws -> VerifiedSource {
        let root = try LocalSourceRoot(url: url)
        let source = try VerifiedSource(root: root, expected: expected)
        root.endAccess() // The immutable lease defers actual scope/fd release through transport.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try root.validateIdentity()
                    try source.validateDescriptor()
                    guard try Self.snapshot(descriptor: source.descriptor, cancellation: cancellation, diagnostics: self.diagnostics) == expected else {
                        throw FTPError.localFile("发送前来源文件发生变化，请重新核对。")
                    }
                    try root.validateIdentity()
                    didVerifyDescriptor?(source.descriptor)
                    continuation.resume(returning: source)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Rooted collection access never opens a concatenated source URL.
    static func openSource(root: LocalSourceRoot, path: [String],
                           directories: [[String]: (UInt64, UInt64)], directory: Bool) throws -> Int32 {
        try root.validateIdentity()
        if root.identity.kind == .directory {
            guard let expected = directories[[]], root.identity.device == expected.0, root.identity.inode == expected.1 else {
                throw FTPError.localFile("来源根身份与计划不符。")
            }
        } else if directory || !path.isEmpty { throw FTPError.localFile("来源根类型与计划不符。") }
        let lease = try root.lease()
        var fd = dup(lease.descriptor)
        guard fd >= 0 else { throw FTPError.localFile("无法打开来源根句柄。") }
        var transferred = false
        defer { if !transferred { Darwin.close(fd) } }
        var prefix: [String] = []
        for (index, name) in path.enumerated() {
            try RemotePath.validateName(Data(name.utf8))
            let isDirectory = directory || index < path.count - 1
            let next = openat(fd, name, (isDirectory ? O_SEARCH : O_RDONLY | O_NONBLOCK) | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw FTPError.localFile("来源目录或文件不可安全打开。") }
            Darwin.close(fd); fd = next; prefix.append(name)
            if isDirectory {
                var value = stat()
                guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
                      let expected = directories[prefix], UInt64(value.st_dev) == expected.0, UInt64(value.st_ino) == expected.1 else {
                    throw FTPError.localFile("来源目录身份发生变化。")
                }
            }
        }
        transferred = true; return fd
    }

    static func verifiedSource(root: LocalSourceRoot, path: [String], directories: [[String]: (UInt64, UInt64)],
                               matching expected: Snapshot, cancellation: FTPCancellationToken) async throws -> VerifiedSource {
        let lease = try root.lease()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try cancellation.checkCancellation()
                    let fd = try openSource(root: root, path: path, directories: directories, directory: false)
                    let url = path.reduce(root.url) { $0.appendingPathComponent($1) }
                    let source = VerifiedSource(url: url, descriptor: fd, lease: lease, expected: expected)
                    try source.validateDescriptor()
                    guard try snapshot(descriptor: fd, cancellation: cancellation) == expected else {
                        throw FTPError.localFile("来源内容与确认计划不符。")
                    }
                    let checked = try openSource(root: root, path: path, directories: directories, directory: false)
                    Darwin.close(checked)
                    try cancellation.checkCancellation()
                    continuation.resume(returning: source)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Immutable lease ownership: asynchronous C calls retain this object until backend stop.
    final class VerifiedSource: @unchecked Sendable {
        let url: URL
        let expected: Snapshot
        private let lease: LocalRootAccess.Lease
        private let ownedDescriptor: Int32?
        var descriptor: Int32 { ownedDescriptor ?? lease.descriptor }
        fileprivate init(root: LocalSourceRoot, expected: Snapshot) throws {
            guard root.identity.kind == .regularFile else { throw FTPError.localFile("来源不是普通文件。") }
            url = root.url; self.expected = expected; lease = try root.lease(); ownedDescriptor = nil
        }
        fileprivate init(url: URL, descriptor: Int32, lease: LocalRootAccess.Lease, expected: Snapshot) {
            self.url = url; ownedDescriptor = descriptor; self.lease = lease; self.expected = expected
        }
        deinit { if let ownedDescriptor { Darwin.close(ownedDescriptor) } }
        func validateDescriptor() throws {
            var value = stat()
            guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
                  UInt64(value.st_dev) == expected.device, UInt64(value.st_ino) == expected.inode,
                  value.st_size == expected.size,
                  Date(timeIntervalSince1970: Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1_000_000_000) == expected.modified else {
                throw FTPError.localFile("已验证的来源句柄发生变化，未开始发送。")
            }
        }
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
