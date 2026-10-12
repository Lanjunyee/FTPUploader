import XCTest

final class PrivateKeyDescriptorTests: XCTestCase {
    private let bytes = Data("-----BEGIN RSA PRIVATE KEY-----\nfixture-secret".utf8)
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testNoFollowReadOnlyFlagsBoundedReadsAndDescriptorRelease() throws {
        let url = try folder().appendingPathComponent("key")
        let content = bytes + Data(repeating: 65, count: PrivateKeyAccess.limit - bytes.count)
        try content.write(to: url)
        var opened: Int32 = -1, reads = 0, starts = 0, stops = 0
        let access = PrivateKeyAccess(start: { _ in starts += 1; return true }, stop: { _ in
            stops += 1; XCTAssertEqual(fcntl(opened, F_GETFD), -1); XCTAssertEqual(errno, EBADF)
        }, readBytes: { handle, bound in
            XCTAssertLessThanOrEqual(bound, 64 * 1024)
            reads += 1; return try handle.read(upToCount: min(bound, 7_777)) ?? Data()
        }, openFile: { url, flags in
            XCTAssertEqual(flags & O_ACCMODE, O_RDONLY)
            XCTAssertEqual(flags & (O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK), O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            opened = Darwin.open(url.path, flags); return opened
        })
        XCTAssertEqual(try access.read(url).bytes, content)
        XCTAssertGreaterThan(reads, 16)
        XCTAssertEqual(starts, 1); XCTAssertEqual(stops, 1)
        XCTAssertEqual(try Data(contentsOf: url), content)
    }
    func testInvalidObjectsAndBoundsAreRejectedBeforeOpening() throws {
        let base = try folder(), url = base.appendingPathComponent("key")
        for kind in ["empty", "large", "directory", "link", "fifo"] {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            switch kind {
            case "empty": try Data().write(to: url)
            case "large": try Data(repeating: 65, count: PrivateKeyAccess.limit + 1).write(to: url)
            case "directory": try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            case "link": try FileManager.default.createSymbolicLink(at: url, withDestinationURL: base)
            default: XCTAssertEqual(mkfifo(url.path, 0o600), 0)
            }
            var opens = 0, reads = 0, stops = 0
            let access = PrivateKeyAccess(start: { _ in true }, stop: { _ in stops += 1 }, readBytes: { _, _ in
                reads += 1; return Data()
            }, openFile: { _, _ in opens += 1; return -1 })
            XCTAssertThrowsError(try access.read(url))
            XCTAssertEqual(opens, 0); XCTAssertEqual(reads, 0); XCTAssertEqual(stops, 1)
        }
    }
    func testReplacementBeforeOpenAndSubstituteDescriptorCannotReadForeignContent() throws {
        for kind in ["link", "file", "foreign-fd"] {
            let base = try folder(), url = base.appendingPathComponent("key"), saved = base.appendingPathComponent("saved")
            let foreign = base.appendingPathComponent("foreign")
            try bytes.write(to: url); try (bytes + Data("foreign".utf8)).write(to: foreign)
            var descriptor: Int32 = -1, reads = 0, starts = 0, stops = 0
            let access = PrivateKeyAccess(start: { _ in starts += 1; return true }, stop: { _ in stops += 1 },
                readBytes: { handle, bound in reads += 1; return try handle.read(upToCount: bound) ?? Data() },
                openFile: { _, flags in
                    try FileManager.default.moveItem(at: url, to: saved)
                    if kind == "link" { try FileManager.default.createSymbolicLink(at: url, withDestinationURL: foreign) }
                    else { try FileManager.default.copyItem(at: foreign, to: url) }
                    descriptor = Darwin.open(url.path, flags)
                    if kind == "foreign-fd" {
                        // Keep the foreign fd, but restore the selected path before fstat.
                        try FileManager.default.removeItem(at: url)
                        try FileManager.default.moveItem(at: saved, to: url)
                    }
                    return descriptor
                })
            XCTAssertThrowsError(try access.read(url))
            XCTAssertEqual(reads, 0, "Unapproved descriptors must fail before reading")
            XCTAssertEqual(starts, 1); XCTAssertEqual(stops, 1)
            if descriptor >= 0 { XCTAssertEqual(fcntl(descriptor, F_GETFD), -1); XCTAssertEqual(errno, EBADF) }
        }
    }
    func testSameInodeRewriteWithRestoredMtimeAndOtherReadTimeChangesAreRejected() throws {
        for kind in ["rewrite", "grow", "truncate", "link", "replace"] {
            let base = try folder(), url = base.appendingPathComponent("key"), saved = base.appendingPathComponent("saved")
            try bytes.write(to: url)
            var initial = stat(); XCTAssertEqual(lstat(url.path, &initial), 0)
            var changed = false, descriptor: Int32 = -1, stops = 0
            let access = PrivateKeyAccess(start: { _ in true }, stop: { _ in stops += 1 }, readBytes: { handle, bound in
                let result = try handle.read(upToCount: bound) ?? Data()
                if !changed {
                    changed = true
                    if kind == "link" || kind == "replace" {
                        try FileManager.default.moveItem(at: url, to: saved)
                        if kind == "link" { try FileManager.default.createSymbolicLink(at: url, withDestinationURL: saved) }
                        else { try self.bytes.write(to: url) }
                    } else {
                        let writer = try FileHandle(forWritingTo: url)
                        defer { try? writer.close() }
                        if kind == "truncate" { try writer.truncate(atOffset: 1) }
                        else if kind == "grow" { try writer.seekToEnd(); try writer.write(contentsOf: Data([42])) }
                        else {
                            Thread.sleep(forTimeInterval: 0.002)
                            try writer.write(contentsOf: Data(repeating: 65, count: self.bytes.count))
                            var times = [initial.st_atimespec, initial.st_mtimespec]
                            XCTAssertEqual(futimens(writer.fileDescriptor, &times), 0)
                            var after = stat(); XCTAssertEqual(fstat(writer.fileDescriptor, &after), 0)
                            XCTAssertEqual(after.st_ino, initial.st_ino)
                            XCTAssertEqual(after.st_size, initial.st_size)
                            XCTAssertEqual(after.st_mtimespec.tv_sec, initial.st_mtimespec.tv_sec)
                            XCTAssertEqual(after.st_mtimespec.tv_nsec, initial.st_mtimespec.tv_nsec)
                            XCTAssertTrue(after.st_ctimespec.tv_sec != initial.st_ctimespec.tv_sec || after.st_ctimespec.tv_nsec != initial.st_ctimespec.tv_nsec)
                        }
                    }
                }
                return result
            }, openFile: { url, flags in descriptor = Darwin.open(url.path, flags); return descriptor })
            XCTAssertThrowsError(try access.read(url))
            XCTAssertEqual(stops, 1)
            XCTAssertEqual(fcntl(descriptor, F_GETFD), -1); XCTAssertEqual(errno, EBADF)
        }
    }
    func testAncestorReplacementWithSameLeafInodeIsRejectedBeforeOrAfterRead() throws {
        for duringRead in [false, true] {
            let base = try folder(), parent = base.appendingPathComponent("parent"), alternate = base.appendingPathComponent("alternate")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: false)
            let url = parent.appendingPathComponent("key")
            try bytes.write(to: url)
            XCTAssertEqual(link(url.path, alternate.appendingPathComponent("key").path), 0)
            var initial = stat(); XCTAssertEqual(lstat(url.path, &initial), 0)
            var changed = false, reads = 0, stops = 0
            func replace() throws {
                if changed { return }; changed = true
                try FileManager.default.moveItem(at: parent, to: base.appendingPathComponent("original"))
                try FileManager.default.moveItem(at: alternate, to: parent)
                var after = stat(); XCTAssertEqual(lstat(url.path, &after), 0)
                XCTAssertEqual(after.st_dev, initial.st_dev); XCTAssertEqual(after.st_ino, initial.st_ino)
                XCTAssertEqual(after.st_ctimespec.tv_sec, initial.st_ctimespec.tv_sec)
                XCTAssertEqual(after.st_ctimespec.tv_nsec, initial.st_ctimespec.tv_nsec)
            }
            let access = PrivateKeyAccess(start: { _ in true }, stop: { _ in stops += 1 }, readBytes: { handle, bound in
                reads += 1; let result = try handle.read(upToCount: bound) ?? Data()
                if duringRead { try replace() }; return result
            }, openFile: { url, flags in
                if !duringRead { try replace() }; return Darwin.open(url.path, flags)
            })
            XCTAssertThrowsError(try access.read(url))
            XCTAssertEqual(stops, 1)
            XCTAssertEqual(reads > 0, duringRead)
        }
    }
    func testStableInitialAncestorAliasIsAllowedButChangedAliasIsRejected() throws {
        let base = try folder(), original = base.appendingPathComponent("original"), alias = base.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        try bytes.write(to: original.appendingPathComponent("key"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        let url = alias.appendingPathComponent("key")
        XCTAssertEqual(try PrivateKeyAccess().read(url).bytes, bytes)
        var changed = false
        let access = PrivateKeyAccess(readBytes: { handle, bound in
            let result = try handle.read(upToCount: bound) ?? Data()
            if !changed {
                changed = true
                try FileManager.default.moveItem(at: alias, to: base.appendingPathComponent("old-alias"))
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
            }
            return result
        })
        XCTAssertThrowsError(try access.read(url))
    }

    func testReadFailureAndExcessiveInjectedReadReleaseDescriptorAndRedactError() throws {
        let url = try folder().appendingPathComponent("key")
        try bytes.write(to: url)
        for excess in [false, true] {
            var descriptor: Int32 = -1, stops = 0
            let access = PrivateKeyAccess(start: { _ in true }, stop: { _ in stops += 1 }, readBytes: { _, bound in
                if excess { return Data(repeating: 65, count: bound + 1) }
                throw NSError(domain: "fixture-secret", code: 1)
            }, openFile: { url, flags in descriptor = Darwin.open(url.path, flags); return descriptor })
            XCTAssertThrowsError(try access.read(url)) { XCTAssertFalse($0.localizedDescription.contains("fixture-secret")) }
            XCTAssertEqual(stops, 1)
            XCTAssertEqual(fcntl(descriptor, F_GETFD), -1); XCTAssertEqual(errno, EBADF)
        }
    }
}

final class SiteArchiveStoreTests: XCTestCase {
    private func fixture() throws -> (URL, UserDefaults) {
        let name = "archive-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        return (directory.appendingPathComponent("sites.json"), defaults)
    }
    private func site() throws -> FTPSite {
        var draft = SiteDraft(); draft.host = "example.test"; draft.loginMode = .account
        draft.username = "member"; draft.rememberPassword = true; draft.password = "password-secret"
        return try draft.configuration()
    }
    func testArchiveAndJournalRoundTripKeepRawDefaultsAndImmutableBackup() throws {
        let (url, defaults) = try fixture(), old = try site()
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([old])) as? [[String: Any]])
        records[0].removeValue(forKey: "transport")
        let raw = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted])
        defaults.set(raw, forKey: SiteStore.key)
        let store = SiteArchiveStore(url: url, defaults: defaults)
        XCTAssertEqual(try store.load(), [old])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        var next = old; next.name = "renamed"
        let journal = SiteTransactionJournal(siteID: old.id, oldSites: [old], newSites: [next], oldArchiveExists: false,
            oldLegacyCredentialExists: true, oldCredentialExists: false, newCredentialExists: true)
        try store.preserveLegacyBackup(); try store.saveJournal(journal)
        try store.save([next])
        let restarted = SiteArchiveStore(url: url, defaults: defaults)
        XCTAssertEqual(try restarted.load(), [next]); XCTAssertEqual(try restarted.loadJournal(), journal)
        XCTAssertEqual(defaults.data(forKey: SiteStore.key), raw)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), raw)
        try store.preserveLegacyBackup()
        XCTAssertEqual(try Data(contentsOf: store.backupURL), raw)
        var committed = journal; committed.phase = .committed
        try store.saveJournal(committed, replacing: journal)
        XCTAssertEqual(try store.loadJournal(), committed)
        XCTAssertThrowsError(try store.removeJournal(journal))
        try store.removeJournal(committed); try store.removeJournal(committed)
        XCTAssertNil(try store.loadJournal())
        for file in [url, store.backupURL] {
            XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("password-secret"))
        }
    }
    func testCorruptUnsupportedArchiveAndJournalAreNeverOverwritten() throws {
        let (url, defaults) = try fixture(), old = try site()
        let store = SiteArchiveStore(url: url, defaults: defaults)
        for bytes in [Data("corrupt".utf8), Data("{\"version\":99,\"sites\":[]}".utf8)] {
            try bytes.write(to: url)
            XCTAssertThrowsError(try store.load()); XCTAssertThrowsError(try store.save([old]))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        try FileManager.default.removeItem(at: url)
        let journal = SiteTransactionJournal(siteID: old.id, oldSites: [], newSites: [old], oldArchiveExists: false,
            oldLegacyCredentialExists: false, oldCredentialExists: false, newCredentialExists: true)
        let corrupt = Data("{\"version\":99}".utf8)
        try corrupt.write(to: store.journalURL)
        XCTAssertThrowsError(try store.loadJournal()); XCTAssertThrowsError(try store.saveJournal(journal))
        XCTAssertThrowsError(try store.removeJournal(journal))
        XCTAssertEqual(try Data(contentsOf: store.journalURL), corrupt)
    }
    func testBackupMismatchAndWriterFailuresPreserveAllSourceData() throws {
        let (url, defaults) = try fixture(), old = try site(), source = try JSONEncoder().encode([old])
        defaults.set(source, forKey: SiteStore.key)
        let store = SiteArchiveStore(url: url, defaults: defaults)
        _ = try store.load()
        let foreign = Data("existing-backup".utf8)
        try foreign.write(to: store.backupURL)
        XCTAssertThrowsError(try store.save([old]))
        XCTAssertEqual(try Data(contentsOf: store.backupURL), foreign)
        XCTAssertEqual(defaults.data(forKey: SiteStore.key), source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try FileManager.default.removeItem(at: store.backupURL)
        let backupFailure = SiteArchiveStore(url: url, defaults: defaults, backupWriter: { _, _ in throw POSIXError(.ENOSPC) })
        _ = try backupFailure.load(); XCTAssertThrowsError(try backupFailure.save([old]))
        XCTAssertEqual(defaults.data(forKey: SiteStore.key), source)
        try store.save([old])
        let original = try Data(contentsOf: url)
        let writeFailure = SiteArchiveStore(url: url, defaults: defaults, writer: { _, _ in throw POSIXError(.ENOSPC) })
        _ = try writeFailure.load()
        XCTAssertThrowsError(try writeFailure.save([]))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), source)
        XCTAssertEqual(defaults.data(forKey: SiteStore.key), source)
    }
    func testInvalidSitesStaleArchiveAndJournalCrossSiteEditsAreBlocked() throws {
        let (url, defaults) = try fixture(), old = try site(), other = try site()
        let store = SiteArchiveStore(url: url, defaults: defaults)
        _ = try store.load(); try store.save([old, other])
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try store.save([old, old]))
        var changedOther = other; changedOther.name = "unrelated-change"
        let journal = SiteTransactionJournal(siteID: old.id, oldSites: [old, other], newSites: [old, changedOther], oldArchiveExists: true,
            oldLegacyCredentialExists: false, oldCredentialExists: true, newCredentialExists: true)
        XCTAssertThrowsError(try store.saveJournal(journal))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.journalURL.path))
        let concurrent = SiteArchiveStore(url: url, defaults: defaults)
        _ = try concurrent.load(); try concurrent.save([])
        let external = try Data(contentsOf: url)
        XCTAssertThrowsError(try store.save([old]))
        XCTAssertEqual(try Data(contentsOf: url), external); XCTAssertNotEqual(external, original)
    }
    func testPrivateKeySitesAndJournalContainReferencesButNotDraftSecrets() throws {
        let (url, defaults) = try fixture()
        var draft = SiteDraft(); draft.host = "example.test"; draft.transport = .sftp; draft.port = "22"
        draft.loginMode = .account; draft.username = "member"; draft.authenticationMethod = .privateKey; draft.encodingPolicy = .utf8
        draft.privateKeyReference = PrivateKeyReference(bookmark: Data([1]), name: "key", digest: Data([2]))
        draft.password = "password-secret"; draft.passphrase = "phrase-secret"
        let keySite = try draft.configuration(), store = SiteArchiveStore(url: url, defaults: defaults)
        _ = try store.load(); try store.save([keySite])
        let journal = SiteTransactionJournal(siteID: keySite.id, oldSites: [keySite], newSites: [], oldArchiveExists: true,
            oldLegacyCredentialExists: false, oldCredentialExists: false, newCredentialExists: false)
        try store.saveJournal(journal)
        for file in [url, store.journalURL] {
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            XCTAssertFalse(text.contains("password-secret")); XCTAssertFalse(text.contains("phrase-secret"))
            XCTAssertFalse(text.contains("BEGIN")); XCTAssertFalse(text.contains("\"password\"")); XCTAssertFalse(text.contains("\"passphrase\""))
        }
        XCTAssertEqual(try store.load(), [keySite])
    }
}

