import XCTest
import Security

final class MemoryKeychain: KeychainAccess {
    var items: [String: Data] = [:]
    var status = errSecSuccess
    var deletes: [String] = []
    private func key(_ query: [String: Any]) -> String {
        "\(query[kSecAttrService as String]!)|\(query[kSecAttrAccount as String]!)"
    }
    func read(_ query: [String: Any]) -> (OSStatus, Data?) {
        guard status == errSecSuccess else { return (status, nil) }
        let data = items[key(query)]
        return (data == nil ? errSecItemNotFound : errSecSuccess, data)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        guard status == errSecSuccess else { return status }
        items[key(attributes)] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        guard status == errSecSuccess else { return status }
        guard items[key(query)] != nil else { return errSecItemNotFound }
        items[key(query)] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        guard status == errSecSuccess else { return status }
        deletes.append(key(query))
        return items.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess
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
}
