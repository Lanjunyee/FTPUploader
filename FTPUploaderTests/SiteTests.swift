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

    func testLegacySitesDefaultToAutomaticAndEncodingEditPreservesConfiguration() throws {
        let suite = "ftp-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var draft = SiteDraft(); draft.host = "example.test"; draft.port = "2121"
        draft.initialDirectory = "/%B9%B2%CF%ED/"; draft.loginMode = .account
        draft.username = "member"; draft.rememberPassword = true
        let old = try draft.configuration()
        let encoded = try JSONEncoder().encode([old])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        json[0].removeValue(forKey: "encodingPolicy")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        defaults.set(legacy, forKey: SiteStore.key)
        let store = SiteStore(defaults: defaults)
        let loaded = try XCTUnwrap(store.load().first)
        XCTAssertEqual(loaded, old); XCTAssertEqual(loaded.encodingPolicy, .automatic)
        XCTAssertEqual(defaults.data(forKey: SiteStore.key), legacy, "Loading must not rewrite migration data")
        for policy in FTPEncodingPolicy.allCases {
            var edit = SiteDraft(site: loaded); edit.encodingPolicy = policy
            let updated = try edit.configuration()
            XCTAssertEqual(updated.id, old.id); XCTAssertEqual(updated.identity, old.identity)
            XCTAssertEqual(updated.rememberPassword, old.rememberPassword)
            XCTAssertEqual(updated.port, old.port); XCTAssertEqual(updated.initialDirectory, old.initialDirectory)
            XCTAssertEqual(updated.encodingPolicy, policy)
            try store.save([updated])
            XCTAssertEqual(try SiteStore(defaults: defaults).load(), [updated])
        }
        json[0]["encodingPolicy"] = "unknown-encoding"
        let invalid = try JSONSerialization.data(withJSONObject: json)
        defaults.set(invalid, forKey: SiteStore.key)
        XCTAssertThrowsError(try store.load()); XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(defaults.data(forKey: SiteStore.key), invalid)
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
    func testLegacySiteProtocolDefaultsAndBackup() throws {
        let suite = "secure-migration-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var draft = SiteDraft(); draft.host = "legacy.test"
        let site = try draft.configuration()
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([site])) as? [[String: Any]])
        records[0].removeValue(forKey: "transport")
        records[0].removeValue(forKey: "encodingPolicy")
        let source = try JSONSerialization.data(withJSONObject: records)
        defaults.set(source, forKey: SiteStore.key)
        let store = SiteStore(defaults: defaults)
        let loaded = try store.load()
        XCTAssertEqual(loaded[0].id, site.id)
        XCTAssertEqual(loaded[0].transport, .ftp)
        XCTAssertEqual(loaded[0].encodingPolicy, .automatic)
        try store.save(loaded)
        XCTAssertEqual(defaults.data(forKey: SiteStore.legacyBackupKey), source)
        XCTAssertEqual(try SiteStore(defaults: defaults).load(), loaded)
    }

    func testProtocolSitesSurviveStoreRestartWithCustomPortAndEncoding() throws {
        let suite = "protocol-sites-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SiteStore(defaults: defaults); _ = try store.load()
        var sites: [FTPSite] = []
        for transport in FileTransport.allCases {
            var draft = SiteDraft(); draft.host = "example.test"; draft.transport = transport
            draft.port = "2022"; draft.initialDirectory = "/中文 %25%23"
            if transport == .sftp { draft.loginMode = .account; draft.username = "member"; draft.encodingPolicy = .utf8 }
            sites.append(try draft.configuration())
        }
        try store.save(sites)
        XCTAssertEqual(try SiteStore(defaults: defaults).load(), sites)
        for site in sites {
            let endpoint = try FTPEndpoint(address: site.address, transport: site.transport)
            XCTAssertEqual(endpoint.port, 2022)
            XCTAssertEqual(endpoint.transport, site.transport)
        }
    }

    func testHostTrustUnknownMatchChangeCorruptionAndFailedAtomicWrite() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("known-hosts.json")
        let host = SSHHostIdentity(host: "example.test", port: 22, key: Data([0,0,0,7]+Array("ssh-rsa".utf8)+[1,2,3]))
        let changed = SSHHostIdentity(host: host.host, port: host.port, key: host.key + Data([4]))
        let store = HostTrustStore(url: url)
        XCTAssertThrowsError(try store.verify(host))
        try store.trust(host)
        try HostTrustStore(url: url).verify(host)
        XCTAssertEqual(host.keyType, "ssh-rsa")
        XCTAssertTrue(host.fingerprint.hasPrefix("SHA256:"))
        XCTAssertThrowsError(try store.verify(changed))
        XCTAssertThrowsError(try store.trust(changed))
        let source = try Data(contentsOf: url)
        let failing = HostTrustStore(url: url, write: { _,_ in throw HostTrustError.storage })
        XCTAssertThrowsError(try failing.reset(host: host.host, port: host.port))
        XCTAssertEqual(try Data(contentsOf: url), source)
        let other = SSHHostIdentity(host: host.host, port: 2222, key: host.key)
        XCTAssertThrowsError(try failing.trust(other))
        XCTAssertEqual(try Data(contentsOf: url), source)
        try store.reset(host: host.host, port: host.port)
        XCTAssertThrowsError(try store.verify(host))
        try Data("damaged".utf8).write(to: url)
        XCTAssertThrowsError(try store.verify(host))
        XCTAssertThrowsError(try store.trust(host))
        XCTAssertEqual(try Data(contentsOf: url), Data("damaged".utf8))
    }

}
