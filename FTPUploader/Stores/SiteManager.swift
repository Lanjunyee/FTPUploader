import Combine
import Foundation

/// Serial recovery state machine. No network boundary or mutable form enters this type.
@MainActor
final class SiteTransactionCoordinator {
    enum State: Equatable { case idle, prepared, recoveryPending, committedCleanupPending }
    private(set) var state: State = .idle
    private(set) var isBusy = false
    private(set) var affectedSiteID: UUID?
    let archive: SiteArchiveStore
    let passwords: PasswordStore

    init(archive: SiteArchiveStore, passwords: PasswordStore) { self.archive = archive; self.passwords = passwords }

    private func perform<T>(_ work: () async throws -> T) async throws -> T {
        guard !isBusy else { throw SiteError.credentials("站点事务正在处理，请稍后再试。") }
        isBusy = true; defer { isBusy = false }
        do { return try await work() }
        catch {
            let journal = try? archive.loadJournal()
            affectedSiteID = journal?.siteID
            state = journal?.phase == .committed ? .committedCleanupPending : .recoveryPending
            throw error
        }
    }
    private func require(_ expected: SiteTransactionJournal) throws {
        guard try archive.loadJournal() == expected else { throw SiteError.storage }
    }
    private func requireKnownConfiguration(_ journal: SiteTransactionJournal) throws {
        let sites = try archive.load()
        guard sites == journal.oldSites || sites == journal.newSites else { throw SiteError.storage }
    }
    private func requireRecovery(_ journal: SiteTransactionJournal) async throws -> PasswordStore.Snapshot? {
        let snapshot = try await passwords.loadRecovery(transactionID: journal.id, siteID: journal.siteID)
        if let snapshot {
            guard snapshot.hasLegacy == journal.oldLegacyCredentialExists,
                  snapshot.hasCurrent == journal.oldCredentialExists else { throw SiteError.storage }
        } else if journal.oldCredentialExists || journal.oldLegacyCredentialExists {
            throw SiteError.credentials("未提交事务缺少必要的旧凭据恢复材料，已阻止该站点操作。")
        }
        return snapshot
    }
    private func cleanOrphans(keeping activeID: UUID?) async throws {
        let ids = try await passwords.recoveryIDs()
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) where id != activeID {
            // No journal means no authority to restore configurations or credentials.
            try await passwords.removeRecovery(transactionID: id)
        }
    }
    func prepare(siteID: UUID, newSites: [FTPSite], expectedOldSites: [FTPSite]) async throws -> SiteTransactionJournal {
        try await perform {
            guard try archive.loadJournal() == nil else { throw SiteError.storage }
            let old = try archive.load()
            guard old == expectedOldSites else { throw SiteError.storage }
            let hadArchive = archive.archiveExists
            try await cleanOrphans(keeping: nil)
            let snapshot = try await passwords.capture(id: siteID)
            let journal = SiteTransactionJournal(siteID: siteID, oldSites: old, newSites: newSites,
                oldArchiveExists: hadArchive, oldLegacyCredentialExists: snapshot.hasLegacy,
                oldCredentialExists: snapshot.hasCurrent,
                newCredentialExists: newSites.first(where: { $0.id == siteID })?.rememberPassword == true)
            try journal.validate(); try archive.preserveLegacyBackup()
            try await passwords.saveRecovery(snapshot, transactionID: journal.id)
            guard try await passwords.loadRecovery(transactionID: journal.id, siteID: siteID) == snapshot,
                  try archive.load() == old, archive.archiveExists == hadArchive else { throw SiteError.storage }
            // All necessary recovery bytes are saved and verified before prepared is visible.
            try archive.saveJournal(journal)
            affectedSiteID = siteID; state = .prepared
            return journal
        }
    }
    func markCommitted(_ prepared: SiteTransactionJournal) async throws -> SiteTransactionJournal {
        try await perform {
            guard prepared.phase == .prepared else { throw SiteError.storage }
            try require(prepared)
            guard try archive.load() == prepared.newSites, archive.archiveExists else { throw SiteError.storage }
            _ = try await requireRecovery(prepared)
            try await passwords.verifyCommittedCredentials(siteID: prepared.siteID,
                site: prepared.newSites.first(where: { $0.id == prepared.siteID }), exists: prepared.newCredentialExists)
            try require(prepared)
            guard try archive.load() == prepared.newSites, archive.archiveExists else { throw SiteError.storage }
            var committed = prepared; committed.phase = .committed
            try archive.saveJournal(committed, replacing: prepared)
            state = .committedCleanupPending; affectedSiteID = prepared.siteID
            return committed
        }
    }
    private func finishCommitted(_ journal: SiteTransactionJournal) async throws {
        guard journal.phase == .committed else { throw SiteError.storage }
        try require(journal)
        guard try archive.load() == journal.newSites, archive.archiveExists else { throw SiteError.storage }
        try await passwords.verifyCommittedCredentials(siteID: journal.siteID,
            site: journal.newSites.first(where: { $0.id == journal.siteID }), exists: journal.newCredentialExists)
        try require(journal)
        // committed is authoritative even when the recovery item was already removed.
        try await passwords.removeRecovery(transactionID: journal.id)
        try require(journal)
        guard try archive.load() == journal.newSites else { throw SiteError.storage }
        try archive.removeJournal(journal)
    }
    func finish(_ committed: SiteTransactionJournal) async throws {
        try await perform {
            try await finishCommitted(committed)
            try await cleanOrphans(keeping: nil)
            state = .idle; affectedSiteID = nil
        }
    }
    /// Reconstruct from disk and Keychain only; never trust this instance's prior state.
    func recover() async throws -> [FTPSite] {
        try await perform {
            let journal = try archive.loadJournal()
            _ = try archive.load() // Corrupt configuration must not drive any cleanup/update.
            if let journal {
                affectedSiteID = journal.siteID
                try requireKnownConfiguration(journal)
                if journal.phase == .committed { try await finishCommitted(journal) }
                else {
                    let snapshot = try await requireRecovery(journal)
                    try require(journal); try archive.validateRollback(journal)
                    if let snapshot { try await passwords.restore(snapshot, id: journal.siteID) }
                    else {
                        // The journal proves both old slots were absent; no old secret is needed.
                        try await passwords.remove(id: journal.siteID)
                        let absent = try await passwords.capture(id: journal.siteID)
                        guard !absent.hasLegacy, !absent.hasCurrent else { throw SiteError.storage }
                    }
                    try require(journal)
                    try archive.restoreArchive(journal)
                    // Rollback is fully verified. Remove prepared authority first, leaving at
                    // worst an orphan that can only be cleaned (never replay a mutation).
                    try archive.removeJournal(journal)
                    try await passwords.removeRecovery(transactionID: journal.id)
                }
            }
            try await cleanOrphans(keeping: nil)
            let sites = try archive.load()
            state = .idle; affectedSiteID = nil
            return sites
        }
    }
}

