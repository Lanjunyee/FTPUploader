import Foundation

protocol SiteStoring {
    func load() throws -> [FTPSite]
    func save(_ sites: [FTPSite]) throws
}

/// Non-secret transaction metadata. Password recovery bytes belong only in Keychain.
struct SiteTransactionJournal: Codable, Equatable {
    enum Phase: String, Codable { case prepared, committed }
    let version: Int
    let id: UUID
    let siteID: UUID
    let oldSites: [FTPSite]
    let newSites: [FTPSite]
    let oldArchiveExists: Bool
    let oldLegacyCredentialExists: Bool
    let oldCredentialExists: Bool
    let newCredentialExists: Bool
    var phase: Phase

    init(id: UUID = UUID(), siteID: UUID, oldSites: [FTPSite], newSites: [FTPSite], oldArchiveExists: Bool,
         oldLegacyCredentialExists: Bool, oldCredentialExists: Bool, newCredentialExists: Bool, phase: Phase = .prepared) {
        version = 1; self.id = id; self.siteID = siteID; self.oldSites = oldSites; self.newSites = newSites
        self.oldArchiveExists = oldArchiveExists; self.oldLegacyCredentialExists = oldLegacyCredentialExists
        self.oldCredentialExists = oldCredentialExists; self.newCredentialExists = newCredentialExists; self.phase = phase
    }
    func validate() throws {
        guard version == 1 else { throw SiteError.storage }
        try SiteArchiveStore.validate(oldSites); try SiteArchiveStore.validate(newSites)
        guard oldSites.contains(where: { $0.id == siteID }) || newSites.contains(where: { $0.id == siteID }),
              oldSites.filter({ $0.id != siteID }) == newSites.filter({ $0.id != siteID }) else { throw SiteError.storage }
        if newCredentialExists {
            guard let next = newSites.first(where: { $0.id == siteID }), next.rememberPassword,
                  next.authenticationMethod == .password else { throw SiteError.storage }
        }
    }
}

