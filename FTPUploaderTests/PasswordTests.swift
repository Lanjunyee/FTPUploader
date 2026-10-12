import XCTest
import Security

final class MemoryKeychain: KeychainAccess {
    var items: [String: Data] = [:]
    var status = errSecSuccess
    var writeStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess
    var deletes: [String] = []
    var retainDeletedItems = false
    private func key(_ query: [String: Any]) -> String {
        "\(query[kSecAttrService as String]!)|\(query[kSecAttrAccount as String]!)"
    }
    func read(_ query: [String: Any]) -> (OSStatus, Data?) {
        guard status == errSecSuccess else { return (status, nil) }
        let data = items[key(query)]
        return (data == nil ? errSecItemNotFound : errSecSuccess, data)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        guard writeStatus == errSecSuccess else { return writeStatus }
        guard status == errSecSuccess else { return status }
        items[key(attributes)] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        guard writeStatus == errSecSuccess else { return writeStatus }
        guard status == errSecSuccess else { return status }
        guard items[key(query)] != nil else { return errSecItemNotFound }
        items[key(query)] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func accounts(service: String) -> (OSStatus, [String]?) {
        guard status == errSecSuccess else { return (status, nil) }
        let prefix = service + "|"
        let accounts = items.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        return accounts.isEmpty ? (errSecItemNotFound, nil) : (errSecSuccess, accounts)
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        guard deleteStatus == errSecSuccess else { return deleteStatus }
        guard status == errSecSuccess else { return status }
        deletes.append(key(query))
        if retainDeletedItems { return items[key(query)] == nil ? errSecItemNotFound : errSecSuccess }
        return items.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess
    }
}

@MainActor
final class PasswordRecoveryTests: XCTestCase {
    private func site() throws -> FTPSite {
        var draft = SiteDraft(); draft.host = "example.test"; draft.loginMode = .account
        draft.username = "member"; draft.rememberPassword = true; return try draft.configuration()
    }
    private func record(_ site: FTPSite, _ password: String) throws -> Data {
        let identity = try JSONSerialization.jsonObject(with: JSONEncoder().encode(site.identity))
        return try JSONSerialization.data(withJSONObject: ["identity": identity, "password": password], options: [.prettyPrinted])
    }
    func testRecoveryEnumerationRejectsNoncanonicalIdentifiersAndRetainsAllMaterials() async throws {
        for account in ["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "invalid"] {
            let access = MemoryKeychain(), store = PasswordStore(service: "recovery-test", access: access), site = try site()
            let snapshot = try await store.capture(id: site.id)
            try await store.saveRecovery(snapshot, transactionID: UUID())
            access.items["recovery-test.recovery-v1|" + account] = Data("unrecognized recovery".utf8)
            let before = access.items
            do { _ = try await store.recoveryIDs(); XCTFail("Unaddressable recovery account accepted") } catch {}
            XCTAssertEqual(access.items, before); XCTAssertTrue(access.deletes.isEmpty)
        }
    }
    func testCompleteLegacyAndV2PayloadsRestoreExactlyAndTransactionsAreIsolated() async throws {
        let access = MemoryKeychain(), store = PasswordStore(service: "recovery-test", access: access), site = try site()
        let legacy = try record(site, "old-legacy-secret"), current = try record(site, "old-current-secret")
        let legacyKey = "recovery-test|" + site.id.uuidString, currentKey = "recovery-test.v2|" + site.id.uuidString
        access.items[legacyKey] = legacy; access.items[currentKey] = current
        let snapshot = try await store.capture(id: site.id), first = UUID(), second = UUID()
        XCTAssertTrue(snapshot.hasLegacy); XCTAssertTrue(snapshot.hasCurrent)
        XCTAssertFalse(String(reflecting: snapshot).contains("secret"))
        try await store.saveRecovery(snapshot, transactionID: first)
        try await store.saveRecovery(snapshot, transactionID: first)
        try await store.saveRecovery(snapshot, transactionID: second)
        access.items.removeValue(forKey: legacyKey); access.items[currentKey] = try record(site, "new-secret")
        let recovered = try await store.loadRecovery(transactionID: first, siteID: site.id)
        XCTAssertEqual(recovered, snapshot)
        try await store.restore(try XCTUnwrap(recovered), id: site.id)
        try await store.restore(snapshot, id: site.id)
        XCTAssertEqual(access.items[legacyKey], legacy); XCTAssertEqual(access.items[currentKey], current)
        try await store.removeRecovery(transactionID: first); try await store.removeRecovery(transactionID: first)
        let absent = try await store.loadRecovery(transactionID: first, siteID: site.id)
        let other = try await store.loadRecovery(transactionID: second, siteID: site.id)
        XCTAssertNil(absent); XCTAssertEqual(other, snapshot)
        XCTAssertEqual(access.items[legacyKey], legacy)
    }
    func testAbsentRecordsRestoreByDeletingOnlyTheTransactionSite() async throws {
        let access = MemoryKeychain(), store = PasswordStore(service: "recovery-test", access: access), site = try self.site(), other = try self.site()
        let snapshot = try await store.capture(id: site.id), transaction = UUID()
        XCTAssertFalse(snapshot.hasLegacy); XCTAssertFalse(snapshot.hasCurrent)
        try await store.saveRecovery(snapshot, transactionID: transaction)
        try await store.save("new", for: site); try await store.save("unrelated", for: other)
        try await store.restore(snapshot, id: site.id)
        let empty = try await store.capture(id: site.id), password = try await store.password(for: other)
        XCTAssertEqual(empty, snapshot); XCTAssertEqual(password, "unrelated")
        let recovery = try await store.loadRecovery(transactionID: transaction, siteID: site.id)
        XCTAssertEqual(recovery, snapshot)
    }
    func testRecoveryCollisionWrongSiteAndCorruptionFailClosed() async throws {
        let access = MemoryKeychain(), store = PasswordStore(service: "recovery-test", access: access), site = try self.site(), other = try self.site()
        try await store.save("original-secret", for: site)
        let original = try await store.capture(id: site.id), transaction = UUID()
        try await store.saveRecovery(original, transactionID: transaction)
        let recoveryKey = "recovery-test.recovery-v1|" + transaction.uuidString
        let protected = access.items[recoveryKey]
        try await store.save("new-secret", for: site)
        let changed = try await store.capture(id: site.id)
        do { try await store.saveRecovery(changed, transactionID: transaction); XCTFail("Overwrote recovery") } catch {}
        XCTAssertEqual(access.items[recoveryKey], protected)
        do { _ = try await store.loadRecovery(transactionID: transaction, siteID: other.id); XCTFail("Wrong site accepted") } catch {}
        do { try await store.restore(original, id: other.id); XCTFail("Wrong-site restore accepted") } catch {}
        XCTAssertNil(access.items["recovery-test.v2|" + other.id.uuidString])
        access.items[recoveryKey] = Data("corrupt-secret".utf8)
        do { _ = try await store.loadRecovery(transactionID: transaction, siteID: site.id); XCTFail("Corruption accepted") }
        catch { XCTAssertFalse(error.localizedDescription.contains("corrupt-secret")) }
        XCTAssertEqual(access.items[recoveryKey], Data("corrupt-secret".utf8))
    }
    func testSystemDenialPreservesRecoveryAndRestoreCanRetry() async throws {
        let access = MemoryKeychain(), store = PasswordStore(service: "recovery-test", access: access), site = try site()
        try await store.save("old-secret", for: site)
        let snapshot = try await store.capture(id: site.id), transaction = UUID()
        try await store.saveRecovery(snapshot, transactionID: transaction)
        try await store.save("new-secret", for: site)
        let protected = access.items
        for status in [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed, errSecParam] {
            access.status = status
            do { _ = try await store.capture(id: site.id); XCTFail() } catch {}
            do { try await store.saveRecovery(snapshot, transactionID: UUID()); XCTFail() } catch {}
            do { _ = try await store.loadRecovery(transactionID: transaction, siteID: site.id); XCTFail() } catch {}
            do { try await store.restore(snapshot, id: site.id); XCTFail() } catch {}
            do { try await store.removeRecovery(transactionID: transaction); XCTFail() } catch {}
            XCTAssertEqual(access.items, protected)
        }
        access.status = errSecSuccess; access.writeStatus = errSecAuthFailed
        do { try await store.restore(snapshot, id: site.id); XCTFail() } catch {}
        let retained = try await store.loadRecovery(transactionID: transaction, siteID: site.id)
        XCTAssertEqual(retained, snapshot)
        access.writeStatus = errSecSuccess
        try await store.restore(snapshot, id: site.id)
        let restored = try await store.password(for: site); XCTAssertEqual(restored, "old-secret")
    }
    func testMalformedOrPrivateKeyPayloadCannotEnterRecoveryItems() async throws {
        let access = MemoryKeychain(), store = PasswordStore(service: "recovery-test", access: access), site = try site()
        let key = "recovery-test.v2|" + site.id.uuidString
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: record(site, "password")) as? [String: Any])
        object["privateKey"] = "-----BEGIN PRIVATE KEY-----"
        let bad = try JSONSerialization.data(withJSONObject: object)
        access.items[key] = bad
        do { _ = try await store.capture(id: site.id); XCTFail("Captured non-password fields") }
        catch { XCTAssertFalse(error.localizedDescription.contains("BEGIN")) }
        XCTAssertEqual(access.items, [key: bad])
    }
}

