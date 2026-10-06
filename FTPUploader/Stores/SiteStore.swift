import Foundation

protocol SiteStoring {
    func load() throws -> [FTPSite]
    func save(_ sites: [FTPSite]) throws
}

final class SiteStore: SiteStoring {
    static let key = "ftp.savedSites"
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
            defaults.set(data, forKey: Self.key)
        } catch { throw SiteError.storage }
    }
}