@MainActor
final class SiteManager: ObservableObject {
    @Published private(set) var sites: [FTPSite] = []
    @Published private(set) var error: String?
    /// The field a local save validation failed on, so the editor can focus it.
    @Published private(set) var fieldIssue: FieldIssue?
    @Published private(set) var isSaving = false
    @Published private(set) var canSave = false
    @Published private(set) var isRecovering = false
    private let store: SiteStoring
    private let passwords: PasswordStoring
    private let transactions: SiteTransactionCoordinator?
    private var credentialRevision = 0
    var canRetryRecovery: Bool { transactions != nil && !canSave && !isRecovering && !isSaving }

    init(store: SiteStoring = SiteArchiveStore(), passwords: PasswordStoring = PasswordStore()) {
        self.store = store; self.passwords = passwords
        if let archive = store as? SiteArchiveStore, let concrete = passwords as? PasswordStore {
            transactions = SiteTransactionCoordinator(archive: archive, passwords: concrete)
            do { sites = try archive.load() } catch { self.error = error.localizedDescription }
            isRecovering = true
            Task { await retryRecovery() }
        } else {
            transactions = nil
            if store is SiteArchiveStore { error = "此凭据后端不支持站点事务恢复，已阻止站点修改。" }
            else {
                // Injectable legacy/in-memory boundaries retain their existing test behavior.
                do { sites = try store.load(); canSave = true }
                catch { self.error = error.localizedDescription }
            }
        }
    }
    func canUseSite(_ id: UUID?) -> Bool {
        guard id != nil else { return true } // Independent manually entered connections remain available.
        guard !isRecovering, !isSaving else { return false }
        guard let transactions else { return canSave }
        if transactions.state == .idle { return canSave }
        // A corrupt/unidentifiable transaction blocks all saved credential reuse.
        return transactions.affectedSiteID != nil && transactions.affectedSiteID != id
    }
    func password(for site: FTPSite) async throws -> String? {
        guard canUseSite(site.id), sites.contains(site) else { throw SiteError.credentials("该站点恢复未完成，不能读取保存凭据；可使用独立手动连接。") }
        let revision = credentialRevision
        let result: String?
        if let transactions { result = try await transactions.passwords.readOnlyPassword(for: site) }
        else { result = try await passwords.password(for: site) }
        guard revision == credentialRevision, canUseSite(site.id), sites.contains(site) else { throw SiteError.credentials("站点状态已变化，未复用迟到凭据。") }
        return result
    }
    func retryRecovery() async {
        guard let transactions, !transactions.isBusy, !isSaving else { return }
        credentialRevision &+= 1
        isRecovering = true; canSave = false
        defer { isRecovering = false }
        do {
            sites = try await transactions.recover()
            canSave = true; error = nil; fieldIssue = nil
        } catch {
            if let known = try? store.load() { sites = known }
            self.error = recoveryMessage(error)
        }
    }
    private func recoveryMessage(_ error: Error) -> String {
        let prefix = transactions?.state == .committedCleanupPending
            ? "站点更新已提交，恢复材料清理未完成。请重试清理，不会撤销新状态。"
            : "站点恢复未完成，已阻止相关凭据读取及站点修改。请重试恢复，或使用独立手动连接。"
        return prefix + " " + error.localizedDescription
    }
    private func transact(siteID: UUID, newSites: [FTPSite], password: String?) async throws {
        guard let transactions else { throw SiteError.storage }
        do {
            let prepared = try await transactions.prepare(siteID: siteID, newSites: newSites, expectedOldSites: sites)
            if let next = newSites.first(where: { $0.id == siteID }), next.rememberPassword {
                guard let password else { throw SiteError.storage }
                try await transactions.passwords.save(password, for: next)
            } else { try await transactions.passwords.remove(id: siteID) }
            try transactions.archive.save(newSites)
            let committed = try await transactions.markCommitted(prepared)
            sites = newSites
            try await transactions.finish(committed)
        } catch {
            let originalFailure = error
            let journal = try? transactions.archive.loadJournal()
            if journal?.phase == .committed {
                if let known = try? store.load() { sites = known }
                canSave = false
                throw SiteError.credentials(recoveryMessage(error))
            }
            do { sites = try await transactions.recover(); canSave = true }
            catch {
                canSave = false
                throw SiteError.credentials(recoveryMessage(error) + " 原更新错误：" + originalFailure.localizedDescription)
            }
            throw originalFailure
        }
    }

