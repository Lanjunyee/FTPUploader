import XCTest

final class InMemorySites: SiteStoring {
    var sites: [FTPSite]
    init(_ sites: [FTPSite] = []) { self.sites = sites }
    func load() throws -> [FTPSite] { sites }
    func save(_ sites: [FTPSite]) throws { self.sites = sites }
}

@MainActor
final class DelayedPasswords: PasswordStoring {
    var reads: [(UUID, CheckedContinuation<String?, Error>)] = []
    func password(for site: FTPSite) async throws -> String? {
        try await withCheckedThrowingContinuation { reads.append((site.id, $0)) }
    }
    func save(_ password: String, for site: FTPSite) async throws {}
    func remove(id: UUID) async throws {}
}

@MainActor
func isolatedHistory() -> TransferHistory {
    TransferHistory(url: FileManager.default.temporaryDirectory.appendingPathComponent("transfer-test-" + UUID().uuidString).appendingPathComponent("history.json"))
}

@MainActor
final class ControlledFTP: FTPServing {
    let diagnostics: TransferDiagnostics?
    init(diagnostics: TransferDiagnostics? = nil) { self.diagnostics = diagnostics }
    struct BrowseRequest {
        let endpoint: FTPEndpoint
        let path: RemotePath
        let credentials: FTPCredentials
        let cancellation: FTPCancellationToken
        let continuation: CheckedContinuation<DirectoryListing, Error>
    }
    struct UploadRequest {
        let name: String
        let endpoint: FTPEndpoint
        let path: RemotePath
        let credentials: FTPCredentials
        let cancellation: FTPCancellationToken
        let progress: (Int64, Int64) -> Void
        let continuation: CheckedContinuation<Void, Error>
    }
    struct DownloadRequest {
        let path: RemotePath
        let credentials: FTPCredentials
        let cancellation: FTPCancellationToken
        let receive: (Data) throws -> Void
        let progress: (Int64, Int64) -> Void
        let continuation: CheckedContinuation<Void, Error>
    }
    struct DirectoryRequest {
        let path: RemotePath
        let credentials: FTPCredentials
        let cancellation: FTPCancellationToken
        let continuation: CheckedContinuation<Void, Error>
    }
    var directories: [DirectoryRequest] = []
    func createDirectory(endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding,
                         credentials: FTPCredentials, cancellation: FTPCancellationToken) async throws {
        try await withCheckedThrowingContinuation {
            directories.append(.init(path: path, credentials: credentials, cancellation: cancellation, continuation: $0))
        }
    }
    var downloads: [DownloadRequest] = []
    func download(endpoint: FTPEndpoint, path: RemotePath, credentials: FTPCredentials, cancellation: FTPCancellationToken,
                  receive: @escaping (Data) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws {
        try await withCheckedThrowingContinuation {
            downloads.append(DownloadRequest(path: path, credentials: credentials, cancellation: cancellation,
                                              receive: receive, progress: progress, continuation: $0))
        }
    }
    var browses: [BrowseRequest] = []
    var uploads: [UploadRequest] = []
    var uploadSources: [SelectedLocalFile.VerifiedSource] = []
    func upload(endpoint: FTPEndpoint, path: RemotePath, source: SelectedLocalFile.VerifiedSource,
                encoding: FTPTextEncoding, credentials: FTPCredentials, cancellation: FTPCancellationToken,
                progress: @escaping (Int64, Int64) -> Void) async throws {
        try source.validateDescriptor()
        uploadSources.append(source)
        defer { uploadSources.removeAll { $0 === source } }
        try await upload(endpoint: endpoint, path: path, file: source.url, encoding: encoding,
                         credentials: credentials, cancellation: cancellation, progress: progress)
    }
    var autoCheckTargets = true
    private(set) var previewTargetListingCount = 0

    func listPreviewTargets(endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding,
                            credentials: FTPCredentials, cancellation: FTPCancellationToken) async throws -> DirectoryListing {
        previewTargetListingCount += 1
        if autoCheckTargets {
            try cancellation.checkCancellation(); diagnostics?.record(.listings)
            return .init(entries: [], encoding: encoding)
        }
        return try await list(endpoint: endpoint, path: path, encoding: encoding, credentials: credentials, cancellation: cancellation)
    }

    func checkUploadTarget(endpoint: FTPEndpoint, path: RemotePath, name: String, encoding: FTPTextEncoding,
                           credentials: FTPCredentials, cancellation: FTPCancellationToken) async throws -> RemoteEntry? {
        if autoCheckTargets { return nil }
        let listing = try await list(endpoint: endpoint, path: path, encoding: encoding, credentials: credentials, cancellation: cancellation)
        try cancellation.checkCancellation()
        let bytes = try encoding.encode(name)
        return try listing.indexed(names: [bytes], cancellation: cancellation)[bytes]
    }
    func list(endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding?, credentials: FTPCredentials, cancellation: FTPCancellationToken) async throws -> DirectoryListing {
        diagnostics?.record(.listings)
        return try await withCheckedThrowingContinuation {
            browses.append(BrowseRequest(endpoint: endpoint, path: path, credentials: credentials, cancellation: cancellation, continuation: $0))
        }
    }
    func upload(endpoint: FTPEndpoint, path: RemotePath, file: URL, encoding: FTPTextEncoding, credentials: FTPCredentials, cancellation: FTPCancellationToken,
                progress: @escaping (Int64, Int64) -> Void) async throws {
        try await withCheckedThrowingContinuation {
            uploads.append(UploadRequest(name: file.lastPathComponent, endpoint: endpoint, path: path, credentials: credentials, cancellation: cancellation, progress: progress, continuation: $0))
        }
    }
}