@MainActor
final class PasswordTests: XCTestCase {
    private func draft() -> SiteDraft {
        var d = SiteDraft(); d.host = "example.test"; d.loginMode = .account
        d.username = "member"; d.password = "secret"; d.rememberPassword = true
        return d
    }

    func testPasswordCRUDAndIdentityIsolation() async throws {
        let access = MemoryKeychain()
        let passwords = PasswordStore(service: "test-only", access: access)
        let one = try draft().configuration()
        var d = draft(); d.id = UUID(); d.username = "other"
        let two = try d.configuration()
        let absent = try await passwords.password(for: one); XCTAssertNil(absent)
        try await passwords.save("one", for: one); try await passwords.save("two", for: two)
        try await passwords.save("updated", for: one)
        let result = try await passwords.password(for: one); XCTAssertEqual(result, "updated")
        var changed = SiteDraft(site: one); changed.username = "changed"
        do { _ = try await passwords.password(for: changed.configuration()); XCTFail("Identity mismatch accepted") } catch {}
        try await passwords.remove(id: one.id); try await passwords.remove(id: one.id)
        let other = try await passwords.password(for: two); XCTAssertEqual(other, "two")
        for status in [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed, errSecParam] {
            access.status = status
            do { _ = try await passwords.password(for: two); XCTFail("Failure accepted") } catch {}
            do { try await passwords.save("p", for: two); XCTFail("Failure accepted") } catch {}
            do { try await passwords.remove(id: two.id); XCTFail("Failure accepted") } catch {}
        }
    }