    func clearEditingError() {
        guard canSave, !isSaving else { return }
        error = nil
        fieldIssue = nil
    }

    func save(_ draft: SiteDraft) async -> FTPSite? {
        guard canSave, !isSaving else { return nil }
        credentialRevision &+= 1
        isSaving = true; error = nil; fieldIssue = nil
        defer { isSaving = false }
        do {
            let next = try draft.configuration()
            let previous = sites.first { $0.id == next.id }
            let preservedPassword: String?
            if next.rememberPassword {
                if let supplied = draft.password { preservedPassword = supplied }
                else if previous?.identity == next.identity, previous?.rememberPassword == true {
                    if let transactions { preservedPassword = try await transactions.passwords.readOnlyPassword(for: next) }
                    else { preservedPassword = try await passwords.password(for: next) }
                } else { preservedPassword = nil }
                guard preservedPassword != nil else { throw FieldIssue(field: .password, message: "请输入该站点的密码后再保存。") }
            } else { preservedPassword = nil }
            var updated = sites
            if let index = updated.firstIndex(where: { $0.id == next.id }) { updated[index] = next }
            else { updated.append(next) }
            if transactions != nil { try await transact(siteID: next.id, newSites: updated, password: preservedPassword) }
            else {
                if let preservedPassword { try await passwords.save(preservedPassword, for: next) }
                else if previous != nil { try await passwords.remove(id: next.id) }
                try store.save(updated); sites = updated
            }
            return next
        } catch {
            if let issue = error as? FieldIssue { fieldIssue = issue }
            self.error = error.localizedDescription
            return nil
        }
    }

    func delete(_ site: FTPSite) async -> Bool {
        guard canSave, !isSaving, sites.contains(site) else { return false }
        credentialRevision &+= 1
        isSaving = true; error = nil
        defer { isSaving = false }
        do {
            let updated = sites.filter { $0.id != site.id }
            if transactions != nil { try await transact(siteID: site.id, newSites: updated, password: nil) }
            else { try await passwords.remove(id: site.id); try store.save(updated); sites = updated }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