@MainActor
final class SiteTransactionTests: XCTestCase {
    private func fixture(writer: ((Data, URL) throws -> Void)? = nil, remover: ((URL) throws -> Void)? = nil) throws
        -> (SiteArchiveStore, PasswordStore, MemoryKeychain) {
        let name = "transaction-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        let archive = SiteArchiveStore(url: directory.appendingPathComponent("sites.json"), defaults: defaults,
            writer: writer ?? { try $0.write(to: $1, options: .atomic) },
            remover: remover ?? { try FileManager.default.removeItem(at: $0) })
        _ = try archive.load()
        let access = MemoryKeychain()
        return (archive, PasswordStore(service: "txn-test", access: access), access)
    }
    private func site(remember: Bool = true) throws -> FTPSite {
        var draft = SiteDraft(); draft.host = "example.test"; draft.loginMode = .account
        draft.username = "member"; draft.rememberPassword = remember
        return try draft.configuration()
    }
    private func changed(_ old: FTPSite) -> FTPSite { var next = old; next.name = "new name"; return next }

    func testPreparedIsPublishedOnlyAfterRecoveryVerification() async throws {
        var recoveryPresent = false
        var memory: MemoryKeychain?
        let (archive, passwords, access) = try fixture(writer: { bytes, url in
            if url.pathExtension == "journal" {
                let journal = try JSONDecoder().decode(SiteTransactionJournal.self, from: bytes)
                recoveryPresent = memory?.items["txn-test.recovery-v1|" + journal.id.uuidString] != nil
                XCTAssertTrue(recoveryPresent)
            }
            try bytes.write(to: url, options: .atomic)
        })
        memory = access
        let old = try site(); try archive.save([old]); try await passwords.save("old", for: old)
        let coordinator = SiteTransactionCoordinator(archive: archive, passwords: passwords)
        let journal = try await coordinator.prepare(siteID: old.id, newSites: [changed(old)], expectedOldSites: [old])
        XCTAssertTrue(recoveryPresent); XCTAssertEqual(coordinator.state, .prepared)
        XCTAssertEqual(try archive.loadJournal(), journal)
        XCTAssertEqual(try archive.load(), [old])
        let secret = try await passwords.password(for: old); XCTAssertEqual(secret, "old")
    }
    func testRecoverySaveFailureCannotPublishPreparedOrMutateSource() async throws {
        let (archive, passwords, access) = try fixture(), old = try site()
        try archive.save([old]); try await passwords.save("old", for: old)
        let original = access.items
        access.writeStatus = errSecAuthFailed
        let coordinator = SiteTransactionCoordinator(archive: archive, passwords: passwords)
        do { _ = try await coordinator.prepare(siteID: old.id, newSites: [changed(old)], expectedOldSites: [old]); XCTFail() } catch {}
        XCTAssertNil(try archive.loadJournal()); XCTAssertEqual(try archive.load(), [old]); XCTAssertEqual(access.items, original)
    }
    func testJournalPublicationFailureLeavesOnlyCleanableOrphan() async throws {
        var failPublication = true
        let (archive, passwords, access) = try fixture(writer: { bytes, url in
            if url.pathExtension == "journal" && failPublication { throw POSIXError(.ENOSPC) }
            try bytes.write(to: url, options: .atomic)
        })
        let old = try site(); try archive.save([old]); try await passwords.save("old", for: old)
        let coordinator = SiteTransactionCoordinator(archive: archive, passwords: passwords)
        do { _ = try await coordinator.prepare(siteID: old.id, newSites: [changed(old)], expectedOldSites: [old]); XCTFail() } catch {}
        XCTAssertNil(try archive.loadJournal()); XCTAssertEqual(try archive.load(), [old])
        let orphans = try await passwords.recoveryIDs(); XCTAssertEqual(orphans.count, 1)
        failPublication = false
        let sites = try await SiteTransactionCoordinator(archive: archive, passwords: passwords).recover()
        XCTAssertEqual(sites, [old])
        let remaining = try await passwords.recoveryIDs(); XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(access.items.count, 1)
        let secret = try await passwords.password(for: old); XCTAssertEqual(secret, "old")
    }
    func testCommitCannotBypassMissingPreparedRecovery() async throws {
        let (archive, passwords, _) = try fixture(), old = try site(), next = changed(old)
        try archive.save([old]); try await passwords.save("old", for: old)
        let coordinator = SiteTransactionCoordinator(archive: archive, passwords: passwords)
        let prepared = try await coordinator.prepare(siteID: old.id, newSites: [next], expectedOldSites: [old])
        try await passwords.save("new", for: next); try archive.save([next])
        try await passwords.removeRecovery(transactionID: prepared.id)
        do { _ = try await coordinator.markCommitted(prepared); XCTFail("Missing material promoted to committed") } catch {}
        XCTAssertEqual(try archive.loadJournal(), prepared); XCTAssertEqual(coordinator.state, .recoveryPending)
    }
    func testOrphanRecoveryIsOnlyCleanedNeverApplied() async throws {
        let (archive, passwords, access) = try fixture(), old = try site()
        try archive.save([old]); try await passwords.save("old", for: old)
        let snapshot = try await passwords.capture(id: old.id), orphan = UUID()
        try await passwords.saveRecovery(snapshot, transactionID: orphan)
        try await passwords.save("current", for: old)
        let coordinator = SiteTransactionCoordinator(archive: archive, passwords: passwords)
        let sites = try await coordinator.recover()
        XCTAssertEqual(sites, [old]); XCTAssertEqual(coordinator.state, .idle)
        let secret = try await passwords.password(for: old); XCTAssertEqual(secret, "current")
        XCTAssertNil(access.items["txn-test.recovery-v1|" + orphan.uuidString])
    }
    func testPreparedMissingNecessarySecretFailsClosedForLegacyAndV2() async throws {
        for legacy in [false, true] {
            let (archive, passwords, access) = try fixture(), old = try site(), next = changed(old)
            try archive.save([old]); try await passwords.save("old", for: old)
            if legacy {
                access.items["txn-test|" + old.id.uuidString] = access.items.removeValue(forKey: "txn-test.v2|" + old.id.uuidString)
            }
            let coordinator = SiteTransactionCoordinator(archive: archive, passwords: passwords)
            let prepared = try await coordinator.prepare(siteID: old.id, newSites: [next], expectedOldSites: [old])
            try await passwords.save("new", for: next); try archive.save([next])
            try await passwords.removeRecovery(transactionID: prepared.id)
            let before = access.items, original = try Data(contentsOf: archive.url)
            let restarted = SiteTransactionCoordinator(archive: archive, passwords: passwords)
            do { _ = try await restarted.recover(); XCTFail("Missing recovery accepted") } catch {}
            XCTAssertEqual(restarted.state, .recoveryPending); XCTAssertEqual(restarted.affectedSiteID, old.id)
            XCTAssertEqual(try Data(contentsOf: archive.url), original); XCTAssertEqual(access.items, before)
            XCTAssertEqual(try archive.loadJournal(), prepared)
        }
    }
    func testPreparedWithoutOldSecretsRestoresAbsenceEvenWhenRecoveryItemMissing() async throws {
        let (archive, passwords, _) = try fixture(), next = try site()
        let coordinator = SiteTransactionCoordinator(archive: archive, passwords: passwords)
        let prepared = try await coordinator.prepare(siteID: next.id, newSites: [next], expectedOldSites: [])
        try await passwords.save("new", for: next); try archive.save([next])
        try await passwords.removeRecovery(transactionID: prepared.id)
        let restored = try await SiteTransactionCoordinator(archive: archive, passwords: passwords).recover()
        XCTAssertEqual(restored, []); XCTAssertFalse(archive.archiveExists); XCTAssertNil(try archive.loadJournal())
        let snapshot = try await passwords.capture(id: next.id)
        XCTAssertFalse(snapshot.hasLegacy); XCTAssertFalse(snapshot.hasCurrent)
    }
    func testPreparedRollbackAndCleanupInterruptionAreSafelyReentrant() async throws {
        var failRemoval = true
        let (archive, passwords, access) = try fixture(remover: { url in
            if url.pathExtension == "journal" && failRemoval { throw POSIXError(.EACCES) }
            try FileManager.default.removeItem(at: url)
        })
        let old = try site(), next = changed(old)
        try archive.save([old]); try await passwords.save("old", for: old)
        let coordinator = SiteTransactionCoordinator(archive: archive, passwords: passwords)
        let prepared = try await coordinator.prepare(siteID: old.id, newSites: [next], expectedOldSites: [old])
        try await passwords.save("new", for: next); try archive.save([next])
        do { _ = try await coordinator.recover(); XCTFail("Removal failure hidden") } catch {}
        XCTAssertEqual(try archive.load(), [old]); XCTAssertEqual(try archive.loadJournal(), prepared)
        XCTAssertNotNil(access.items["txn-test.recovery-v1|" + prepared.id.uuidString])
        failRemoval = false
        let sites = try await SiteTransactionCoordinator(archive: archive, passwords: passwords).recover()
        XCTAssertEqual(sites, [old]); XCTAssertNil(try archive.loadJournal())
        let secret = try await passwords.password(for: old); XCTAssertEqual(secret, "old")
        let ids = try await passwords.recoveryIDs(); XCTAssertTrue(ids.isEmpty)
    }
    func testCommittedCleanupFailureAndMissingRecoveryNeverRollBackNewState() async throws {
        for failKeychainCleanup in [false, true] {
            var failJournalRemoval = !failKeychainCleanup
            let (archive, passwords, access) = try fixture(remover: { url in
                if url.pathExtension == "journal" && failJournalRemoval { throw POSIXError(.EACCES) }
                try FileManager.default.removeItem(at: url)
            })
            let old = try site(), next = changed(old)
            try archive.save([old]); try await passwords.save("old", for: old)
            let coordinator = SiteTransactionCoordinator(archive: archive, passwords: passwords)
            let prepared = try await coordinator.prepare(siteID: old.id, newSites: [next], expectedOldSites: [old])
            try await passwords.save("new", for: next); try archive.save([next])
            let committed = try await coordinator.markCommitted(prepared)
            if failKeychainCleanup { access.deleteStatus = errSecAuthFailed }
            do { try await coordinator.finish(committed); XCTFail("Cleanup failure hidden") } catch {}
            XCTAssertEqual(coordinator.state, .committedCleanupPending)
            XCTAssertEqual(try archive.load(), [next]); XCTAssertEqual(try archive.loadJournal(), committed)
            let recoveryKey = "txn-test.recovery-v1|" + committed.id.uuidString
            XCTAssertEqual(access.items[recoveryKey] != nil, failKeychainCleanup)
            access.deleteStatus = errSecSuccess; failJournalRemoval = false
            let sites = try await SiteTransactionCoordinator(archive: archive, passwords: passwords).recover()
            XCTAssertEqual(sites, [next]); XCTAssertNil(try archive.loadJournal())
            let secret = try await passwords.password(for: next); XCTAssertEqual(secret, "new")
            XCTAssertNil(access.items[recoveryKey])
        }
    }
    func testCleanupReadBackRejectsSuccessfulNoopDeletionThenSafelyRetries() async throws {
        for keychainNoop in [false, true] {
            var journalNoop = !keychainNoop
            let (archive, passwords, access) = try fixture(remover: { url in
                if url.pathExtension == "journal" && journalNoop { return }
                try FileManager.default.removeItem(at: url)
            })
            let old = try site(), next = changed(old)
            try archive.save([old]); try await passwords.save("old", for: old)
            let coordinator = SiteTransactionCoordinator(archive: archive, passwords: passwords)
            let prepared = try await coordinator.prepare(siteID: old.id, newSites: [next], expectedOldSites: [old])
            try await passwords.save("new", for: next); try archive.save([next])
            let committed = try await coordinator.markCommitted(prepared)
            access.retainDeletedItems = keychainNoop
            do { try await coordinator.finish(committed); XCTFail("No-op deletion reported complete") } catch {}
            XCTAssertEqual(coordinator.state, .committedCleanupPending)
            XCTAssertEqual(try archive.loadJournal(), committed); XCTAssertEqual(try archive.load(), [next])
            XCTAssertEqual(access.items["txn-test.recovery-v1|" + committed.id.uuidString] != nil, keychainNoop)
            access.retainDeletedItems = false; journalNoop = false
            let restored = try await SiteTransactionCoordinator(archive: archive, passwords: passwords).recover()
            XCTAssertEqual(restored, [next]); XCTAssertNil(try archive.loadJournal())
        }
    }
    func testUnknownConfigurationAndCorruptJournalPreserveEveryRecoveryItem() async throws {
        for corruptJournal in [false, true] {
            let (archive, passwords, access) = try fixture(), old = try site(), unknown = try site()
            try archive.save([old]); try await passwords.save("old", for: old)
            let coordinator = SiteTransactionCoordinator(archive: archive, passwords: passwords)
            _ = try await coordinator.prepare(siteID: old.id, newSites: [changed(old)], expectedOldSites: [old])
            if corruptJournal { try Data("corrupt".utf8).write(to: archive.journalURL) }
            else { try archive.save([unknown]) }
            let keys = access.items, bytes = try Data(contentsOf: archive.url), journalBytes = try Data(contentsOf: archive.journalURL)
            do { _ = try await SiteTransactionCoordinator(archive: archive, passwords: passwords).recover(); XCTFail() } catch {}
            XCTAssertEqual(access.items, keys); XCTAssertEqual(try Data(contentsOf: archive.url), bytes)
            XCTAssertEqual(try Data(contentsOf: archive.journalURL), journalBytes)
        }
    }
}

