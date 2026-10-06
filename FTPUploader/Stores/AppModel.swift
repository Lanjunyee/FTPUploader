import Combine
import Foundation

enum UploadState: Equatable {
    case idle, uploading, awaitingCompletion, succeeded
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var address = "" {
        didSet {
            if !updatingDraft && address != oldValue {
                if !canEditConnection {
                    updatingDraft = true; address = oldValue; updatingDraft = false
                    return
                }
                clearFieldIssue(for: .address)
                let hadPassword = password != nil
                password = nil
                // Sticky: a later keystroke no longer sees the old password, but the
                // requirement to re-enter one still stands until a password is provided.
                if hadPassword && loginMode == .account { identityChangedNotice = true }
                invalidateConnection()
            }
        }
    }
    @Published var loginMode = FTPLoginMode.anonymous {
        didSet {
            if !updatingDraft && loginMode != oldValue {
                if !canEditConnection {
                    updatingDraft = true; loginMode = oldValue; updatingDraft = false
                    return
                }
                clearFieldIssue(for: .password)
                let hadPassword = password != nil
                password = nil
                identityChangedNotice = hadPassword && loginMode == .account
                invalidateConnection()
            }
        }
    }
    @Published var username = "" {
        didSet {
            if !updatingDraft && username != oldValue {
                if !canEditConnection {
                    updatingDraft = true; username = oldValue; updatingDraft = false
                    return
                }
                clearFieldIssue(for: .username)
                let hadPassword = password != nil
                password = nil
                if hadPassword && loginMode == .account { identityChangedNotice = true }
                invalidateConnection()
            }
        }
    }
    @Published var password: String? {
        didSet {
            if !updatingDraft && password != oldValue {
                if !canEditConnection {
                    updatingDraft = true; password = oldValue; updatingDraft = false
                    return
                }
                clearFieldIssue(for: .password)
                if password != nil { identityChangedNotice = false }
                invalidateConnection()
            }
        }
    }
    @Published private(set) var selectedSiteID: UUID?
    @Published private(set) var credentialError: String?
    /// The first local input failure of the last submit, kept apart from
    /// `directoryError` so a field problem never reads as a connection failure.
    @Published private(set) var fieldIssue: FieldIssue?
    /// Bumped only when a field issue is raised, so a view can move focus to the
    /// first invalid field without losing focus when the issue is cleared by typing.
    @Published private(set) var fieldIssueTicket = 0
    /// Set when an identity change made a previously supplied (or loaded) password
    /// unusable, so the password area can explain the requirement.
    @Published private(set) var identityChangedNotice = false
    @Published private(set) var isPasswordLoading = false
    @Published private(set) var isSiteOperationBusy = false
    let sites: SiteManager
    @Published private(set) var endpoint: FTPEndpoint?
    @Published private(set) var path = RemotePath.root
    @Published private(set) var entries: [RemoteEntry] = []
    @Published private(set) var isDirectoryLoading = false
    @Published private(set) var hasDirectory = false
    @Published private(set) var directoryError: String?
    @Published private(set) var selectedFile: SelectedLocalFile?
    @Published private(set) var selectionError: String?
    @Published private(set) var uploadState = UploadState.idle
    @Published private(set) var uploadTarget: String?
    @Published private(set) var sent: Int64 = 0
    @Published private(set) var total: Int64 = 0

    private let client: FTPServing
    private var encoding = FTPTextEncoding.utf8
    private var directoryRequestID = 0
    private var uploadRequestID = 0
    private var draftVersion = 0
    private var updatingDraft = false
    private var activeCredentials: FTPCredentials?

    init(client: FTPServing = FTPClient(), sites: SiteManager? = nil) {
        self.client = client; self.sites = sites ?? SiteManager()
    }

    var isUploading: Bool { uploadState == .uploading || uploadState == .awaitingCompletion }
    var isBusy: Bool { isDirectoryLoading || isUploading || isSiteOperationBusy }
    var canEditConnection: Bool { !isUploading && !isSiteOperationBusy }
    var canConnect: Bool {
        canEditConnection && !isPasswordLoading && !isDirectoryLoading
            && !address.trimmingCharacters(in: .whitespaces).isEmpty
    }
    var connectionIdentity: String {
        guard let credentials = activeCredentials else { return "FTP" }
        return credentials.mode == .anonymous ? "FTP · 匿名访问" : "FTP · 账户：\(credentials.username)"
    }
    var canChooseFile: Bool { hasDirectory && !isBusy }
    var canUpload: Bool { canChooseFile && selectedFile != nil }
    var currentLocation: String {
        guard let endpoint else { return "尚未连接" }
        return endpoint.display + path.display
    }
    var pendingTarget: String? {
        guard hasDirectory, let file = selectedFile else { return nil }
        return currentLocation + (path.components.isEmpty ? "" : "/") + file.name
    }