/// Versioned atomic archive and journal boundary. The transaction coordinator will own
/// mutation order; creating this boundary does not implicitly migrate or edit Keychain.
final class SiteArchiveStore: SiteStoring {
    private struct Archive: Codable, Equatable { let version: Int; let sites: [FTPSite] }
    let url: URL
    var journalURL: URL { url.appendingPathExtension("journal") }
    var backupURL: URL { url.appendingPathExtension("defaults-backup") }
    private let defaults: UserDefaults
    private let writer: (Data, URL) throws -> Void
    private let backupWriter: (Data, URL) throws -> Void
    private let remover: (URL) throws -> Void
    var archiveExists: Bool { loaded && loadedData != nil }
    private var loaded = false
    private var loadedData: Data?

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FTPUploader/sites.json"), defaults: UserDefaults = .standard,
        writer: @escaping (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .atomic) },
        backupWriter: @escaping (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .withoutOverwriting) },
        remover: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.url = url; self.defaults = defaults; self.writer = writer; self.backupWriter = backupWriter; self.remover = remover
    }
    static func validate(_ sites: [FTPSite]) throws {
        guard Set(sites.map(\.id)).count == sites.count else { throw SiteError.storage }
        try sites.forEach { try $0.validate() }
    }
    private func data(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
    private func directory() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    func load() throws -> [FTPSite] {
        loaded = false
        do {
            let original = try data(at: url)
            let sites: [FTPSite]
            if let original {
                let archive = try JSONDecoder().decode(Archive.self, from: original)
                guard archive.version == 2 else { throw SiteError.storage }
                try Self.validate(archive.sites); sites = archive.sites
            } else { sites = try SiteStore(defaults: defaults).load() }
            loadedData = original; loaded = true; return sites
        } catch { throw SiteError.storage }
    }
    /// Preserve the exact original defaults bytes, including legacy omitted fields.
    /// Existing backup mismatches fail closed; neither defaults key is overwritten.
    func preserveLegacyBackup() throws {
        guard let value = defaults.object(forKey: SiteStore.key) else { return }
        guard let source = value as? Data else { throw SiteError.storage }
        _ = try SiteStore(defaults: defaults).load()
        try directory()
        if let existing = try data(at: backupURL) {
            guard existing == source else { throw SiteError.storage }
        } else { try backupWriter(source, backupURL) }
        guard try data(at: backupURL) == source else { throw SiteError.storage }
    }
    func save(_ sites: [FTPSite]) throws {
        guard loaded else { throw SiteError.storage }
        do {
            try Self.validate(sites)
            guard try data(at: url) == loadedData else { throw SiteError.storage }
            try preserveLegacyBackup(); try directory()
            let bytes = try JSONEncoder().encode(Archive(version: 2, sites: sites))
            try writer(bytes, url)
            guard try data(at: url) == bytes else { throw SiteError.storage }
            loadedData = bytes
        } catch { throw SiteError.storage }
    }
    /// Restore only a known old/new state, never overwrite an unknown archive or defaults.
    func validateRollback(_ journal: SiteTransactionJournal) throws {
        let current = try load()
        guard current == journal.oldSites || current == journal.newSites else { throw SiteError.storage }
        if !journal.oldArchiveExists {
            guard try SiteStore(defaults: defaults).load() == journal.oldSites else { throw SiteError.storage }
        }
    }
    func restoreArchive(_ journal: SiteTransactionJournal) throws {
        try validateRollback(journal)
        if journal.oldArchiveExists { try save(journal.oldSites) }
        else {
            guard try data(at: url) == loadedData else { throw SiteError.storage }
            if loadedData != nil { try remover(url) }
            loadedData = nil
        }
        guard try load() == journal.oldSites, archiveExists == journal.oldArchiveExists else { throw SiteError.storage }
    }
    func loadJournal() throws -> SiteTransactionJournal? {
        do {
            guard let bytes = try data(at: journalURL) else { return nil }
            let journal = try JSONDecoder().decode(SiteTransactionJournal.self, from: bytes)
            try journal.validate(); return journal
        } catch { throw SiteError.storage }
    }
    func saveJournal(_ journal: SiteTransactionJournal, replacing expected: SiteTransactionJournal? = nil) throws {
        do {
            try journal.validate()
            guard try loadJournal() == expected, expected == nil || expected?.id == journal.id else { throw SiteError.storage }
            try directory()
            let bytes = try JSONEncoder().encode(journal)
            try writer(bytes, journalURL)
            guard try data(at: journalURL) == bytes else { throw SiteError.storage }
        } catch { throw SiteError.storage }
    }
    func removeJournal(_ expected: SiteTransactionJournal) throws {
        do {
            guard let current = try loadJournal() else { return }
            guard current == expected else { throw SiteError.storage }
            try remover(journalURL)
            guard try data(at: journalURL) == nil else { throw SiteError.storage }
        } catch { throw SiteError.storage }
    }
}

final class SiteStore: SiteStoring {
    static let key = "ftp.savedSites"
    static let legacyBackupKey = "ftp.savedSites.beforeSecureProtocols"
    private let defaults: UserDefaults
    private var loadSucceeded = false

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() throws -> [FTPSite] {
        do {
            guard let value = defaults.object(forKey: Self.key) else {
                loadSucceeded = true
                return []
            }
            guard let data = value as? Data else { throw SiteError.storage }
            let sites = try JSONDecoder().decode([FTPSite].self, from: data)
            guard Set(sites.map(\.id)).count == sites.count else { throw SiteError.storage }
            try sites.forEach { try $0.validate() }
            loadSucceeded = true
            return sites
        } catch { loadSucceeded = false; throw SiteError.storage }
    }

    func save(_ sites: [FTPSite]) throws {
        guard loadSucceeded else { throw SiteError.storage }
        do {
            guard Set(sites.map(\.id)).count == sites.count else { throw SiteError.storage }
            try sites.forEach { try $0.validate() }
            let data = try JSONEncoder().encode(sites)
            if defaults.object(forKey: Self.legacyBackupKey) == nil,
               let source = defaults.data(forKey: Self.key),
               let records = try JSONSerialization.jsonObject(with: source) as? [[String: Any]],
               records.contains(where: { $0["transport"] == nil }) {
                defaults.set(source, forKey: Self.legacyBackupKey)
                guard defaults.data(forKey: Self.legacyBackupKey) == source else { throw SiteError.storage }
            }
            defaults.set(data, forKey: Self.key)
            guard defaults.data(forKey: Self.key) == data else { throw SiteError.storage }
        } catch { throw SiteError.storage }
    }
}
