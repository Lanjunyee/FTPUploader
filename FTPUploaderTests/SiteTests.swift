import XCTest

final class SiteTests: XCTestCase {
    func testDraftDefaultsValidationAndExplicitEmptyPassword() throws {
        var draft = SiteDraft()
        XCTAssertEqual(draft.loginMode, .anonymous)
        XCTAssertFalse(draft.rememberPassword)
        draft.host = "example.test"
        draft.loginMode = .account
        XCTAssertThrowsError(try draft.configuration())
        draft.username = "u:@"
        draft.password = " a:@ b "
        XCTAssertEqual(try draft.configuration().username, "u:@")
        XCTAssertEqual(try FTPCredentials.account(username: draft.username, password: draft.password).password, " a:@ b ")
        XCTAssertThrowsError(try FTPCredentials.account(username: "u", password: nil))
        XCTAssertEqual(try FTPCredentials.account(username: "u", password: "").password, "")
        for value in ["line\n", "nul\0"] {
            XCTAssertThrowsError(try FTPCredentials.account(username: value, password: "p"))
            XCTAssertThrowsError(try FTPCredentials.account(username: "u", password: value))
        }
        XCTAssertFalse(String(describing: try FTPCredentials.account(username: "u", password: "secret")).contains("secret"))
    }

    func testValidationFailuresReportTheOwningFieldAndReason() throws {
        func issue(_ configure: (inout SiteDraft) -> Void,
                   file: StaticString = #filePath, line: UInt = #line) -> FieldIssue {
            var draft = SiteDraft()
            draft.host = "example.test"
            configure(&draft)
            do { _ = try draft.configuration() }
            catch let issue as FieldIssue { return issue }
            catch { XCTFail("Expected FieldIssue, got \(error)", file: file, line: line) }
            XCTFail("Expected validation failure", file: file, line: line)
            return FieldIssue(field: .address, message: "")
        }

        for host in ["sftp://example.test", "ftp://u:p@example.test", "example.test/path"] {
            let failure = issue { $0.host = host }
            XCTAssertEqual(failure.field, .server, "Wrong field for \(host)")
            XCTAssertFalse(failure.message.isEmpty)
        }
        for port in ["0", "70000", "bad", ""] {
            let failure = issue { $0.port = port }
            XCTAssertEqual(failure.field, .port, "Wrong field for port \(port)")
            XCTAssertTrue(failure.message.contains("1 到 65535"), "Reason for \(port): \(failure.message)")
        }
        let noUsername = issue { $0.loginMode = .account }
        XCTAssertEqual(noUsername.field, .username)
        XCTAssertTrue(noUsername.message.contains("用户名"))
        let badUsername = issue { $0.loginMode = .account; $0.username = "line\n" }
        XCTAssertEqual(badUsername.field, .username)
        XCTAssertTrue(badUsername.message.contains("控制字符"))
        let badPassword = issue { $0.loginMode = .account; $0.username = "member"; $0.password = "nul\0" }
        XCTAssertEqual(badPassword.field, .password)
        XCTAssertTrue(badPassword.message.contains("控制字符"))
        for directory in ["/a/..", "/a%ZZ"] {
            let failure = issue { $0.initialDirectory = directory }
            XCTAssertEqual(failure.field, .initialDirectory, "Wrong field for \(directory)")
            XCTAssertFalse(failure.message.isEmpty)
        }

        var valid = SiteDraft(); valid.host = "example.test"; valid.loginMode = .account
        valid.username = "member"; valid.password = ""
        XCTAssertNoThrow(try valid.configuration())
    }

    func testConfigurationRoundTripDoesNotPersistPassword() throws {
        let suite = "ftp-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SiteStore(defaults: defaults)
        XCTAssertTrue(try store.load().isEmpty)
        var draft = SiteDraft()
        draft.host = "example.test"; draft.port = "2121"; draft.initialDirectory = "/共享 资料%25%23"
        draft.loginMode = .account; draft.username = "member"; draft.password = "do-not-persist-me"
        draft.rememberPassword = true
        let one = try draft.configuration()
        draft.id = UUID(); draft.host = "other.test"
        let two = try draft.configuration()
        try store.save([one, two])
        XCTAssertEqual(try SiteStore(defaults: defaults).load(), [one, two])
        XCTAssertEqual(try FTPEndpoint(address: one.address).initialPath.display, "/共享 资料%#")
        let bytes = try XCTUnwrap(defaults.data(forKey: SiteStore.key))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("do-not-persist-me"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("\"password\""))
    }

    func testCorruptOrInvalidDataIsPreserved() throws {
        let suite = "ftp-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = Data("broken".utf8)
        defaults.set(data, forKey: SiteStore.key)
        let store = SiteStore(defaults: defaults)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(defaults.data(forKey: SiteStore.key), data)
        var draft = SiteDraft(); draft.host = "example.test"
        for port in ["0", "70000", "bad"] { draft.port = port; XCTAssertThrowsError(try draft.configuration()) }
        draft.port = "21"
        for host in ["sftp://example.test", "ftp://u:p@example.test", "example.test/path"] {
            draft.host = host; XCTAssertThrowsError(try draft.configuration())
        }
    }
}
