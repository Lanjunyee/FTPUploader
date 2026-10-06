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
}
