import Foundation

/// Owns directory-operation generations and the shared executor's read-only session.
/// Presentation and form validation remain with AppModel.
@MainActor
final class ConnectionSessionCoordinator {
    private let client: FTPServing
    private let executor: TransferExecutor
    private(set) var generation = 0
    private(set) var draftVersion = 0
    private(set) var cancellation: FTPCancellationToken?

    init(client: FTPServing, executor: TransferExecutor) {
        self.client = client
        self.executor = executor
    }

    func invalidate() {
        draftVersion += 1
        generation += 1
    }

    func begin() -> (generation: Int, cancellation: FTPCancellationToken) {
        generation += 1
        let token = FTPCancellationToken()
        cancellation = token
        return (generation, token)
    }

    func finish(_ id: Int) {
        guard generation == id else { return }
        cancellation = nil
    }

    func list(endpoint: FTPEndpoint, path: RemotePath, preferredEncoding: FTPTextEncoding?,
              policy: FTPEncodingPolicy, credentials: FTPCredentials,
              resolveInitial: Bool, cancellation: FTPCancellationToken) async throws -> (path: RemotePath, listing: DirectoryListing) {
        let connection = TransferConnectionOwner(base: client, endpoint: endpoint, credentials: credentials,
            executor: executor, readOnly: true)
        defer { connection.close() }
        let result: (path: RemotePath, listing: DirectoryListing)
        if resolveInitial {
            result = try await connection.resolveInitialDirectory(endpoint: endpoint, policy: policy,
                credentials: credentials, cancellation: cancellation)
        } else {
            let listing = try await connection.list(endpoint: endpoint, path: path, encoding: preferredEncoding,
                credentials: credentials, cancellation: cancellation)
            result = (path: path, listing: listing)
        }
        try cancellation.checkCancellation()
        return result
    }
}