    func testSaveWithoutPasswordReportsThePasswordFieldWithoutSecrets() async throws {
        let suite = "ftp-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = SiteManager(store: SiteStore(defaults: defaults),
                                  passwords: PasswordStore(service: "test-only", access: MemoryKeychain()))
        var d = SiteDraft()
        d.host = "example.test"; d.loginMode = .account; d.username = "member"; d.rememberPassword = true
        let saved = await manager.save(d)
        XCTAssertNil(saved)
        XCTAssertTrue(manager.sites.isEmpty)
        let issue = try XCTUnwrap(manager.fieldIssue)
        XCTAssertEqual(issue.field, .password)
        XCTAssertTrue(issue.message.contains("密码"))
        XCTAssertEqual(manager.error, issue.message)
        XCTAssertFalse((manager.error ?? "").contains("member"))
        manager.clearEditingError()
        XCTAssertNil(manager.fieldIssue)
        XCTAssertNil(manager.error)
    }

    func testSiteSaveFailuresAndPasswordLifecycle() async throws {
        let suite = "ftp-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = MemoryKeychain()
        let passwords = PasswordStore(service: "test-only", access: access)
        let manager = SiteManager(store: SiteStore(defaults: defaults), passwords: passwords)
        var d = draft()
        access.status = errSecAuthFailed
        let failed = await manager.save(d); XCTAssertNil(failed); XCTAssertTrue(manager.sites.isEmpty)
        XCTAssertEqual(d.password, "secret", "Failure leaves caller's draft intact")
        XCTAssertNotNil(manager.error)
        manager.clearEditingError(); XCTAssertNil(manager.error)
        access.status = errSecSuccess
        let savedFirst = await manager.save(d)
        let first = try XCTUnwrap(savedFirst)
        var edit = SiteDraft(site: first); edit.name = "renamed"
        let renamed = await manager.save(edit); XCTAssertNotNil(renamed)
        let preserved = try await passwords.password(for: first); XCTAssertEqual(preserved, "secret")
        edit.username = "new-user"
        let invalid = await manager.save(edit); XCTAssertNil(invalid)
        XCTAssertEqual(manager.sites[0].username, "member")
        access.status = errSecAuthFailed
        let deleted = await manager.delete(first); XCTAssertFalse(deleted); XCTAssertEqual(manager.sites.count, 1)
        edit = SiteDraft(site: manager.sites[0]); edit.rememberPassword = false
        let failedRemoval = await manager.save(edit); XCTAssertNil(failedRemoval)
        XCTAssertTrue(manager.sites[0].rememberPassword)
        access.status = errSecSuccess
        let saved = await manager.save(edit); XCTAssertNotNil(saved)
        let absent = try await passwords.password(for: first); XCTAssertNil(absent)
        d.id = UUID(); let second = await manager.save(d); XCTAssertNotNil(second)
        let success = await manager.delete(manager.sites[0]); XCTAssertTrue(success)
        let retained = try await passwords.password(for: manager.sites[0]); XCTAssertEqual(retained, "secret")
        defaults.set(Data("broken".utf8), forKey: SiteStore.key)
        let corrupt = SiteManager(store: SiteStore(defaults: defaults), passwords: passwords)
        corrupt.clearEditingError()
        XCTAssertFalse(corrupt.canSave); XCTAssertNotNil(corrupt.error)
        XCTAssertEqual(defaults.data(forKey: SiteStore.key), Data("broken".utf8))
    }
    func testLegacyCredentialReadOnlyLoadingAndProtocolIsolation() async throws {
        let site = try draft().configuration()
        let legacy: [String: Any] = ["identity": ["host": site.host, "port": site.port, "username": site.username,
                                               "mode": "account"], "password": "legacy secret"]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let key = "test-only|" + site.id.uuidString
        for failure in 0...2 {
            let access = MemoryKeychain(); access.items[key] = data
            let store = PasswordStore(service: "test-only", access: access)
            var secure = SiteDraft(site: site); secure.transport = .ftpsExplicit
            let unavailable = try await store.password(for: secure.configuration())
            XCTAssertNil(unavailable)
            XCTAssertEqual(access.items[key], data)
            if failure == 1 { access.writeStatus = errSecAuthFailed }
            if failure == 2 { access.deleteStatus = errSecAuthFailed }
            let password = try await store.password(for: site)
            XCTAssertEqual(password, "legacy secret")
            XCTAssertEqual(access.items[key], data, "Read-only loading must not migrate or delete the source")
            XCTAssertNil(access.items["test-only.v2|" + site.id.uuidString])
        }
    }

    func testSwitchToPrivateKeyCleansOnlyItsPasswordAndPreservesSource() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceBytes = Data("private source remains unchanged".utf8)
        try sourceBytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let suite = "key-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let access = MemoryKeychain(); let passwords = PasswordStore(service: "key-test", access: access)
        let manager = SiteManager(store: SiteStore(defaults: defaults), passwords: passwords)
        var d = draft(); d.transport = .sftp; d.port = "22"; d.encodingPolicy = .utf8
        let saved = await manager.save(d); let original = try XCTUnwrap(saved)
        var other = d; other.id = UUID()
        let savedOther = await manager.save(other); let second = try XCTUnwrap(savedOther)
        d.authenticationMethod = .privateKey
        d.privateKeyReference = PrivateKeyReference(bookmark: Data(source.path.utf8), name: source.lastPathComponent, digest: Data([2]))
        access.deleteStatus = errSecAuthFailed
        let failed = await manager.save(d); XCTAssertNil(failed)
        XCTAssertEqual(manager.sites[0], original)
        access.deleteStatus = errSecSuccess
        let switched = await manager.save(d); let key = try XCTUnwrap(switched)
        // Even a denied keychain must not be read for key authentication.
        access.status = errSecAuthFailed
        let noPassword = try await passwords.password(for: key); XCTAssertNil(noPassword)
        access.status = errSecSuccess
        let otherPassword = try await passwords.password(for: second); XCTAssertEqual(otherPassword, "secret")
        let deleted = await manager.delete(key); XCTAssertTrue(deleted)
        XCTAssertEqual(manager.sites, [second])
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
    }

}