    func connect() {
        guard canConnect else { return }
        // Validate before touching the live connection: a local input failure must
        // keep the current directory and must not present itself as a network error.
        let next: FTPEndpoint
        let credentials: FTPCredentials
        do {
            next = try FTPEndpoint(address: address)
            credentials = loginMode == .anonymous ? .anonymous : try .account(username: username, password: password)
        } catch let issue as FieldIssue {
            setFieldIssue(issue)
            return
        } catch {
            setFieldIssue(nil)
            directoryError = error.localizedDescription
            return
        }
        setFieldIssue(nil)
        invalidateConnection()
        let initialEncoding: FTPTextEncoding? = next.initialPath.components.contains {
            String(data: $0.bytes, encoding: .utf8) == nil
        } ? .gb18030 : nil
        requestDirectory(endpoint: next, path: next.initialPath, preferredEncoding: initialEncoding, credentials: credentials)
    }

    /// Reconnect from the path popover. The draft address is validated before it is
    /// applied, so an invalid draft keeps the old directory, the popover and the draft.
    /// Returns `true` only when the connection request was actually started.
    @discardableResult
    func reconnect(to draftAddress: String) -> Bool {
        guard canEditConnection, !isDirectoryLoading else { return false }
        do { _ = try FTPEndpoint(address: draftAddress) }
        catch let issue as FieldIssue {
            setFieldIssue(issue)
            return false
        } catch {
            setFieldIssue(nil)
            directoryError = error.localizedDescription
            return false
        }
        address = draftAddress
        connect()
        return true
    }

    private func clearFieldIssue(for field: FTPFormField) {
        if fieldIssue?.field == field { setFieldIssue(nil) }
    }

    private func setFieldIssue(_ issue: FieldIssue?) {
        fieldIssue = issue
        if issue != nil { fieldIssueTicket += 1 }
    }

    /// Drops a field reason left over from a dismissed form (for example the path popover).
    func dismissFieldIssue() {
        setFieldIssue(nil)
    }

    private func invalidateConnection() {
        draftVersion += 1
        directoryRequestID += 1
        endpoint = nil
        path = .root
        entries = []
        hasDirectory = false
        isDirectoryLoading = false
        directoryError = nil
        setFieldIssue(nil)
        credentialError = nil
        isPasswordLoading = false
        activeCredentials = nil
        clearFile()
        resetUpload()
    }

    func selectSite(_ id: UUID?) {
        guard canEditConnection else { return }
        invalidateConnection()
        identityChangedNotice = false
        selectedSiteID = id
        updatingDraft = true
        defer { updatingDraft = false }
        if let site = sites.sites.first(where: { $0.id == id }) {
            address = site.address; loginMode = site.loginMode; username = site.username; password = nil
            if site.rememberPassword { loadPassword(site) }
        } else { address = ""; loginMode = .anonymous; username = ""; password = nil }
    }

    private func loadPassword(_ site: FTPSite) {
        let version = draftVersion
        isPasswordLoading = true
        Task {
            do {
                let saved = try await sites.passwords.password(for: site)
                guard version == draftVersion, selectedSiteID == site.id else { return }
                updatingDraft = true; password = saved; updatingDraft = false
                identityChangedNotice = false
                isPasswordLoading = false
                if saved == nil { credentialError = "此站点没有可用的保存密码，请重新输入。" }
            } catch {
                guard version == draftVersion, selectedSiteID == site.id else { return }
                isPasswordLoading = false
                credentialError = error.localizedDescription
            }
        }
    }

    func siteDraft() -> SiteDraft {
        var draft = selectedSiteID.flatMap { id in sites.sites.first { $0.id == id } }.map(SiteDraft.init) ?? SiteDraft()
        if let endpoint = try? FTPEndpoint(address: address) {
            draft.host = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
            draft.port = String(endpoint.port); draft.initialDirectory = endpoint.initialPath.encodedDirectory
        }
        draft.loginMode = loginMode; draft.username = username; draft.password = password
        return draft
    }

    func saveSite(_ draft: SiteDraft) async -> Bool {
        guard canEditConnection else { return false }
        isSiteOperationBusy = true
        defer { isSiteOperationBusy = false }
        guard let saved = await sites.save(draft) else { return false }
        isSiteOperationBusy = false
        if selectedSiteID == nil || selectedSiteID == saved.id {
            selectSite(saved.id)
            if saved.loginMode == .account, let supplied = draft.password {
                invalidateConnection() // Ignore the asynchronous read after supplying this known password.
                updatingDraft = true; password = supplied; updatingDraft = false
                identityChangedNotice = false
            }
        }
        return true
    }