@MainActor
final class TransactionalSiteManagerTests: XCTestCase {
    private final class Faults {
        var archiveFailures = 0
        var journalRemovalFailure = false
        var onArchiveFailure: (() -> Void)?
    }
    private func fixture(source: Data? = nil) throws -> (SiteArchiveStore, PasswordStore, MemoryKeychain, Faults) {
        let name = "manager-transactions-" + UUID().uuidString, faults = Faults()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        if let source { defaults.set(source, forKey: SiteStore.key) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        let archive = SiteArchiveStore(url: directory.appendingPathComponent("sites.json"), defaults: defaults,
            writer: { bytes, url in
                if url.pathExtension == "json" && faults.archiveFailures != 0 {
                    if faults.archiveFailures > 0 { faults.archiveFailures -= 1 }
                    faults.onArchiveFailure?(); throw POSIXError(.ENOSPC)
                }
                try bytes.write(to: url, options: .atomic)
            }, remover: { url in
                if url.pathExtension == "journal" && faults.journalRemovalFailure { throw POSIXError(.EACCES) }
                try FileManager.default.removeItem(at: url)
            })
        _ = try archive.load()
        let access = MemoryKeychain()
        return (archive, PasswordStore(service: "manager-txn", access: access), access, faults)
    }
    private func draft() -> SiteDraft {
        var value = SiteDraft(); value.host = "example.test"; value.loginMode = .account
        value.username = "member"; value.rememberPassword = true; value.password = "old-secret"
        return value
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { throw POSIXError(.ETIMEDOUT) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    private func legacySource(_ site: FTPSite) throws -> Data {
        var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([site])) as? [[String: Any]])
        for field in ["transport", "encodingPolicy", "authenticationMethod", "privateKeyReference"] { rows[0].removeValue(forKey: field) }
        return try JSONSerialization.data(withJSONObject: rows)
    }
    private func legacyRecord(_ site: FTPSite) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["identity": ["host": site.host, "port": site.port,
            "username": site.username, "mode": "account"], "password": "legacy-secret"])
    }
    func testLegacyMissingFieldsRemainReadOnlyUntilTransactionalSaveAndRawBackupIsPreserved() async throws {
        let old = try draft().configuration(), raw = try legacySource(old)
        let (archive, passwords, access, _) = try fixture(source: raw)
        let key = "manager-txn|" + old.id.uuidString, secretRecord = try legacyRecord(old)
        access.items[key] = secretRecord
        let manager = SiteManager(store: archive, passwords: passwords)
        try await wait { !manager.isRecovering }
        XCTAssertEqual(manager.sites, [old]); XCTAssertEqual(manager.sites.first?.transport, .ftp)
        XCTAssertEqual(manager.sites.first?.authenticationMethod, .password)
        XCTAssertEqual(manager.sites.first?.encodingPolicy, .automatic)
        let loaded = try await manager.password(for: old); XCTAssertEqual(loaded, "legacy-secret")
        XCTAssertEqual(access.items[key], secretRecord); XCTAssertFalse(archive.archiveExists)
        var edit = SiteDraft(site: old); edit.name = "new name"
        let saved = await manager.save(edit); XCTAssertNotNil(saved)
        XCTAssertTrue(archive.archiveExists); XCTAssertNil(access.items[key])
        XCTAssertEqual(try Data(contentsOf: archive.backupURL), raw)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: archive.url.deletingLastPathComponent().lastPathComponent))
        XCTAssertEqual(defaults.data(forKey: SiteStore.key), raw)
        let migrated = try await manager.password(for: XCTUnwrap(saved)); XCTAssertEqual(migrated, "legacy-secret")
        let rebuilt = SiteManager(store: archive, passwords: passwords)
        try await wait { !rebuilt.isRecovering }; XCTAssertEqual(rebuilt.sites, manager.sites)
        XCTAssertEqual(try Data(contentsOf: archive.backupURL), raw)
    }
    func testLegacyMigrationFailureRetainsOriginalBytesAndRestartCanRetry() async throws {
        let old = try draft().configuration(), raw = try legacySource(old)
        let (archive, passwords, access, faults) = try fixture(source: raw)
        let key = "manager-txn|" + old.id.uuidString, original = try legacyRecord(old)
        access.items[key] = original
        let manager = SiteManager(store: archive, passwords: passwords)
        try await wait { !manager.isRecovering }
        faults.archiveFailures = 1
        var edit = SiteDraft(site: old); edit.name = "new name"
        let failed = await manager.save(edit); XCTAssertNil(failed)
        XCTAssertFalse(archive.archiveExists); XCTAssertEqual(manager.sites, [old]); XCTAssertEqual(access.items[key], original)
        XCTAssertNil(access.items["manager-txn.v2|" + old.id.uuidString])
        XCTAssertEqual(try Data(contentsOf: archive.backupURL), raw)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: archive.url.deletingLastPathComponent().lastPathComponent))
        XCTAssertEqual(defaults.data(forKey: SiteStore.key), raw)
        let rebuilt = SiteManager(store: archive, passwords: passwords)
        try await wait { !rebuilt.isRecovering }
        let saved = await rebuilt.save(edit); XCTAssertNotNil(saved)
        XCTAssertNil(access.items[key]); XCTAssertEqual(try Data(contentsOf: archive.backupURL), raw)
    }
    func testLegacyMigrationInterruptionAfterBackupOrHalfKeychainWriteRestoresSource() async throws {
        for boundary in ["backup", "half-keychain", "archive", "committed"] {
            let old = try draft().configuration(), raw = try legacySource(old)
            let (archive, passwords, access, _) = try fixture(source: raw)
            let legacyKey = "manager-txn|" + old.id.uuidString, original = try legacyRecord(old)
            access.items[legacyKey] = original
            try archive.preserveLegacyBackup()
            if boundary != "backup" {
                let coordinator = SiteTransactionCoordinator(archive: archive, passwords: passwords)
                let prepared = try await coordinator.prepare(siteID: old.id, newSites: [old], expectedOldSites: [old])
                // Simulate termination after v2 write, before legacy deletion.
                var record = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
                record["identity"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old.identity))
                access.items["manager-txn.v2|" + old.id.uuidString] = try JSONSerialization.data(withJSONObject: record)
                if boundary != "half-keychain" {
                    access.items.removeValue(forKey: legacyKey)
                    try archive.save([old])
                    if boundary == "committed" { _ = try await coordinator.markCommitted(prepared) }
                }
            }
            let rebuilt = SiteManager(store: archive, passwords: passwords)
            try await wait { !rebuilt.isRecovering }
            XCTAssertTrue(rebuilt.canSave, rebuilt.error ?? ""); XCTAssertEqual(rebuilt.sites, [old])
            XCTAssertEqual(archive.archiveExists, boundary == "committed")
            XCTAssertEqual(access.items[legacyKey], boundary == "committed" ? nil : original)
            XCTAssertEqual(try Data(contentsOf: archive.backupURL), raw)
            let secret = try await rebuilt.password(for: old); XCTAssertEqual(secret, "legacy-secret")
            XCTAssertNil(try archive.loadJournal())
        }
    }
    func testMigrationNeverReusesLegacyFTPSecretForEncryptedProtocol() async throws {
        for transport in [FileTransport.ftpsExplicit, .sftp] {
            let old = try draft().configuration(), raw = try legacySource(old)
            let (archive, passwords, access, _) = try fixture(source: raw)
            let legacyKey = "manager-txn|" + old.id.uuidString, original = try legacyRecord(old)
            access.items[legacyKey] = original
            let manager = SiteManager(store: archive, passwords: passwords)
            try await wait { !manager.isRecovering }
            var edit = SiteDraft(site: old); edit.transport = transport
            if transport == .sftp { edit.encodingPolicy = .utf8 }
            let unavailable = try await passwords.password(for: edit.configuration()); XCTAssertNil(unavailable)
            let denied = await manager.save(edit); XCTAssertNil(denied)
            XCTAssertEqual(manager.fieldIssue?.field, .password); XCTAssertEqual(access.items[legacyKey], original)
            XCTAssertFalse(archive.archiveExists)
            edit.password = "explicit-new-secret"
            let saved = await manager.save(edit); XCTAssertEqual(saved?.transport, transport)
            do { _ = try await passwords.password(for: old); XCTFail("Old protocol identity reused a new credential") } catch {}
            let newSecret = try await manager.password(for: XCTUnwrap(saved)); XCTAssertEqual(newSecret, "explicit-new-secret")
            XCTAssertEqual(try Data(contentsOf: archive.backupURL), raw)
        }
    }
    func testPrivateKeyConfigurationMigrationCleansLegacyPasswordWithoutReadingOrChangingSourceKey() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceBytes = Data("private-key-source-never-persisted".utf8)
        try sourceBytes.write(to: source); defer { try? FileManager.default.removeItem(at: source) }
        var value = draft(); value.transport = .sftp; value.port = "22"; value.encodingPolicy = .utf8; value.authenticationMethod = .privateKey
        value.privateKeyReference = PrivateKeyReference(bookmark: Data(source.path.utf8), name: "key", digest: Data([2]))
        let old = try value.configuration(), raw = try JSONEncoder().encode([old])
        let (archive, passwords, access, _) = try fixture(source: raw)
        let legacyKey = "manager-txn|" + old.id.uuidString
        access.items[legacyKey] = try legacyRecord(old)
        let manager = SiteManager(store: archive, passwords: passwords)
        try await wait { !manager.isRecovering }
        let password = try await manager.password(for: old); XCTAssertNil(password)
        XCTAssertNotNil(access.items[legacyKey])
        var edit = SiteDraft(site: old); edit.name = "new name"
        let saved = await manager.save(edit); XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.privateKeyReference, old.privateKeyReference); XCTAssertNil(access.items[legacyKey])
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: archive.backupURL), raw)
        for file in [archive.url, archive.backupURL] {
            let bytes = try Data(contentsOf: file)
            XCTAssertNil(bytes.range(of: sourceBytes)); XCTAssertNil(bytes.range(of: Data("legacy-secret".utf8)))
        }
    }
    func testSaveAndDeleteArchiveFailureRestoreOldCredentialsAndOtherSite() async throws {
        for deleting in [false, true] {
            let (archive, passwords, access, faults) = try fixture(), old = try draft().configuration(), other = try draft().configuration()
            try archive.save([old, other]); try await passwords.save("old-secret", for: old); try await passwords.save("unrelated-secret", for: other)
            let protected = access.items
            let manager = SiteManager(store: archive, passwords: passwords)
            try await wait { !manager.isRecovering }; XCTAssertTrue(manager.canSave)
            faults.archiveFailures = 1
            if deleting { let result = await manager.delete(old); XCTAssertFalse(result) }
            else {
                var edit = SiteDraft(site: old); edit.name = "new name"; edit.password = "new-secret"
                let result = await manager.save(edit); XCTAssertNil(result)
            }
            XCTAssertEqual(manager.sites, [old, other]); XCTAssertEqual(try archive.load(), [old, other])
            XCTAssertTrue(manager.canSave); XCTAssertNotNil(manager.error); XCTAssertEqual(access.items, protected)
            XCTAssertNil(try archive.loadJournal())
            let password = try await manager.password(for: old); XCTAssertEqual(password, "old-secret")
        }
    }
    func testFailedCompensationBlocksAffectedCredentialsAndExplicitRetryRestores() async throws {
        let (archive, passwords, access, faults) = try fixture(), old = try draft().configuration(), other = try draft().configuration()
        try archive.save([old, other]); try await passwords.save("old-secret", for: old); try await passwords.save("unrelated-secret", for: other)
        let manager = SiteManager(store: archive, passwords: passwords)
        try await wait { !manager.isRecovering }
        faults.archiveFailures = 1; faults.onArchiveFailure = { access.writeStatus = errSecAuthFailed }
        var edit = SiteDraft(site: old); edit.name = "new name"; edit.password = "new-secret"
        let result = await manager.save(edit); XCTAssertNil(result)
        XCTAssertFalse(manager.canSave); XCTAssertTrue(manager.canRetryRecovery)
        XCTAssertFalse(manager.canUseSite(old.id)); XCTAssertTrue(manager.canUseSite(other.id)); XCTAssertTrue(manager.canUseSite(nil))
        XCTAssertTrue(manager.error?.contains("恢复未完成") == true)
        do { _ = try await manager.password(for: old); XCTFail("Affected credential reused") } catch {}
        let unrelated = try await manager.password(for: other); XCTAssertEqual(unrelated, "unrelated-secret")
        XCTAssertNotNil(try archive.loadJournal())
        access.writeStatus = errSecSuccess; faults.onArchiveFailure = nil
        await manager.retryRecovery()
        XCTAssertTrue(manager.canSave); XCTAssertNil(manager.error); XCTAssertEqual(manager.sites, [old, other])
        let restored = try await manager.password(for: old); XCTAssertEqual(restored, "old-secret")
    }
    func testCommittedCleanupFeedbackPublishesNewStateWithoutFullSuccessAndRetryOnlyCleans() async throws {
        let (archive, passwords, _, faults) = try fixture(), old = try draft().configuration()
        try archive.save([old]); try await passwords.save("old-secret", for: old)
        let manager = SiteManager(store: archive, passwords: passwords)
        try await wait { !manager.isRecovering }
        faults.journalRemovalFailure = true
        var edit = SiteDraft(site: old); edit.name = "new name"; edit.password = "new-secret"
        let result = await manager.save(edit); XCTAssertNil(result)
        XCTAssertEqual(manager.sites.first?.name, "new name")
        XCTAssertFalse(manager.canSave); XCTAssertTrue(manager.error?.contains("已提交") == true)
        XCTAssertEqual(try archive.loadJournal()?.phase, .committed)
        faults.journalRemovalFailure = false; await manager.retryRecovery()
        XCTAssertTrue(manager.canSave); XCTAssertEqual(manager.sites.first?.name, "new name")
        let secret = try await manager.password(for: XCTUnwrap(manager.sites.first)); XCTAssertEqual(secret, "new-secret")
        XCTAssertNil(try archive.loadJournal())
    }
    func testNonIdentityEditKeepsPasswordAndConcurrentDeleteIsRejected() async throws {
        let (archive, passwords, _, _) = try fixture(), old = try draft().configuration()
        try archive.save([old]); try await passwords.save("old-secret", for: old)
        let manager = SiteManager(store: archive, passwords: passwords)
        try await wait { !manager.isRecovering }
        var edit = SiteDraft(site: old); edit.name = "new name"
        let saving = Task { await manager.save(edit) }
        let deleting = Task { await manager.delete(old) }
        let saved = await saving.value, deleted = await deleting.value
        XCTAssertNotNil(saved); XCTAssertFalse(deleted)
        let current = try XCTUnwrap(manager.sites.first)
        let secret = try await manager.password(for: current); XCTAssertEqual(secret, "old-secret")
        XCTAssertEqual(current.name, "new name"); XCTAssertEqual(manager.sites.count, 1)
    }
    func testStartupRebuildAtEachPersistentBoundaryRecoversOnlyJournalAuthority() async throws {
        for boundary in ["orphan", "prepared", "credentials", "archive", "committed", "key-cleaned", "journal-cleaned"] {
            let (archive, passwords, _, _) = try fixture(), old = try draft().configuration()
            var next = old; next.name = "new name"
            try archive.save([old]); try await passwords.save("old-secret", for: old)
            let coordinator = SiteTransactionCoordinator(archive: archive, passwords: passwords)
            if boundary == "orphan" {
                let snapshot = try await passwords.capture(id: old.id)
                try await passwords.saveRecovery(snapshot, transactionID: UUID())
            } else {
                let prepared = try await coordinator.prepare(siteID: old.id, newSites: [next], expectedOldSites: [old])
                if boundary != "prepared" {
                    try await passwords.save("new-secret", for: next)
                    if boundary != "credentials" {
                        try archive.save([next])
                        if boundary != "archive" {
                            let committed = try await coordinator.markCommitted(prepared)
                            if boundary == "key-cleaned" || boundary == "journal-cleaned" { try await passwords.removeRecovery(transactionID: committed.id) }
                            if boundary == "journal-cleaned" { try archive.removeJournal(committed) }
                        }
                    }
                }
            }
            let manager = SiteManager(store: archive, passwords: passwords)
            XCTAssertFalse(manager.canSave); XCTAssertFalse(manager.canUseSite(old.id))
            try await wait { !manager.isRecovering }
            XCTAssertTrue(manager.canSave, manager.error ?? "")
            let committed = ["committed", "key-cleaned", "journal-cleaned"].contains(boundary)
            XCTAssertEqual(manager.sites, committed ? [next] : [old])
            let secret = try await manager.password(for: committed ? next : old)
            XCTAssertEqual(secret, committed ? "new-secret" : "old-secret")
            XCTAssertNil(try archive.loadJournal())
            let ids = try await passwords.recoveryIDs(); XCTAssertTrue(ids.isEmpty)
        }
    }
    func testCorruptJournalBlocksSavedUseButManualConnectionWorksAndRecoveryHasNoNetworkRequests() async throws {
        let fixture = try FTPFixture(countOperations: true); defer { fixture.stop() }
        let (archive, passwords, access, _) = try self.fixture(), old = try draft().configuration()
        try archive.save([old]); try await passwords.save("old-secret", for: old)
        let corrupt = Data("invalid journal".utf8); try corrupt.write(to: archive.journalURL)
        let protected = access.items
        let manager = SiteManager(store: archive, passwords: passwords)
        try await wait { !manager.isRecovering }
        XCTAssertFalse(manager.canSave); XCTAssertFalse(manager.canUseSite(old.id))
        let initial = try fixture.operationCounts(); XCTAssertEqual(initial?["connections"], 0)
        await manager.retryRecovery()
        XCTAssertEqual(try Data(contentsOf: archive.journalURL), corrupt); XCTAssertEqual(access.items, protected)
        let after = try fixture.operationCounts(); XCTAssertEqual(after?["connections"], 0)
        let model = AppModel(client: FTPClient(), sites: manager, history: TransferHistory(url: archive.url.appendingPathExtension("history")))
        model.selectSite(old.id); await Task.yield(); XCTAssertFalse(model.canConnect)
        model.selectSite(nil); model.address = "127.0.0.1:\(fixture.info.port)"; model.connect()
        try await wait { model.hasDirectory && !model.isBusy }
        XCTAssertTrue(model.hasDirectory)
        XCTAssertEqual(try Data(contentsOf: archive.journalURL), corrupt)
    }
}

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
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
        XCTAssertTrue(records.allSatisfy { $0["password"] == nil && $0["passphrase"] == nil })
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

    func testKeyConfigurationAndLegacyIdentityDecoding() throws {
        var d = SiteDraft(); d.host = "example.test"; d.transport = .sftp
        d.loginMode = .account; d.username = "member"; d.port = "22"; d.encodingPolicy = .utf8
        let password = try d.configuration()
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(password)) as? [String: Any])
        legacy.removeValue(forKey: "authenticationMethod")
        XCTAssertEqual(try JSONDecoder().decode(FTPSite.self, from: JSONSerialization.data(withJSONObject: legacy)).authenticationMethod, .password)
        d.authenticationMethod = .privateKey
        XCTAssertThrowsError(try d.configuration())
        d.privateKeyReference = PrivateKeyReference(bookmark: Data([1]), name: "id_key", digest: Data([2]))
        d.passphrase = "do-not-save"; d.rememberPassword = true
        let keySite = try d.configuration()
        XCTAssertFalse(keySite.rememberPassword)
        let encoded = try JSONEncoder().encode(keySite)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("do-not-save"))
        XCTAssertEqual(try JSONDecoder().decode(FTPSite.self, from: encoded), keySite)
        d.transport = .ftp; d.port = "21"
        XCTAssertThrowsError(try d.configuration())
        let material = PrivateKeyMaterial(Data("secret-key".utf8))
        let credentials = try FTPCredentials.key(username: "member", material: material, passphrase: "phrase")
        XCTAssertFalse(String(reflecting: credentials).contains("phrase"))
        XCTAssertFalse(String(reflecting: material).contains("secret-key"))
        XCTAssertEqual(credentials.redacting("secret-key phrase"), "[redacted] [redacted]")
        XCTAssertThrowsError(try FTPCredentials.key(username: "member", material: material, passphrase: "nul\0"))
    }

    func testKeyAccessBoundsChangesAndAuthorizationPairing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("key")
        let bytes = Data("-----BEGIN RSA PRIVATE KEY-----\nfixture-one".utf8)
        try bytes.write(to: url)
        var starts = 0; var stops = 0
        let access = PrivateKeyAccess(start: { _ in starts += 1; return true }, stop: { _ in stops += 1 },
                                      create: { _ in Data([1]) }, restore: { _ in (url, false) })
        let selection = try PrivateKeySelection.select(url, access: access)
        let reference = try selection.reference(access: access)
        XCTAssertEqual(try access.resolve(reference.bookmark), url)
        XCTAssertEqual(starts, stops)
        try Data("-----BEGIN RSA PRIVATE KEY-----\nfixture-two".utf8).write(to: url)
        XCTAssertThrowsError(try selection.material(access: access))
        XCTAssertEqual(starts, stops)
        let stale = PrivateKeyAccess(restore: { _ in (url, true) })
        XCTAssertThrowsError(try stale.resolve(Data([1])))
        XCTAssertThrowsError(try PrivateKeyAccess().resolve(Data([0])))
        let failure = PrivateKeyAccess(start: { _ in true }, stop: { _ in stops += 1 }, create: { _ in throw SiteError.storage })
        XCTAssertThrowsError(try failure.bookmark(url))
        for data in [Data(), Data("ssh-rsa public-only".utf8), Data(repeating: 65, count: PrivateKeyAccess.limit + 1)] {
            try data.write(to: url)
            XCTAssertThrowsError(try access.read(url))
        }
        XCTAssertThrowsError(try access.read(root))
        try bytes.write(to: url)
        let denied = PrivateKeyAccess(readBytes: { _, _ in throw POSIXError(.EACCES) })
        do { _ = try denied.read(url); XCTFail("Permission failure accepted") }
        catch { XCTAssertFalse(error.localizedDescription.contains("fixture-one")) }
        let changedDuringRead = PrivateKeyAccess(readBytes: { handle, bound in
            let result = try handle.read(upToCount: bound) ?? Data()
            try Data("replacement".utf8).write(to: url)
            return result
        })
        XCTAssertThrowsError(try changedDuringRead.read(url))
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try access.read(url))
    }

}
