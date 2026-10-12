import XCTest

@MainActor
final class TransferTransportSessionTests: XCTestCase {
    private func job(_ endpoint: FTPEndpoint, credentials: FTPCredentials = .anonymous) -> TransferJob {
        TransferJob(direction: .upload, endpoint: endpoint, path: .root, encoding: .utf8,
            credentials: credentials, localURL: URL(fileURLWithPath: "/fixture/source"))
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw FTPError.localFile("Session fixture timed out")
    }
    func testHealthyOwnerUsesIndependentExpiringTokensAndTheSharedExecutor() async throws {
        let endpoint = try FTPEndpoint(address: "ftp://example.test"), executor = TransferExecutor()
        var closes = 0, tokens: [FTPCancellationToken] = []
        let configuration = TransportConfiguration()
        let session = TransferTransportSession(endpoint: endpoint, credentials: .anonymous,
            configuration: configuration, executor: executor, closeDriver: { closes += 1 })
        for _ in 0..<3 {
            let current = job(endpoint)
            try await executor.execute(current) {
                try await session.execute(job: current, endpoint: endpoint, credentials: .anonymous, configuration: configuration) { token in
                    XCTAssertTrue(executor.activeJob === current); XCTAssertFalse(token.isCancelled)
                    tokens.append(token)
                }
            }
            XCTAssertEqual(session.state, .open); XCTAssertNil(executor.activeJob)
        }
        XCTAssertEqual(Set(tokens.map(\.id)).count, 3)
        XCTAssertTrue(tokens.allSatisfy(\.isCancelled)); XCTAssertEqual(closes, 0)
        session.invalidate(); session.invalidate(); XCTAssertEqual(closes, 1); XCTAssertEqual(session.state, .closed)
    }
    func testContextChangesCloseWithoutInvokingAnotherOperation() async throws {
        let endpoint = try FTPEndpoint(address: "ftp://example.test"), credentials = try FTPCredentials.account(username: "member", password: "secret")
        let changed: [(FTPEndpoint, FTPCredentials, TransportConfiguration)] = [
            (try FTPEndpoint(address: "sftp://example.test"), credentials, .init()),
            (try FTPEndpoint(address: "ftps://example.test"), credentials, .init()),
            (try FTPEndpoint(address: "ftp://different.test"), credentials, .init()),
            (try FTPEndpoint(address: "ftp://example.test:2121"), credentials, .init()),
            (endpoint, try .account(username: "other", password: "secret"), .init()),
            (endpoint, try .account(username: "member", password: "changed"), .init()),
            (endpoint, .anonymous, .init()),
            (endpoint, credentials, .init(responseTimeout: 10))
        ]
        for (requestEndpoint, requestCredentials, configuration) in changed {
            let executor = TransferExecutor(); var closes = 0, calls = 0
            let session = TransferTransportSession(endpoint: endpoint, credentials: credentials, configuration: .init(),
                executor: executor, closeDriver: { closes += 1 })
            let current = job(requestEndpoint, credentials: requestCredentials)
            do {
                try await executor.execute(current) {
                    try await session.execute(job: current, endpoint: requestEndpoint, credentials: requestCredentials, configuration: configuration) { _ in calls += 1 }
                }
                XCTFail("Different context must not reuse")
            } catch {}
            XCTAssertEqual(calls, 0); XCTAssertEqual(closes, 1); XCTAssertEqual(session.state, .closed)
        }
    }
    func testEveryProtocolBoundaryAndJobSnapshotMismatchRejectReuse() async throws {
        let credentials = try FTPCredentials.account(username: "member", password: "secret")
        for transport in FileTransport.allCases {
            for other in FileTransport.allCases where other != transport {
                let endpoint = try FTPEndpoint(address: "example.test", transport: transport)
                let request = try FTPEndpoint(address: "example.test", transport: other), executor = TransferExecutor()
                var calls = 0, closes = 0
                let revision = UUID()
                let session = TransferTransportSession(endpoint: endpoint, credentials: credentials, configuration: .init(),
                    trustRevision: revision, executor: executor, closeDriver: { closes += 1 })
                let current = job(request, credentials: credentials)
                do {
                    try await executor.execute(current) {
                        // Even passing the old endpoint cannot authorize a differently bound job.
                        try await session.execute(job: current, endpoint: endpoint, credentials: credentials,
                            configuration: .init(), trustRevision: revision) { _ in calls += 1 }
                    }
                    XCTFail("Cross-protocol job accepted")
                } catch {}
                XCTAssertEqual(calls, 0); XCTAssertEqual(closes, 1)
            }
        }
    }
    func testSessionOwnerKeysDoNotBecomeAGlobalAuthenticationPool() throws {
        let endpoint = try FTPEndpoint(address: "example.test"), executor = TransferExecutor()
        var closes = 0
        var first: TransferTransportSession? = .init(endpoint: endpoint, credentials: .anonymous, configuration: .init(),
            executor: executor, closeDriver: { closes += 1 })
        let second = TransferTransportSession(endpoint: endpoint, credentials: .anonymous, configuration: .init(),
            executor: executor, closeDriver: { closes += 1 })
        XCTAssertNotEqual(first?.key, second.key)
        first = nil; XCTAssertEqual(closes, 1)
        second.invalidate(); XCTAssertEqual(closes, 2)
    }
    func testSFTPTrustRevisionChangeOrMissingEvidenceCannotReuse() async throws {
        let endpoint = try FTPEndpoint(address: "sftp://example.test"), credentials = try FTPCredentials.account(username: "member", password: "secret")
        for revision in [UUID?.some(UUID()), nil] {
            let executor = TransferExecutor(); var closes = 0, calls = 0
            let session = TransferTransportSession(endpoint: endpoint, credentials: credentials, configuration: .init(),
                trustRevision: revision, executor: executor, closeDriver: { closes += 1 })
            let first = job(endpoint, credentials: credentials)
            try await executor.execute(first) {
                try await session.execute(job: first, endpoint: endpoint, credentials: credentials, configuration: .init(), trustRevision: revision) { _ in calls += 1 }
            }
            let second = job(endpoint, credentials: credentials)
            do {
                try await executor.execute(second) {
                    try await session.execute(job: second, endpoint: endpoint, credentials: credentials, configuration: .init(), trustRevision: revision == nil ? nil : UUID()) { _ in calls += 1 }
                }
                XCTFail("Changed or absent trust evidence must reject reuse")
            } catch {}
            XCTAssertEqual(calls, 1); XCTAssertEqual(closes, 1)
        }
    }
    func testConcurrentOperationsAndInvalidationWaitForBackendStop() async throws {
        let endpoint = try FTPEndpoint(address: "ftp://example.test"), executor = TransferExecutor()
        var closes = 0, pending: CheckedContinuation<Void, Error>?, token: FTPCancellationToken?
        let session = TransferTransportSession(endpoint: endpoint, credentials: .anonymous, configuration: .init(),
            executor: executor, closeDriver: { closes += 1 })
        let current = job(endpoint)
        let task = Task {
            try await executor.execute(current) {
                try await session.execute(job: current, endpoint: endpoint, credentials: .anonymous, configuration: .init()) { operationToken in
                    token = operationToken
                    try await withCheckedThrowingContinuation { pending = $0 }
                }
            }
        }
        try await wait { pending != nil }
        do {
            try await session.execute(job: current, endpoint: endpoint, credentials: .anonymous, configuration: .init()) { _ in XCTFail("Second operation started") }
            XCTFail("Concurrent operation admitted")
        } catch {}
        do { try await executor.execute(job(endpoint)) { XCTFail("Second job started") }; XCTFail("Second job admitted") } catch {}
        session.invalidate(); XCTAssertEqual(session.state, .invalidating)
        XCTAssertTrue(token?.isCancelled == true); XCTAssertEqual(closes, 0); XCTAssertTrue(executor.activeJob === current)
        pending?.resume(); pending = nil
        do { try await task.value; XCTFail("Invalidated operation reported success") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        XCTAssertEqual(closes, 1); XCTAssertEqual(session.state, .closed); XCTAssertNil(executor.activeJob)
    }
    func testFailureClosesWithoutRetryAndSessionRequiresExecutorOwnership() async throws {
        let endpoint = try FTPEndpoint(address: "ftp://example.test"), executor = TransferExecutor()
        var closes = 0, calls = 0
        let session = TransferTransportSession(endpoint: endpoint, credentials: .anonymous, configuration: .init(),
            executor: executor, closeDriver: { closes += 1 })
        let current = job(endpoint)
        do {
            try await session.execute(job: current, endpoint: endpoint, credentials: .anonymous, configuration: .init()) { _ in calls += 1 }
            XCTFail("Unowned job admitted")
        } catch {}
        XCTAssertEqual(session.state, .open); XCTAssertEqual(calls, 0)
        do {
            try await executor.execute(current) {
                try await session.execute(job: current, endpoint: endpoint, credentials: .anonymous, configuration: .init()) { _ in
                    calls += 1; throw FTPError.localFile("backend rejected")
                }
            }
            XCTFail("Failure swallowed")
        } catch {}
        XCTAssertEqual(calls, 1); XCTAssertEqual(closes, 1); XCTAssertNil(executor.activeJob)
    }
    func testParentCancellationPropagatesWithoutChildCancellingAnotherOperation() {
        let parent = FTPCancellationToken(), first = FTPCancellationToken(), second = FTPCancellationToken()
        let child = FTPCancellationToken(parent: parent)
        first.cancel(); XCTAssertFalse(second.isCancelled); XCTAssertFalse(child.isCancelled)
        child.cancel(); XCTAssertFalse(parent.isCancelled)
        let next = FTPCancellationToken(parent: parent); XCTAssertFalse(next.isCancelled)
        parent.cancel(); XCTAssertTrue(next.isCancelled)
    }
    func testCAContentChangeWithSameSizeAndRestoredMtimeClosesBeforeOperation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("original CA".utf8).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
        let ca = try TransportCAFile(url: url, cancellation: .init()), configuration = TransportConfiguration(ca: ca)
        let endpoint = try FTPEndpoint(address: "ftps://example.test"), executor = TransferExecutor()
        var closes = 0, calls = 0
        let session = TransferTransportSession(endpoint: endpoint, credentials: .anonymous, configuration: configuration,
            executor: executor, closeDriver: { closes += 1 })
        let first = job(endpoint)
        try await executor.execute(first) {
            try await session.execute(job: first, endpoint: endpoint, credentials: .anonymous, configuration: configuration) { _ in calls += 1 }
        }
        try Data("modified CA".utf8).write(to: url)
        if let mtime { try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path) }
        let second = job(endpoint)
        do {
            try await executor.execute(second) {
                try await session.execute(job: second, endpoint: endpoint, credentials: .anonymous, configuration: configuration) { _ in calls += 1 }
            }
            XCTFail("Changed CA reused")
        } catch {}
        XCTAssertEqual(calls, 1); XCTAssertEqual(closes, 1); XCTAssertFalse(session.key.description.contains(url.path))
        XCTAssertEqual(ca.description, "TransportCAFile([redacted])")
    }
    func testMissingCAAndCancelledCaptureFailWithoutInvokingBackend() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("CA".utf8).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let cancelled = FTPCancellationToken(); cancelled.cancel()
        XCTAssertThrowsError(try TransportCAFile(url: url, cancellation: cancelled))
        let ca = try TransportCAFile(url: url, cancellation: .init())
        let endpoint = try FTPEndpoint(address: "example.test", transport: .ftpsExplicit), executor = TransferExecutor()
        var calls = 0, closes = 0
        let configuration = TransportConfiguration(ca: ca)
        let session = TransferTransportSession(endpoint: endpoint, credentials: .anonymous, configuration: configuration,
            executor: executor, closeDriver: { closes += 1 })
        try FileManager.default.removeItem(at: url)
        let current = job(endpoint)
        do {
            try await executor.execute(current) {
                try await session.execute(job: current, endpoint: endpoint, credentials: .anonymous, configuration: configuration) { _ in calls += 1 }
            }
            XCTFail("Missing CA allowed backend")
        } catch {}
        XCTAssertEqual(calls, 0); XCTAssertEqual(closes, 1)
    }
    func testRealCurlSessionReusesControlConnectionAcrossBinaryOperationsForThreeProtocols() async throws {
        let caPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/tls-fixtures/ca.pem").path
        for transport in [FileTransport.ftp, .ftpsExplicit, .ftpsImplicit] {
            let fixture = try FTPFixture(transport: transport, countOperations: true); defer { fixture.stop() }
            let executor = TransferExecutor(), endpoint = fixture.endpoint
            let client = FTPClient(caFile: transport.requiresTLS ? caPath : nil)
            let session = try await client.makeCurlSession(endpoint: endpoint, credentials: .anonymous, executor: executor)
            defer { session.invalidate() }
            let payload = Data((0..<4096).map { UInt8($0 % 256) })
            let source = FileManager.default.temporaryDirectory.appendingPathComponent("curl-session-" + UUID().uuidString + ".bin")
            try payload.write(to: source); defer { try? FileManager.default.removeItem(at: source) }
            let first = job(endpoint)
            try await executor.execute(first) {
                _ = try await session.list(endpoint: endpoint, path: .root, encoding: .utf8, credentials: .anonymous, cancellation: first.cancellation)
            }
            let upload = job(endpoint)
            try await executor.execute(upload) {
                try await session.upload(endpoint: endpoint, path: .root, file: source, encoding: .utf8, credentials: .anonymous, cancellation: upload.cancellation) { _, _ in }
            }
            let path = try RemotePath.root.appending(name: source.lastPathComponent, bytes: Data(source.lastPathComponent.utf8))
            let download = job(endpoint); var received = Data()
            try await executor.execute(download) {
                try await session.download(endpoint: endpoint, path: path, credentials: .anonymous, cancellation: download.cancellation,
                    receive: { received.append($0) }, progress: { _, _ in })
            }
            XCTAssertEqual(received, payload)
            let directory = try RemotePath.root.appending(name: "session-directory", bytes: Data("session-directory".utf8)), mkdir = job(endpoint)
            try await executor.execute(mkdir) {
                try await session.createDirectory(endpoint: endpoint, path: directory, encoding: .utf8, credentials: .anonymous, cancellation: mkdir.cancellation)
            }
            let last = job(endpoint); var listing: DirectoryListing?
            try await executor.execute(last) {
                listing = try await session.list(endpoint: endpoint, path: .root, encoding: .utf8, credentials: .anonymous, cancellation: last.cancellation)
            }
            XCTAssertTrue(listing?.entries.contains { $0.name == source.lastPathComponent && $0.size == Int64(payload.count) } == true)
            XCTAssertTrue(listing?.entries.contains { $0.name == "session-directory" && $0.kind == .directory } == true)
            let counts = try XCTUnwrap(fixture.operationCounts())
            XCTAssertEqual(counts["connections"], 1, transport.rawValue); XCTAssertEqual(counts["authentications"], 1)
            let commands = try fixture.commands()
            XCTAssertEqual(commands.filter { $0["command"] == "STOR" }.count, 1)
            XCTAssertEqual(commands.filter { $0["command"] == "RETR" }.count, 1)
            XCTAssertEqual(commands.filter { $0["command"] == "MKD" }.count, 1)
            if transport.requiresTLS {
                XCTAssertTrue(commands.filter { ["STOR", "RETR", "MLSD", "MKD"].contains($0["command"] ?? "") }.allSatisfy { $0["control_tls"] == "yes" })
            }
        }
    }
    func testScopedFTPSInvalidCertificatesAndDataTLSNeverSucceedOrDowngrade() async throws {
        let caPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/tls-fixtures/ca.pem").path
        for transport in [FileTransport.ftpsExplicit, .ftpsImplicit] {
            for certificate in ["expired", "wrong", "self", "good"] {
                let fixture = try FTPFixture(transport: transport, certificate: certificate, failDataTLS: certificate == "good"); defer { fixture.stop() }
                let executor = TransferExecutor(), credentials = try FTPCredentials.account(username: "member", password: "fixture-pass:@ ")
                let session = try await FTPClient(caFile: caPath).makeCurlSession(endpoint: fixture.endpoint, credentials: credentials, executor: executor)
                defer { session.invalidate() }
                let current = job(fixture.endpoint, credentials: credentials)
                do {
                    try await executor.execute(current) {
                        _ = try await session.list(endpoint: fixture.endpoint, path: .root, encoding: .utf8, credentials: credentials, cancellation: current.cancellation)
                    }
                    XCTFail("Invalid TLS accepted")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("TLS")); XCTAssertFalse(error.localizedDescription.contains(credentials.password))
                }
                XCTAssertEqual(session.lifecycle.state, .closed)
                let commands = try fixture.commands()
                if certificate != "good" { XCTAssertFalse(commands.contains { $0["command"] == "PASS" }) }
                XCTAssertFalse(commands.contains { $0["data_tls"] == "no" })
            }
        }
    }
    func testScopedFailureAndFinalWaitCancellationCloseWithoutSecondStore() async throws {
        for name in ["最终拒绝", "等待确认"] {
            let fixture = try FTPFixture(delay: 10, countOperations: true); defer { fixture.stop() }
            let executor = TransferExecutor(), endpoint = fixture.endpoint
            let session = try await FTPClient().makeCurlSession(endpoint: endpoint, credentials: .anonymous, executor: executor)
            defer { session.invalidate() }
            let first = job(endpoint)
            try await executor.execute(first) {
                _ = try await session.list(endpoint: endpoint, path: .root, encoding: .utf8, credentials: .anonymous, cancellation: first.cancellation)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
            try Data("payload".utf8).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
            let path = try RemotePath.root.appending(name: name, bytes: Data(name.utf8)), current = job(endpoint)
            let task = Task {
                try await executor.execute(current) {
                    try await session.upload(endpoint: endpoint, path: path, file: url, encoding: .utf8, credentials: .anonymous, cancellation: current.cancellation) { _, _ in }
                }
            }
            if name == "等待确认" {
                let received = fixture.root.appendingPathComponent(name).appendingPathComponent(url.lastPathComponent)
                try await wait { (try? Data(contentsOf: received)) == Data("payload".utf8) }
                session.invalidate(); XCTAssertTrue(executor.activeJob === current)
            }
            do { try await task.value; XCTFail("Failed/cancelled store succeeded") } catch {}
            XCTAssertEqual(session.lifecycle.state, .closed); XCTAssertNil(executor.activeJob)
            let later = job(endpoint)
            do {
                try await executor.execute(later) {
                    try await session.upload(endpoint: endpoint, path: .root, file: url, encoding: .utf8, credentials: .anonymous, cancellation: later.cancellation) { _, _ in }
                }
                XCTFail("Closed session performed another write")
            } catch {}
            XCTAssertEqual(try fixture.commands().filter { $0["command"] == "STOR" }.count, 1)
            XCTAssertEqual(try fixture.operationCounts()?["connections"], 1)
        }
    }
    func testUnsupportedMLSDUsesFreshReadOnlyLISTWithoutRepeatingMLSDOrWrites() async throws {
        let fixture = try FTPFixture(scenario: "no-mlsd", countOperations: true); defer { fixture.stop() }
        let executor = TransferExecutor(), current = job(fixture.endpoint)
        let session = try await FTPClient().makeCurlSession(endpoint: fixture.endpoint, credentials: .anonymous, executor: executor)
        defer { session.invalidate() }
        try await executor.execute(current) {
            _ = try await session.list(endpoint: fixture.endpoint, path: .root, encoding: nil, credentials: .anonymous, cancellation: current.cancellation)
        }
        let commands = try fixture.commands()
        XCTAssertEqual(commands.filter { $0["command"] == "MLSD" }.count, 1)
        XCTAssertEqual(commands.filter { $0["command"] == "LIST" }.count, 1)
        XCTAssertFalse(commands.contains { ["STOR", "RETR", "MKD"].contains($0["command"] ?? "") })
        XCTAssertEqual(try fixture.operationCounts()?["connections"], 2)
    }
    func testScopedSFTPPasswordAndPrivateKeyFormatsReuseVerifiedAuthenticatedSession() async throws {
        for mode in ["password", "openssh-ed25519", "openssh-rsa", "pem-rsa", "pkcs8-rsa"] {
            for encrypted in mode == "password" ? [false] : [false, true] {
                let fixture = try SFTPFixture(keyAuth: mode != "password", countOperations: true); defer { fixture.stop() }
                let store = HostTrustStore(url: fixture.root.appendingPathComponent(".trusted.json"))
                try store.trust(fixture.identity)
                let credentials: FTPCredentials
                if mode == "password" {
                    credentials = try .account(username: "member", password: "fixture-pass:@ ")
                } else {
                    let material = try PrivateKeyAccess().read(fixture.root.appendingPathComponent(".keys/" + mode + (encrypted ? "-encrypted" : "")))
                    credentials = try .key(username: "member", material: material, passphrase: encrypted ? " 密钥口令:@ " : nil)
                }
                let endpoint = fixture.endpoint, executor = TransferExecutor()
                let session = try FTPClient(responseTimeout: 4, stallTimeout: 4, trust: store)
                    .makeSSHSession(endpoint: endpoint, credentials: credentials, executor: executor)
                defer { session.invalidate() }
                let first = job(endpoint, credentials: credentials)
                try await executor.execute(first) {
                    _ = try await session.list(endpoint: endpoint, path: .root, encoding: .utf8, credentials: credentials, cancellation: first.cancellation)
                }
                // Public-key SSH may use both a probe and a signed authentication request.
                let initialAuthentications = try fixture.operationCounts()?["authentications"]
                let initialKeyCallbacks = try fixture.commands().filter { $0["command"] == "AUTH_KEY" }.count
                XCTAssertEqual(initialKeyCallbacks, mode == "password" ? 0 : 2)
                let source = fixture.root.appendingPathComponent(".inputs/session.bin")
                try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                let remote = try RemotePath.root.appending(name: source.lastPathComponent, bytes: Data(source.lastPathComponent.utf8))
                for payload in [Data([0, 255, 10, 128]), Data()] {
                    try payload.write(to: source)
                    let upload = job(endpoint, credentials: credentials)
                    try await executor.execute(upload) {
                        try await session.upload(endpoint: endpoint, path: .root, file: source, encoding: .utf8, credentials: credentials,
                            cancellation: upload.cancellation, progress: { _, _ in })
                    }
                    var received = Data(); let download = job(endpoint, credentials: credentials)
                    try await executor.execute(download) {
                        try await session.download(endpoint: endpoint, path: remote, credentials: credentials, cancellation: download.cancellation,
                            receive: { received.append($0) }, progress: { _, _ in })
                    }
                    XCTAssertEqual(received, payload, mode)
                }
                let mkdir = job(endpoint, credentials: credentials)
                let directory = try RemotePath.root.appending(name: "session-directory", bytes: Data("session-directory".utf8))
                try await executor.execute(mkdir) {
                    try await session.createDirectory(endpoint: endpoint, path: directory, encoding: .utf8, credentials: credentials, cancellation: mkdir.cancellation)
                }
                let last = job(endpoint, credentials: credentials)
                try await executor.execute(last) {
                    let listing = try await session.list(endpoint: endpoint, path: .root, encoding: .utf8, credentials: credentials, cancellation: last.cancellation)
                    XCTAssertTrue(listing.entries.contains { $0.name == "session-directory" && $0.kind == .directory })
                }
                XCTAssertEqual(try fixture.operationCounts()?["connections"], 1, mode)
                let commands = try fixture.commands()
                XCTAssertEqual(commands.filter { $0["command"] == "AUTH" }.count, mode == "password" ? 1 : 0)
                XCTAssertEqual(commands.filter { $0["command"] == "AUTH_KEY" }.count, initialKeyCallbacks)
                XCTAssertEqual(try fixture.operationCounts()?["authentications"], initialAuthentications)
                XCTAssertEqual(session.lifecycle.state, .open)
            }
        }
    }

    func testScopedSFTPFailedHandleClosesWithoutReconnectOrRepeatingWrite() async throws {
        let fixture = try SFTPFixture(countOperations: true); defer { fixture.stop() }
        let store = HostTrustStore(url: fixture.root.appendingPathComponent(".trusted.json")); try store.trust(fixture.identity)
        let credentials = try FTPCredentials.account(username: "member", password: "fixture-pass:@ ")
        let executor = TransferExecutor(), endpoint = fixture.endpoint
        let session = try FTPClient(responseTimeout: 3, trust: store).makeSSHSession(endpoint: endpoint, credentials: credentials, executor: executor)
        defer { session.invalidate() }
        let first = job(endpoint, credentials: credentials)
        try await executor.execute(first) {
            _ = try await session.list(endpoint: endpoint, path: .root, encoding: .utf8, credentials: credentials, cancellation: first.cancellation)
        }
        let invalidParent = try RemotePath.root.appending(name: "missing-parent", bytes: Data("missing-parent".utf8))
        let path = try invalidParent.appending(name: "child", bytes: Data("child".utf8))
        let failed = job(endpoint, credentials: credentials)
        do {
            try await executor.execute(failed) {
                try await session.createDirectory(endpoint: endpoint, path: path, encoding: .utf8, credentials: credentials, cancellation: failed.cancellation)
            }
            XCTFail("Failed mkdir accepted")
        } catch {}
        XCTAssertEqual(session.lifecycle.state, .closed); XCTAssertNil(executor.activeJob)
        let before = try fixture.commands(), next = job(endpoint, credentials: credentials)
        do {
            try await executor.execute(next) {
                try await session.createDirectory(endpoint: endpoint, path: path, encoding: .utf8, credentials: credentials, cancellation: next.cancellation)
            }
            XCTFail("Closed session repeated write")
        } catch {}
        XCTAssertEqual(try fixture.commands(), before)
        XCTAssertEqual(try fixture.operationCounts()?["connections"], 1)
    }

    func testScopedSFTPUnknownChangedAndResetTrustNeverBypassAuthority() async throws {
        let fixture = try SFTPFixture(countOperations: true); defer { fixture.stop() }
        let url = fixture.root.appendingPathComponent(".trusted.json"), store = HostTrustStore(url: fixture.root.appendingPathComponent(".trusted.json"))
        let credentials = try FTPCredentials.account(username: "member", password: "fixture-pass:@ ")
        let executor = TransferExecutor(), client = FTPClient(trust: store)
        for changed in [false, true] {
            if changed { try store.trust(SSHHostIdentity(host: fixture.identity.host, port: fixture.identity.port, key: fixture.identity.key + Data([1]))) }
            let session = try client.makeSSHSession(endpoint: fixture.endpoint, credentials: credentials, executor: executor)
            let current = job(fixture.endpoint, credentials: credentials)
            do {
                try await executor.execute(current) {
                    _ = try await session.list(endpoint: fixture.endpoint, path: .root, encoding: .utf8, credentials: credentials, cancellation: current.cancellation)
                }
                XCTFail("Unverified host authenticated")
            } catch is HostTrustError {}
            XCTAssertEqual(session.lifecycle.state, .closed)
        }
        XCTAssertEqual(try fixture.operationCounts()?["authentications"], 0)
        try store.reset(host: fixture.identity.host, port: fixture.identity.port); try store.trust(fixture.identity)
        let session = try client.makeSSHSession(endpoint: fixture.endpoint, credentials: credentials, executor: executor)
        defer { session.invalidate() }
        let first = job(fixture.endpoint, credentials: credentials)
        try await executor.execute(first) {
            _ = try await session.list(endpoint: fixture.endpoint, path: .root, encoding: .utf8, credentials: credentials, cancellation: first.cancellation)
        }
        let before = try fixture.operationCounts()
        try HostTrustStore(url: url).reset(host: fixture.identity.host, port: fixture.identity.port)
        let second = job(fixture.endpoint, credentials: credentials)
        do {
            try await executor.execute(second) {
                _ = try await session.list(endpoint: fixture.endpoint, path: .root, encoding: .utf8, credentials: credentials, cancellation: second.cancellation)
            }
            XCTFail("Reset authority reused session")
        } catch {}
        XCTAssertEqual(session.lifecycle.state, .closed)
        XCTAssertEqual(try fixture.operationCounts(), before)
    }

    func testOwnerPauseExpiresAtSixtySecondsAndOnlyExplicitResumeOpensFreshConnection() async throws {
        let fixture = try FTPFixture(countOperations: true); defer { fixture.stop() }
        let executor = TransferExecutor()
        var delays: [Double] = [], actions: [@MainActor () -> Void] = [], cancellations = 0
        let owner = TransferConnectionOwner(base: FTPClient(), endpoint: fixture.endpoint, credentials: .anonymous, executor: executor,
            schedule: { delay, action in delays.append(delay); actions.append(action); return { cancellations += 1 } })
        let first = job(fixture.endpoint)
        try await executor.execute(first) {
            _ = try await owner.list(endpoint: fixture.endpoint, path: .root, encoding: .utf8, credentials: .anonymous, cancellation: first.cancellation)
        }
        owner.pause(); owner.pause()
        XCTAssertEqual(delays, [60, 60]); XCTAssertEqual(cancellations, 1)
        actions[0](); XCTAssertEqual(owner.lifecycleState, .open)
        actions[1](); XCTAssertTrue(owner.idleExpired); XCTAssertNil(owner.lifecycleState)
        let before = try fixture.operationCounts(), token = FTPCancellationToken()
        do {
            _ = try await owner.list(endpoint: fixture.endpoint, path: .root, encoding: .utf8, credentials: .anonymous, cancellation: token)
            XCTFail("Expired pause silently reconnected")
        } catch {}
        XCTAssertEqual(try fixture.operationCounts(), before)
        owner.resume()
        _ = try await owner.list(endpoint: fixture.endpoint, path: .root, encoding: .utf8, credentials: .anonymous, cancellation: token)
        XCTAssertEqual(try fixture.operationCounts()?["connections"], 2)
        owner.close()
        do {
            _ = try await owner.list(endpoint: fixture.endpoint, path: .root, encoding: .utf8, credentials: .anonymous, cancellation: token)
            XCTFail("Ended owner reconnected")
        } catch {}
        XCTAssertEqual(try fixture.operationCounts()?["connections"], 2)
    }

    func testOwnerDirectoryFailureUsesOneFreshReadWithoutRepeatingMkdirAcrossProtocols() async throws {
        for transport in [FileTransport.ftp, .ftpsExplicit, .ftpsImplicit, .sftp] {
            let ftp = transport == .sftp ? nil : try FTPFixture(transport: transport, countOperations: true)
            let ssh = transport == .sftp ? try SFTPFixture(scenario: "mkdir-after-create-error", countOperations: true) : nil
            defer { ftp?.stop(); ssh?.stop() }
            let endpoint = ftp?.endpoint ?? ssh!.endpoint, root = ftp?.root ?? ssh!.root
            let trust = HostTrustStore(url: root.appendingPathComponent(".trusted.json"))
            if let ssh { try trust.trust(ssh.identity) }
            let credentials: FTPCredentials = transport == .sftp ? try .account(username: "member", password: "fixture-pass:@ ") : .anonymous
            let ca = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/tls-fixtures/ca.pem").path
            let client = FTPClient(caFile: ca, trust: trust), executor = TransferExecutor()
            let owner = TransferConnectionOwner(base: client, endpoint: endpoint, credentials: credentials, executor: executor)
            defer { owner.close() }
            // FTP returns a deliberately wrong final 250 after actually creating the directory.
            let parent = transport == .sftp ? RemotePath.root : try RemotePath.root.appending(name: "最终拒绝", bytes: Data("最终拒绝".utf8))
            let target = try parent.appending(name: "created-once", bytes: Data("created-once".utf8))
            let current = job(endpoint, credentials: credentials); var result: RemoteDirectoryResult?
            try await executor.execute(current) {
                result = try await owner.ensureDirectory(endpoint: endpoint, path: target, encoding: .utf8,
                    credentials: credentials, cancellation: current.cancellation)
            }
            XCTAssertEqual(result, .verifiedAfterError)
            let commands = try ftp?.commands() ?? ssh!.commands()
            XCTAssertEqual(commands.filter { ["MKD", "MKDIR"].contains($0["command"] ?? "") }.count, 1)
            XCTAssertEqual(commands.filter { ["MLSD", "LIST"].contains($0["command"] ?? "") }.count, 2)
            XCTAssertFalse(commands.contains { ["STOR", "RETR", "OPEN"].contains($0["command"] ?? "") })
            let counts = try ftp?.operationCounts() ?? ssh!.operationCounts()
            XCTAssertEqual(counts?["connections"], 2)
        }
    }

    func testOwnerReadOnlyScanRejectsWritesAndFailedOwnerRequiresExplicitContinue() async throws {
        let fixture = try FTPFixture(countOperations: true); defer { fixture.stop() }
        let executor = TransferExecutor(), scan = TransferConnectionOwner(base: FTPClient(), endpoint: fixture.endpoint,
            credentials: .anonymous, executor: executor, readOnly: true)
        let path = try RemotePath.root.appending(name: "must-not-create", bytes: Data("must-not-create".utf8))
        do {
            try await scan.createDirectory(endpoint: fixture.endpoint, path: path, encoding: .utf8, credentials: .anonymous, cancellation: .init())
            XCTFail("Scan issued a write")
        } catch {}
        XCTAssertEqual(try fixture.operationCounts()?["connections"], 0)
        _ = try await scan.list(endpoint: fixture.endpoint, path: .root, encoding: .utf8, credentials: .anonymous, cancellation: .init())
        scan.close()
        let owner = TransferConnectionOwner(base: FTPClient(), endpoint: fixture.endpoint, credentials: .anonymous, executor: executor)
        defer { owner.close() }
        _ = try await owner.list(endpoint: fixture.endpoint, path: .root, encoding: .utf8, credentials: .anonymous, cancellation: .init())
        do {
            _ = try await owner.list(endpoint: fixture.endpoint, path: path, encoding: .utf8, credentials: .anonymous, cancellation: .init())
            XCTFail("Missing directory accepted")
        } catch {}
        let before = try fixture.operationCounts()
        do {
            _ = try await owner.list(endpoint: fixture.endpoint, path: .root, encoding: .utf8, credentials: .anonymous, cancellation: .init())
            XCTFail("Failed owner silently reconnected")
        } catch {}
        XCTAssertEqual(try fixture.operationCounts(), before)
        owner.resume()
        _ = try await owner.list(endpoint: fixture.endpoint, path: .root, encoding: .utf8, credentials: .anonymous, cancellation: .init())
        XCTAssertEqual(try fixture.operationCounts()?["connections"], (before?["connections"] ?? 0) + 1)
    }

    func testDeadReusableCurlControlConnectionCannotSilentlyReconnectForAWrite() async throws {
        let ca = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/tls-fixtures/ca.pem").path
        for transport in [FileTransport.ftp, .ftpsExplicit, .ftpsImplicit] {
            let fixture = try FTPFixture(scenario: "close-after-list", transport: transport, countOperations: true); defer { fixture.stop() }
            let executor = TransferExecutor(), owner = TransferConnectionOwner(base: FTPClient(caFile: ca), endpoint: fixture.endpoint,
                credentials: .anonymous, executor: executor)
            defer { owner.close() }
            _ = try await owner.list(endpoint: fixture.endpoint, path: .root, encoding: .utf8, credentials: .anonymous, cancellation: .init())
            try await Task.sleep(nanoseconds: 100_000_000)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
            try Data([0, 255, 10]).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
            let current = job(fixture.endpoint)
            do {
                try await executor.execute(current) {
                    try await owner.upload(endpoint: fixture.endpoint, path: .root, file: url, encoding: .utf8, credentials: .anonymous,
                        cancellation: current.cancellation, progress: { _, _ in })
                }
                XCTFail("Dead control silently reconnected")
            } catch {}
            XCTAssertEqual(owner.lifecycleState, .closed)
            XCTAssertEqual(try fixture.operationCounts()?["connections"], 1)
            XCTAssertEqual(try fixture.commands().filter { $0["command"] == "STOR" }.count, 0)
        }
    }

    func testBatchOverwriteIdleClosureRetainsRootUntilExplicitSkipAndTerminalCleanup() async throws {
        let fixture = try FTPFixture(countOperations: true); defer { fixture.stop() }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("owned-root")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("a-existing.bin"))
        try Data([0, 255, 10]).write(to: folder.appendingPathComponent("b-new.bin"))
        let remote = fixture.root.appendingPathComponent(folder.lastPathComponent)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        let old = Data("keep-old".utf8); try old.write(to: remote.appendingPathComponent("a-existing.bin"))
        var starts = 0, stops = 0
        let scope = LocalSecurityScope(start: { _ in starts += 1; return true }, stop: { _ in stops += 1 })
        let root = try LocalSourceRoot(url: folder, scope: scope)
        let plan = try await LocalTransferScanner().scan(roots: [root], destination: .root, encoding: .utf8, cancellation: .init())
        let executor = TransferExecutor(); var action: (@MainActor () -> Void)?, delays: [Double] = []
        let queue = BatchTransferQueue(client: FTPClient(), executor: executor, connectionScheduler: { delay, callback in
            delays.append(delay); action = callback; return {}
        })
        try queue.prepare(plan: plan, endpoint: fixture.endpoint, remoteRoot: .root, encoding: .utf8,
            credentials: .anonymous, sources: [plan.roots[0].id: root])
        queue.startOrContinue()
        for _ in 0..<3000 { if queue.overwriteID != nil { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        let decision = try XCTUnwrap(queue.overwriteID)
        XCTAssertEqual(delays, [60]); XCTAssertEqual(starts, 1); XCTAssertEqual(stops, 0)
        action?()
        XCTAssertTrue(queue.isLocked); XCTAssertTrue(queue.hasCredentials); XCTAssertEqual(stops, 0)
        XCTAssertEqual(try fixture.operationCounts()?["connections"], 1)
        queue.skipOverwrite(decision)
        for _ in 0..<3000 { if queue.state == .finished { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(queue.state, .finished); XCTAssertFalse(queue.isLocked); XCTAssertFalse(queue.hasCredentials)
        XCTAssertEqual(starts, 1); XCTAssertEqual(stops, 1); XCTAssertNil(executor.activeJob)
        XCTAssertEqual(queue.summary?.skipped, 1); XCTAssertEqual(queue.summary?.succeeded, 2)
        XCTAssertEqual(try Data(contentsOf: remote.appendingPathComponent("a-existing.bin")), old)
        XCTAssertEqual(try Data(contentsOf: remote.appendingPathComponent("b-new.bin")), Data([0, 255, 10]))
        XCTAssertEqual(try fixture.operationCounts()?["connections"], 2)
        XCTAssertEqual(try fixture.commands().filter { $0["command"] == "STOR" }.count, 1)
    }

    func testOwnerActiveCancellationWaitsForBackendBeforeClosingAndUnlocking() async throws {
        let fixture = try FTPFixture(scenario: "slow-list", delay: 3, countOperations: true); defer { fixture.stop() }
        let executor = TransferExecutor(), current = job(fixture.endpoint)
        let owner = TransferConnectionOwner(base: FTPClient(responseTimeout: 5, stallTimeout: 5), endpoint: fixture.endpoint,
            credentials: .anonymous, executor: executor)
        let task = Task {
            try await executor.execute(current) {
                _ = try await owner.list(endpoint: fixture.endpoint, path: .root, encoding: .utf8, credentials: .anonymous, cancellation: current.cancellation)
            }
        }
        for _ in 0..<3000 {
            if try fixture.commands().contains(where: { $0["command"] == "MLSD" }) { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(try fixture.commands().contains { $0["command"] == "MLSD" })
        owner.close()
        XCTAssertTrue(executor.activeJob === current); XCTAssertEqual(owner.lifecycleState, .invalidating)
        do { try await task.value; XCTFail("Cancelled owner completed") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(executor.activeJob); XCTAssertNil(owner.lifecycleState); XCTAssertEqual(current.outcome, .cancelled)
        XCTAssertEqual(try fixture.operationCounts()?["connections"], 1)
    }

    func testOwnerDirectoryRecheckCannotCrossChangedSFTPTrust() async throws {
        let fixture = try SFTPFixture(countOperations: true); defer { fixture.stop() }
        let store = HostTrustStore(url: fixture.root.appendingPathComponent(".trusted.json")); try store.trust(fixture.identity)
        let credentials = try FTPCredentials.account(username: "member", password: "fixture-pass:@ "), executor = TransferExecutor()
        let owner = TransferConnectionOwner(base: FTPClient(trust: store), endpoint: fixture.endpoint, credentials: credentials, executor: executor)
        defer { owner.close() }
        let parent = try RemotePath.root.appending(name: "missing-parent", bytes: Data("missing-parent".utf8))
        let target = try parent.appending(name: "child", bytes: Data("child".utf8)), current = job(fixture.endpoint, credentials: credentials)
        try await executor.execute(current) {
            let failure: Error
            do {
                try await owner.createDirectory(endpoint: fixture.endpoint, path: target, encoding: .utf8, credentials: credentials, cancellation: current.cancellation)
                return XCTFail("Invalid parent mkdir accepted")
            } catch { failure = error }
            XCTAssertTrue(failure is DirectoryCreationError)
            let before = try fixture.operationCounts()
            try store.reset(host: fixture.identity.host, port: fixture.identity.port)
            do {
                _ = try await owner.recheckDirectory(endpoint: fixture.endpoint, parent: parent, encoding: .utf8, credentials: credentials,
                    cancellation: current.cancellation, after: failure)
                XCTFail("Recheck crossed changed authority")
            } catch {}
            XCTAssertEqual(try fixture.operationCounts(), before)
        }
        XCTAssertEqual(try fixture.commands().filter { $0["command"] == "MKDIR" }.count, 1)
    }

    func testOwnerFinalUploadRefusalAndFailedDirectoryRecheckMatrixNeverReplayWrites() async throws {
        let ca = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/tls-fixtures/ca.pem").path
        let modes: [(FileTransport, Bool)] = [(.ftp, false), (.ftpsExplicit, false), (.ftpsImplicit, false), (.sftp, false), (.sftp, true)]
        for (transport, keyAuth) in modes {
            for directoryFailure in [false, true] {
                let ftp = transport == .sftp ? nil : try FTPFixture(scenario: directoryFailure ? "mkdir-list-error" : "normal", transport: transport, countOperations: true)
                let ssh = transport == .sftp ? try SFTPFixture(scenario: directoryFailure ? "mkdir-list-error" : "reject-close", keyAuth: keyAuth, countOperations: true) : nil
                defer { ftp?.stop(); ssh?.stop() }
                let endpoint = ftp?.endpoint ?? ssh!.endpoint, root = ftp?.root ?? ssh!.root
                let trust = HostTrustStore(url: root.appendingPathComponent(".trusted.json")); if let ssh { try trust.trust(ssh.identity) }
                let credentials: FTPCredentials
                if keyAuth {
                    credentials = try .key(username: "member", material: PrivateKeyAccess().read(root.appendingPathComponent(".keys/openssh-ed25519-encrypted")), passphrase: " 密钥口令:@ ")
                } else { credentials = transport == .sftp ? try .account(username: "member", password: "fixture-pass:@ ") : .anonymous }
                let executor = TransferExecutor(), owner = TransferConnectionOwner(base: FTPClient(caFile: ca, trust: trust), endpoint: endpoint,
                    credentials: credentials, executor: executor)
                defer { owner.close() }
                let token = FTPCancellationToken()
                let target = try RemotePath.root.appending(name: "created-once", bytes: Data("created-once".utf8))
                let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
                defer { try? FileManager.default.removeItem(at: source) }; try Data([0, 255, 10]).write(to: source)
                let current = job(endpoint, credentials: credentials)
                if !directoryFailure {
                    _ = try await owner.list(endpoint: endpoint, path: .root, encoding: .utf8, credentials: credentials, cancellation: token)
                }
                do {
                    try await executor.execute(current) {
                        if directoryFailure {
                            _ = try await owner.ensureDirectory(endpoint: endpoint, path: target, encoding: .utf8,
                                credentials: credentials, cancellation: current.cancellation)
                        } else {
                            let parent = transport == .sftp ? RemotePath.root : try RemotePath.root.appending(name: "最终拒绝", bytes: Data("最终拒绝".utf8))
                            try await owner.upload(endpoint: endpoint, path: parent, file: source, encoding: .utf8,
                                credentials: credentials, cancellation: current.cancellation, progress: { _, _ in })
                        }
                    }
                    XCTFail("Refused final response or failed recheck accepted")
                } catch {}
                XCTAssertEqual(owner.lifecycleState, .closed); XCTAssertNil(executor.activeJob)
                let before = try ftp?.operationCounts() ?? ssh!.operationCounts()
                do {
                    _ = try await owner.list(endpoint: endpoint, path: .root, encoding: .utf8, credentials: credentials, cancellation: .init())
                    XCTFail("Failed owner added another request")
                } catch {}
                let counts = try ftp?.operationCounts() ?? ssh!.operationCounts()
                XCTAssertEqual(counts, before)
                XCTAssertEqual(counts?["connections"], directoryFailure ? 2 : 1)
                XCTAssertEqual(counts?["authentications"], (directoryFailure ? 2 : 1) * (keyAuth ? 2 : 1))
                let commands = try ftp?.commands() ?? ssh!.commands()
                XCTAssertEqual(commands.filter { ["MKD", "MKDIR"].contains($0["command"] ?? "") }.count, directoryFailure ? 1 : 0)
                XCTAssertEqual(commands.filter { ["STOR", "OPEN"].contains($0["command"] ?? "") }.count, directoryFailure ? 0 : 1)
                XCTAssertEqual(counts?["listings"], directoryFailure ? 2 : 1)
                if keyAuth { XCTAssertFalse(commands.contains { $0["command"] == "AUTH" }) }
                let numeric: [String: Any] = ["mode": transport.rawValue + (keyAuth ? "-key" : "-password"),
                    "stage": directoryFailure ? "directory-recheck-failed" : "upload-final-refused", "counts": counts ?? [:]]
                print("TRANSFER_SESSION_FAILURE " + String(decoding: try JSONSerialization.data(withJSONObject: numeric, options: [.sortedKeys]), as: UTF8.self))
            }
        }
    }

    func testTrustRevisionDetectsLocalResetAndAnotherStoreChangingAuthority() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), url = base.appendingPathComponent("hosts.json")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = HostTrustStore(url: url), other = HostTrustStore(url: url)
        let initial = try store.sessionRevision()
        XCTAssertEqual(try store.sessionRevision(), initial)
        let identity = SSHHostIdentity(host: "example.test", port: 22, key: Data("public key".utf8))
        try store.trust(identity)
        let trusted = try store.sessionRevision(); XCTAssertNotEqual(trusted, initial)
        XCTAssertEqual(try store.sessionRevision(), trusted)
        try other.reset(host: identity.host, port: identity.port)
        XCTAssertNotEqual(try store.sessionRevision(), trusted)
        try Data("corrupt".utf8).write(to: url)
        XCTAssertThrowsError(try store.sessionRevision())
    }
}
