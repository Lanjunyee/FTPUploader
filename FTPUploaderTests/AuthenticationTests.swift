import XCTest

final class AuthenticationTests: XCTestCase {
    func testAccountIdentityForBrowsingFallbackAndBinaryUpload() async throws {
        for scenario in ["account-only", "no-mlsd"] {
            let fixture = try FTPFixture(scenario: scenario)
            defer { fixture.stop() }
            let credentials = try FTPCredentials.account(username: "member", password: "fixture-pass:@ ")
            let client = FTPClient()
            let listing = try await client.list(endpoint: fixture.endpoint, path: .root, credentials: credentials)
            let entry = try XCTUnwrap(listing.entries.first { $0.name == "账户资料" })
            XCTAssertFalse(listing.entries.contains { $0.name == "访客资料" })
            let path = try RemotePath.root.appending(name: entry.name, bytes: entry.rawName)
            _ = try await client.list(endpoint: fixture.endpoint, path: path, encoding: listing.encoding, credentials: credentials)
            _ = try await client.list(endpoint: fixture.endpoint, path: path, encoding: listing.encoding, credentials: credentials)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + " %#.bin")
            let bytes = Data((0..<8192).map { UInt8($0 % 256) })
            try bytes.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            try await client.upload(endpoint: fixture.endpoint, path: path, file: file, encoding: .utf8, credentials: credentials) { _, _ in }
            XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("账户资料").appendingPathComponent(file.lastPathComponent)), bytes)
            let commands = try fixture.commands()
            XCTAssertTrue(commands.filter { $0["command"] == "USER" }.allSatisfy { $0["argument"] == "member" })
            XCTAssertEqual(commands.filter { $0["command"] == "STOR" }.count, 1)
            XCTAssertEqual(commands.contains { $0["command"] == "LIST" }, scenario == "no-mlsd")
        }
    }

    func testRejectedAccountDoesNotFallbackOrRetry() async throws {
        let fixture = try FTPFixture(scenario: "account-only")
        defer { fixture.stop() }
        do {
            _ = try await FTPClient().list(endpoint: fixture.endpoint, path: .root,
                                          credentials: .account(username: "member", password: "wrong"))
            XCTFail("Rejected credentials accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("账户登录失败"))
            XCTAssertTrue(error.localizedDescription.contains("530"))
        }
        let commands = try fixture.commands()
        XCTAssertEqual(commands.filter { $0["command"] == "USER" }.map { $0["argument"]! }, ["member"])
        XCTAssertFalse(commands.contains { ["STOR", "MLSD", "LIST"].contains($0["command"]!) })
    }

    func testEchoedPasswordIsRedactedBeforeBufferTruncation() async throws {
        let fixture = try FTPFixture(scenario: "echo-password")
        defer { fixture.stop() }
        let password = "private-password-at-buffer-boundary"
        do {
            _ = try await FTPClient().list(endpoint: fixture.endpoint, path: .root,
                                          credentials: .account(username: "member", password: password))
            XCTFail("Unexpected success")
        } catch {
            let detail = error.localizedDescription
            XCTAssertTrue(detail.contains("530"))
            XCTAssertTrue(detail.contains("[redacted]"))
            XCTAssertFalse(detail.contains(password))
            XCTAssertFalse(detail.contains("private-"))
        }
    }

    func testExplicitEmptyPasswordIsSentAsEmpty() async throws {
        let fixture = try FTPFixture(scenario: "account-only")
        defer { fixture.stop() }
        let result = try await FTPClient().list(endpoint: fixture.endpoint, path: .root,
                                               credentials: .account(username: "empty", password: ""))
        XCTAssertFalse(result.entries.isEmpty)
    }
    private var testCA: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/tls-fixtures/ca.pem").path
    }

    func testFTPSRequiresEncryptedControlAndDataAndPreservesContent() async throws {
        for transport in [FileTransport.ftpsExplicit, .ftpsImplicit] {
            let fixture = try FTPFixture(transport: transport)
            defer { fixture.stop() }
            let client = FTPClient(caFile: testCA)
            let credentials = try FTPCredentials.account(username: "member", password: "fixture-pass:@ ")
            let listing = try await client.list(endpoint: fixture.endpoint, path: .root, credentials: credentials)
            XCTAssertFalse(listing.entries.isEmpty)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+" 中文.bin")
            let bytes = Data((0..<4096).map { UInt8($0 % 256) }); try bytes.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            try await client.upload(endpoint: fixture.endpoint, path: .root, file: file, encoding: .utf8, credentials: credentials) { _, _ in }
            XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(file.lastPathComponent)), bytes)
            let commands = try fixture.commands()
            XCTAssertTrue(commands.filter { ["USER","PASS"].contains($0["command"] ?? "") }.allSatisfy { $0["control_tls"] == "yes" })
            XCTAssertEqual(commands.filter { $0["command"] == "DATA" }.count, 2)
            XCTAssertTrue(commands.filter { $0["command"] == "DATA" }.allSatisfy { $0["data_tls"] == "yes" })
        }
    }

    func testFTPSInvalidCertificatesAndDataTLSFailureNeverSucceed() async throws {
        for certificate in ["expired", "wrong", "self", "good"] {
            let fixture = try FTPFixture(transport: .ftpsExplicit, certificate: certificate, failDataTLS: certificate == "good")
            defer { fixture.stop() }
            do {
                _ = try await FTPClient(caFile: testCA).list(endpoint: fixture.endpoint, path: .root,
                         credentials: .account(username: "member", password: "fixture-pass:@ "))
                XCTFail("Invalid TLS accepted: " + certificate)
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("fixture-pass:@ "))
                XCTAssertTrue(error.localizedDescription.contains("TLS"))
            }
            let commands = try fixture.commands()
            if certificate != "good" { XCTAssertFalse(commands.contains { $0["command"] == "PASS" }) }
            XCTAssertFalse(commands.contains { $0["data_tls"] == "no" })
        }
    }

    func testMissingTLSAndRejectedUpgradeSendNoPassword() async throws {
        let fixture = try FTPFixture(); defer { fixture.stop() }
        let endpoint = try FTPEndpoint(address: "127.0.0.1:\(fixture.info.port)", transport: .ftpsExplicit)
        for available in [false,true] {
            do {
                _ = try await FTPClient(tlsAvailable: { available }).list(endpoint: endpoint, path: .root,
                                    credentials: .account(username: "member", password: "secret"))
                XCTFail("Missing TLS accepted")
            } catch {}
            XCTAssertFalse(try fixture.commands().contains { ["USER","PASS","DATA"].contains($0["command"] ?? "") })
        }
    }

    func testFTPSCancellationStopsPendingDirectory() async throws {
        for transport in [FileTransport.ftpsExplicit, .ftpsImplicit] {
            let fixture = try FTPFixture(scenario: "slow-list", delay: 10, transport: transport)
            defer { fixture.stop() }
            let token = FTPCancellationToken()
            let task = Task { try await FTPClient(caFile: testCA).list(endpoint: fixture.endpoint, path: .root,
                                                       credentials: .anonymous, cancellation: token) }
            try await Task.sleep(nanoseconds: 200_000_000)
            let started = Date(); token.cancel()
            do { _ = try await task.value; XCTFail("Cancelled FTPS succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        }
    }

    func testSFTPHostTrustBeforeAuthenticationAndChangedKeysBlock() async throws {
        let fixture = try SFTPFixture(); defer { fixture.stop() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+"/hosts.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = HostTrustStore(url: url); let client = FTPClient(responseTimeout: 3, stallTimeout: 3, trust: store)
        let credentials = try FTPCredentials.account(username: "member", password: "fixture-pass:@ ")
        do {
            _ = try await client.list(endpoint: fixture.endpoint, path: .root, credentials: credentials)
            XCTFail("Unknown host authenticated")
        } catch HostTrustError.unknown(let identity) { XCTAssertEqual(identity, fixture.identity) }
        XCTAssertFalse(try fixture.commands().contains { $0["command"] == "AUTH" })
        let wrong = SSHHostIdentity(host: fixture.identity.host, port: fixture.identity.port, key: fixture.identity.key + Data([1]))
        try store.trust(wrong)
        do {
            _ = try await client.list(endpoint: fixture.endpoint, path: .root, credentials: credentials)
            XCTFail("Changed host authenticated")
        } catch HostTrustError.changed {}
        XCTAssertFalse(try fixture.commands().contains { $0["command"] == "AUTH" })
        try store.reset(host: fixture.identity.host, port: fixture.identity.port)
        try store.trust(fixture.identity)
        let listing = try await client.list(endpoint: fixture.endpoint, path: .root, credentials: credentials)
        XCTAssertTrue(listing.entries.contains { $0.name == "中文 空格%#" })
        XCTAssertEqual(try fixture.commands().filter { $0["command"] == "AUTH" }.count, 1)
    }

    func testPrivateKeyFormatMatrixAndTransfers() async throws {
        let fixture = try SFTPFixture(keyAuth: true); defer { fixture.stop() }
        let hosts = fixture.root.appendingPathComponent(".trusted.json")
        let store = HostTrustStore(url: hosts); try store.trust(fixture.identity)
        let client = FTPClient(responseTimeout: 4, stallTimeout: 4, trust: store)
        for format in ["openssh-ed25519", "openssh-rsa", "pem-rsa", "pkcs8-rsa"] {
            for encrypted in [false, true] {
                let url = fixture.root.appendingPathComponent(".keys/" + format + (encrypted ? "-encrypted" : ""))
                let material = try PrivateKeyAccess().read(url)
                let credentials = try FTPCredentials.key(username: "member", material: material,
                                                        passphrase: encrypted ? " 密钥口令:@ " : nil)
                let listing = try await client.list(endpoint: fixture.endpoint, path: .root, credentials: credentials)
                XCTAssertFalse(listing.entries.isEmpty, format)
                let local = fixture.root.appendingPathComponent(".inputs/source.bin")
                try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                for bytes in [Data([0, 255, 10]), Data()] {
                    try bytes.write(to: local)
                    try await client.upload(endpoint: fixture.endpoint, path: .root, file: local, encoding: .utf8, credentials: credentials) { _, _ in }
                    // Address the uploaded file by its exact raw name.
                    let remote = try RemotePath.root.appending(name: local.lastPathComponent, bytes: Data(local.lastPathComponent.utf8))
                    var received = Data()
                    try await client.download(endpoint: fixture.endpoint, path: remote, credentials: credentials,
                                              cancellation: FTPCancellationToken(), receive: { received.append($0) }, progress: { _, _ in })
                    XCTAssertEqual(received, bytes, format)
                }
            }
        }
        XCTAssertFalse(try fixture.commands().contains { $0["command"] == "AUTH" })
    }

    func testPrivateKeyTrustAndFailuresNeverFallback() async throws {
        let fixture = try SFTPFixture(keyAuth: true); defer { fixture.stop() }
        let store = HostTrustStore(url: fixture.root.appendingPathComponent(".trusted.json"))
        let client = FTPClient(responseTimeout: 3, trust: store)
        let material = try PrivateKeyAccess().read(fixture.root.appendingPathComponent(".keys/openssh-ed25519-encrypted"))
        let credentials = try FTPCredentials.key(username: "member", material: material, passphrase: "wrong")
        do { _ = try await client.list(endpoint: fixture.endpoint, path: .root, credentials: credentials); XCTFail("Unknown host authenticated") }
        catch HostTrustError.unknown {}
        XCTAssertFalse(try fixture.commands().contains { $0["command"] == "AUTH_KEY" })
        try store.trust(SSHHostIdentity(host: fixture.identity.host, port: fixture.identity.port, key: fixture.identity.key + Data([1])))
        do { _ = try await client.list(endpoint: fixture.endpoint, path: .root, credentials: credentials); XCTFail("Changed host authenticated") }
        catch HostTrustError.changed {}
        XCTAssertFalse(try fixture.commands().contains { $0["command"] == "AUTH_KEY" })
        try store.reset(host: fixture.identity.host, port: fixture.identity.port)
        try store.trust(fixture.identity)
        do { _ = try await client.list(endpoint: fixture.endpoint, path: .root, credentials: credentials); XCTFail("Wrong phrase authenticated") }
        catch { XCTAssertFalse(error.localizedDescription.contains("wrong")) }
        XCTAssertFalse(try fixture.commands().contains { ["AUTH", "LIST", "OPEN"].contains($0["command"] ?? "") })
        let plain = try PrivateKeyAccess().read(fixture.root.appendingPathComponent(".keys/openssh-rsa"))
        let rejected = try FTPCredentials.key(username: "unapproved", material: plain, passphrase: nil)
        do { _ = try await client.list(endpoint: fixture.endpoint, path: .root, credentials: rejected); XCTFail("Unapproved user authenticated") }
        catch { XCTAssertTrue(error.localizedDescription.contains("公钥")) }
        XCTAssertFalse(try fixture.commands().contains { $0["command"] == "AUTH" })
    }

    func testPrivateKeyAuthenticationTimeoutCancellationAndUnsupportedPEM() async throws {
        for cancel in [false, true] {
            let fixture = try SFTPFixture(scenario: "slow-auth", delay: 3, keyAuth: true)
            defer { fixture.stop() }
            let store = HostTrustStore(url: fixture.root.appendingPathComponent(".trusted.json"))
            try store.trust(fixture.identity)
            let credentials = try FTPCredentials.key(username: "member", material: PrivateKeyAccess().read(fixture.root.appendingPathComponent(".keys/openssh-ed25519")), passphrase: nil)
            let token = FTPCancellationToken()
            let task = Task { try await FTPClient(responseTimeout: 1, trust: store).list(endpoint: fixture.endpoint, path: .root, credentials: credentials, cancellation: token) }
            if cancel {
                let limit = Date().addingTimeInterval(2)
                while !(try fixture.commands().contains { $0["command"] == "AUTH_KEY" }) && Date() < limit { try await Task.sleep(nanoseconds: 5_000_000) }
                token.cancel()
            }
            let started = Date()
            do { _ = try await task.value; XCTFail("Stalled authentication succeeded") }
            catch { if cancel { XCTAssertTrue(error is CancellationError) } else { XCTAssertTrue(error.localizedDescription.contains("超时")) } }
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
            XCTAssertFalse(try fixture.commands().contains { ["AUTH", "LIST", "OPEN"].contains($0["command"] ?? "") })
        }
        let fixture = try SFTPFixture(keyAuth: true); defer { fixture.stop() }
        let store = HostTrustStore(url: fixture.root.appendingPathComponent(".trusted.json")); try store.trust(fixture.identity)
        let damaged = try FTPCredentials.key(username: "member", material: PrivateKeyMaterial(Data("-----BEGIN PRIVATE KEY-----\nnot-a-key".utf8)), passphrase: nil)
        do { _ = try await FTPClient(trust: store).list(endpoint: fixture.endpoint, path: .root, credentials: damaged); XCTFail("Damaged PEM accepted") }
        catch { XCTAssertTrue(error is FieldIssue); XCTAssertFalse(error.localizedDescription.contains("not-a-key")) }
        XCTAssertThrowsError(try PrivateKeyAccess().read(fixture.root.appendingPathComponent(".keys/unsupported-openssh-ec")))
        let unsupported = try FTPCredentials.key(username: "member", material: PrivateKeyAccess().read(fixture.root.appendingPathComponent(".keys/unsupported-pem-ec")), passphrase: nil)
        do { _ = try await FTPClient(trust: store).list(endpoint: fixture.endpoint, path: .root, credentials: unsupported); XCTFail("Unsupported EC key accepted") }
        catch { XCTAssertTrue(error is FieldIssue) }
        XCTAssertFalse(try fixture.commands().contains { ["AUTH", "AUTH_KEY", "LIST", "OPEN"].contains($0["command"] ?? "") })
    }

}
