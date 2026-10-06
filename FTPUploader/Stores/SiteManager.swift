import Combine
import Foundation

@MainActor
final class SiteManager: ObservableObject {
    @Published private(set) var sites: [FTPSite] = []
    @Published private(set) var error: String?
    /// The field a local save validation failed on, so the editor can focus it.
    @Published private(set) var fieldIssue: FieldIssue?
    @Published private(set) var isSaving = false
    @Published private(set) var canSave = false
    private let store: SiteStoring
    let passwords: PasswordStoring

    init(store: SiteStoring = SiteStore(), passwords: PasswordStoring = PasswordStore()) {
        self.store = store; self.passwords = passwords
        do { sites = try store.load(); canSave = true }
        catch { self.error = error.localizedDescription }
    }

    func clearEditingError() {
        guard canSave, !isSaving else { return }
        error = nil
        fieldIssue = nil
    }

    func save(_ draft: SiteDraft) async -> FTPSite? {
        guard canSave, !isSaving else { return nil }
        isSaving = true; error = nil; fieldIssue = nil
        defer { isSaving = false }
        do {
            let next = try draft.configuration()
            let previous = sites.first { $0.id == next.id }
            if next.rememberPassword {
                let password: String?
                if let supplied = draft.password { password = supplied }
                else if previous?.identity == next.identity, previous?.rememberPassword == true {
                    password = try await passwords.password(for: next)
                } else { password = nil }
                guard let password else { throw FieldIssue(field: .password, message: "请输入该站点的密码后再保存。") }
                try await passwords.save(password, for: next)
            } else if previous != nil {
                try await passwords.remove(id: next.id)
            }
            var updated = sites
            if let index = updated.firstIndex(where: { $0.id == next.id }) { updated[index] = next }
            else { updated.append(next) }
            try store.save(updated)
            sites = updated
            return next
        } catch {
            if let issue = error as? FieldIssue { fieldIssue = issue }
            self.error = error.localizedDescription
            return nil
        }
    }

    func delete(_ site: FTPSite) async -> Bool {
        guard canSave, !isSaving else { return false }
        isSaving = true; error = nil
        defer { isSaving = false }
        do {
            try await passwords.remove(id: site.id)
            let updated = sites.filter { $0.id != site.id }
            try store.save(updated)
            sites = updated
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
