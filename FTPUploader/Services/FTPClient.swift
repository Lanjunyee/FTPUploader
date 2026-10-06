import Foundation

protocol FTPServing {
    func list(endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding?, credentials: FTPCredentials) async throws -> DirectoryListing
    func upload(endpoint: FTPEndpoint, path: RemotePath, file: URL, encoding: FTPTextEncoding, credentials: FTPCredentials,
                progress: @escaping (Int64, Int64) -> Void) async throws
}

final class FTPClient: FTPServing, @unchecked Sendable {
    private final class TransferContext {
        var data = Data()
        let progress: ((Int64, Int64) -> Void)?
        init(progress: ((Int64, Int64) -> Void)? = nil) { self.progress = progress }
    }

    private let queue = DispatchQueue(label: "local.ftpuploader.ftp", qos: .userInitiated)
    private let options: FTPOptions

    init(connectTimeout: Int = 15, responseTimeout: Int = 60, stallTimeout: Int = 60) {
        options = FTPOptions(connect_timeout: connectTimeout, response_timeout: responseTimeout, stall_timeout: stallTimeout)
    }

    func list(endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding? = nil, credentials: FTPCredentials = .anonymous) async throws -> DirectoryListing {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let url = endpoint.directoryURL(path)
                    let data: Data
                    let machineReadable: Bool
                    do {
                        data = try fetch(url: url, method: "MLSD", credentials: credentials)
                        machineReadable = true
                    } catch let error as FTPError where [500, 502, 504].contains(error.responseCode ?? 0) {
                        data = try fetch(url: url, method: "LIST", credentials: credentials)
                        machineReadable = false
                    }
                    let listing = try DirectoryParser.parse(data, machineReadable: machineReadable, preferredEncoding: encoding)
                    continuation.resume(returning: listing)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func fetch(url: String, method: String, credentials: FTPCredentials) throws -> Data {
        let context = TransferContext()
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        let result = credentials.username.withCString { user in
            credentials.password.withCString { password in
                ftp_list(url, method, user, password, options, { bytes, count, pointer in
            guard let bytes, let pointer else { return 0 }
            let context = Unmanaged<TransferContext>.fromOpaque(pointer).takeUnretainedValue()
            // A malformed server cannot allocate unlimited memory for a directory.
            guard count <= 16 * 1024 * 1024 - context.data.count else { return 0 }
            context.data.append(bytes, count: count)
            return 1
        }, pointer)
            }
        }
        try validate(result, upload: false, credentials: credentials)
        return context.data
    }

    func upload(endpoint: FTPEndpoint, path: RemotePath, file: URL, encoding: FTPTextEncoding, credentials: FTPCredentials = .anonymous,
                progress: @escaping (Int64, Int64) -> Void) async throws {
        let url = try endpoint.fileURL(path, name: file.lastPathComponent, encoding: encoding)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                let context = TransferContext(progress: progress)
                let pointer = Unmanaged.passUnretained(context).toOpaque()
                let result = credentials.username.withCString { user in
                    credentials.password.withCString { password in
                        ftp_upload(url, file.path, user, password, options, { sent, total, pointer in
                            guard let pointer else { return }
                            let context = Unmanaged<TransferContext>.fromOpaque(pointer).takeUnretainedValue()
                            context.progress?(sent, total)
                        }, pointer)
                    }
                }
                do {
                    try validate(result, upload: true, credentials: credentials)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func validate(_ result: FTPResult, upload: Bool, credentials: FTPCredentials) throws {
        guard result.code == 0 else {
            let message = withUnsafePointer(to: result) { String(cString: ftp_result_message($0)) }
            throw FTPError.transport(code: Int32(result.code), response: result.response_code, message: credentials.redacting(message), upload: upload, mode: credentials.mode)
        }
    }
}