    func deleteSite(_ site: FTPSite) async -> Bool {
        guard canEditConnection else { return false }
        isSiteOperationBusy = true
        defer { isSiteOperationBusy = false }
        guard await sites.delete(site) else { return false }
        isSiteOperationBusy = false
        if selectedSiteID == site.id { selectSite(nil) }
        return true
    }

    func enter(_ entry: RemoteEntry) {
        guard hasDirectory, !isBusy, entry.isDirectory, let endpoint, let credentials = activeCredentials else { return }
        do {
            let next = try path.appending(name: entry.name, bytes: entry.rawName)
            requestDirectory(endpoint: endpoint, path: next, preferredEncoding: encoding, credentials: credentials)
        } catch { directoryError = error.localizedDescription }
    }

    func goUp() {
        guard hasDirectory, !isBusy, let parent = path.parent, let endpoint, let credentials = activeCredentials else { return }
        requestDirectory(endpoint: endpoint, path: parent, preferredEncoding: encoding, credentials: credentials)
    }

    func refresh() {
        guard !isBusy, let endpoint, let credentials = activeCredentials else { return }
        requestDirectory(endpoint: endpoint, path: path, preferredEncoding: encoding, credentials: credentials)
    }

    private func requestDirectory(endpoint requestedEndpoint: FTPEndpoint, path requestedPath: RemotePath,
                                  preferredEncoding: FTPTextEncoding?, credentials: FTPCredentials) {
        directoryRequestID += 1
        let id = directoryRequestID
        isDirectoryLoading = true
        directoryError = nil
        Task {
            do {
                let listing = try await client.list(endpoint: requestedEndpoint, path: requestedPath, encoding: preferredEncoding, credentials: credentials)
                guard id == directoryRequestID else { return }
                endpoint = requestedEndpoint
                activeCredentials = credentials
                path = requestedPath
                entries = listing.entries
                encoding = listing.encoding
                hasDirectory = true
                isDirectoryLoading = false
            } catch {
                guard id == directoryRequestID else { return }
                isDirectoryLoading = false
                directoryError = credentials.redacting(error.localizedDescription)
            }
        }
    }

    func selectFile(_ url: URL) {
        guard canChooseFile else { return }
        selectionError = nil
        do {
            let file = try SelectedLocalFile(url: url)
            clearFile()
            selectedFile = file
            resetUpload()
        } catch {
            clearFile()
            selectionError = error.localizedDescription
        }
    }

    func fileSelectionFailed(_ error: Error) {
        guard (error as NSError).code != NSUserCancelledError else { return }
        selectionError = error.localizedDescription
    }

    func upload() {
        guard canUpload, let endpoint, let file = selectedFile, let credentials = activeCredentials else { return }
        let targetPath = path
        let targetEncoding = encoding
        uploadTarget = pendingTarget
        sent = 0
        total = file.size
        do {
            try file.beginAccessAndValidate()
            _ = try endpoint.fileURL(targetPath, name: file.name, encoding: targetEncoding)
        } catch {
            file.endAccess()
            uploadState = .failed(error.localizedDescription)
            return
        }
        total = file.size
        uploadRequestID += 1
        let id = uploadRequestID
        uploadState = .uploading
        Task { [self, file] in
            defer { file.endAccess() }
            do {
                try await client.upload(endpoint: endpoint, path: targetPath, file: file.url, encoding: targetEncoding, credentials: credentials) { [weak self] sent, total in
                    Task { @MainActor [weak self] in
                        guard let self, self.uploadRequestID == id, self.isUploading else { return }
                        let nextSent = max(0, sent)
                        let nextTotal = max(0, total)
                        let nextState: UploadState = total == 0 || sent >= total ? .awaitingCompletion : .uploading
                        guard self.sent != nextSent || self.total != nextTotal || self.uploadState != nextState else { return }
                        self.sent = nextSent
                        self.total = nextTotal
                        self.uploadState = nextState
                    }
                }
                guard id == uploadRequestID else { return }
                sent = total
                uploadState = .succeeded
                refresh()
            } catch {
                guard id == uploadRequestID else { return }
                uploadState = .failed(credentials.redacting(error.localizedDescription))
            }
        }
    }

    private func clearFile() {
        selectedFile?.endAccess()
        selectedFile = nil
        selectionError = nil
    }

    private func resetUpload() {
        uploadState = .idle
        uploadTarget = nil
        sent = 0
        total = 0
    }
}
