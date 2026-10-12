import Combine
import Foundation

enum UploadState: Equatable {
    case idle, checkingTarget, awaitingOverwrite, uploading, awaitingCompletion, cancelling, cancelled, succeeded
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var transport = FileTransport.ftp {
        didSet {
            guard !updatingDraft, transport != oldValue else { return }
            guard canEditConnection else {
                updatingDraft = true; transport = oldValue; updatingDraft = false; return
            }
            clearPrivateKeyPhrase()
            let hadPassword = password != nil
            updatingDraft = true
            password = nil
            if transport == .sftp { loginMode = .account; encodingPolicy = .utf8 }
            else { authenticationMethod = .password; privateKeySelection = nil; privateKeyReference = nil }
            updatingDraft = false
            identityChangedNotice = hadPassword
            invalidateConnection()
        }
    }
    @Published var address = "" {
        didSet {
            if !updatingDraft && address != oldValue {
                if !canEditConnection {
                    updatingDraft = true; address = oldValue; updatingDraft = false
                    return
                }
                clearFieldIssue(for: .address)
                clearPrivateKeyPhrase()
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
                if transport == .sftp && loginMode == .anonymous {
                    updatingDraft = true; loginMode = .account; updatingDraft = false; return
                }
                clearFieldIssue(for: .password)
                clearPrivateKeyPhrase()
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
                clearPrivateKeyPhrase()
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
    @Published var authenticationMethod = AuthenticationMethod.password {
        didSet {
            guard !updatingDraft, authenticationMethod != oldValue else { return }
            guard canEditConnection, authenticationMethod == .password || transport == .sftp else {
                updatingDraft = true; authenticationMethod = oldValue; updatingDraft = false; return
            }
            clearPrivateKeyPhrase()
            password = nil
            invalidateConnection()
        }
    }
    @Published var passphrase: String? {
        didSet {
            guard !updatingDraft, passphrase != oldValue else { return }
            guard canEditConnection else { updatingDraft = true; passphrase = oldValue; updatingDraft = false; return }
            if passphrase != nil { privateKeyIdentityNotice = false }
            invalidateConnection()
        }
    }
    @Published private(set) var privateKeySelection: PrivateKeySelection?
    @Published private(set) var privateKeyReference: PrivateKeyReference?
    @Published private(set) var privateKeyIdentityNotice = false
    private let keyAccess: PrivateKeyAccessing

    private func clearPrivateKeyPhrase() {
        if passphrase != nil { privateKeyIdentityNotice = true }
        let previous = updatingDraft
        updatingDraft = true; passphrase = nil; updatingDraft = previous
    }
    func choosePrivateKey(_ url: URL) {
        guard canEditConnection else { return }
        do {
            let selection = try PrivateKeySelection.select(url, access: keyAccess)
            clearPrivateKeyPhrase()
            invalidateConnection()
            privateKeySelection = selection; privateKeyReference = nil
        } catch let issue as FieldIssue { setFieldIssue(issue) }
        catch { setFieldIssue(FieldIssue(field: .privateKey, message: "无法读取私钥，请重新选择。")) }
    }
    var privateKeyName: String { privateKeySelection?.name ?? privateKeyReference?.name ?? "尚未选择私钥" }
    var privateKeyLocation: String? {
        privateKeySelection?.url.path ?? privateKeyReference.flatMap { try? keyAccess.resolve($0.bookmark).path }
    }

    @Published var encodingPolicy = FTPEncodingPolicy.automatic {
        didSet {
            guard !updatingDraft, encodingPolicy != oldValue else { return }
            guard canEditConnection else {
                updatingDraft = true; encodingPolicy = oldValue; updatingDraft = false
                return
            }
            if transport == .sftp && encodingPolicy != .utf8 {
                updatingDraft = true; encodingPolicy = .utf8; updatingDraft = false
            }
            invalidateConnection()
        }
    }
    @Published private(set) var hostTrustRequest: SSHHostIdentity?
    @Published private(set) var changedHost: SSHHostIdentity?
    private var hostTrustVersion: Int?

    func cancelHostTrust() {
        guard hostTrustRequest != nil else { return }
        hostTrustRequest = nil; hostTrustVersion = nil
        directoryError = nil
        directoryCancelled = true
        clearPrivateKeyPhrase()
    }
    func acceptHostTrust(_ id: String) {
        guard let identity = hostTrustRequest, identity.id == id, hostTrustVersion == draftVersion, canEditConnection else { return }
        do {
            try client.trustHost(identity)
            hostTrustRequest = nil; hostTrustVersion = nil
            connect() // Fresh handshake rechecks the same key before authentication.
        } catch { directoryError = error.localizedDescription }
    }
    func resetHostTrust(_ id: String) {
        guard let identity = changedHost, identity.id == id, canEditConnection else { return }
        do {
            try client.resetHost(identity)
            changedHost = nil
            connect() // Presents the new fingerprint; reset is never implicit trust.
        } catch { directoryError = error.localizedDescription }
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
    private(set) var directoryContentRevision: UInt64 = 0
    @Published private(set) var entries: [RemoteEntry] = [] {
        didSet { directoryContentRevision &+= 1 }
    }
    @Published private(set) var isDirectoryLoading = false
    @Published private(set) var isDirectoryCancelling = false
    @Published private(set) var directoryCancelled = false
    @Published private(set) var hasDirectory = false
    @Published private(set) var directoryError: String?
    @Published private(set) var selectedFile: SelectedLocalFile?
    @Published private(set) var selectionError: String?
    @Published private(set) var uploadState = UploadState.idle
    @Published private(set) var uploadTarget: String?
    @Published private(set) var overwriteTarget: String?
    @Published private(set) var overwriteRequestID: UUID?
    @Published private(set) var sent: Int64 = 0
    @Published private(set) var uploadTrafficOverflow = false
    @Published private(set) var total: Int64 = 0

    @Published private(set) var downloadState = UploadState.idle
    @Published private(set) var downloadTarget: String?
    @Published private(set) var downloadName: String?
    @Published private(set) var downloadCleanupError: String?
    @Published private(set) var downloadBytes: Int64 = 0
    @Published private(set) var downloadTrafficOverflow = false
    @Published private(set) var downloadTotal: Int64 = -1
    @Published private(set) var downloadConfirmationID: UUID?
    private let connectionCoordinator: ConnectionSessionCoordinator
    private let singleFileCoordinator: SingleFileTransferCoordinator
    private var downloadCancellation: FTPCancellationToken? {
        get { singleFileCoordinator.downloadCancellation }
        set { singleFileCoordinator.downloadCancellation = newValue }
    }
    private var uploadConnection: TransferConnectionOwner? { singleFileCoordinator.uploadConnection }
    private var downloadConnection: TransferConnectionOwner? { singleFileCoordinator.downloadConnection }
    private let collectionCoordinator: CollectionTransferCoordinator
    var batch: BatchTransferQueue { collectionCoordinator.batch }
    /// A retry has independent ids/results; the original queue never executes it in place.
    @Published private(set) var retryBatch: BatchTransferQueue
    var retryBatches: [BatchTransferQueue] { collectionCoordinator.retries }
    private let transferExecutor: TransferExecutor
    var sessionQueues: [BatchTransferQueue] { [batch] + retryBatches }
    var sessionSummary: TransferSessionSummary? {
        guard let original = batch.summary else { return nil }
        return TransferSessionSummary(original: original, retries: retryBatches.compactMap(\.summary))
    }
    var collectionScan: TransferScanSession { collectionCoordinator.scan }
    private let rootScope: LocalSecurityScope
    private var collectionPreparation: CollectionTransferCoordinator.Preparation? { collectionCoordinator.preparation }
    var hasCollectionCredentials: Bool { collectionPreparation != nil || sessionQueues.contains(where: \.hasCredentials) }
    var collectionTarget: String? {
        guard let context = collectionPreparation else { return nil }
        return context.destination?.url.path ?? (context.endpoint.display + context.remoteRoot.display)
    }
    var collectionDirection: TransferDirection? {
        guard let context = collectionPreparation else { return collectionScan.plan?.direction }
        return context.destination != nil ? .download : .upload
    }
    let history: TransferHistory
    let metrics: TransferMetricsMonitor
    private var metricsObservation: AnyCancellable?
    private let client: FTPServing
    private var encoding = FTPTextEncoding.utf8
    private var directoryRequestID: Int { connectionCoordinator.generation }
    private var uploadRequestID: Int {
        get { singleFileCoordinator.uploadGeneration }
        set { singleFileCoordinator.uploadGeneration = newValue }
    }
    private var draftVersion: Int { connectionCoordinator.draftVersion }
    private var dropGeneration = UUID()
    private var updatingDraft = false
    private var activeCredentials: FTPCredentials?
    private var directoryCancellation: FTPCancellationToken? { connectionCoordinator.cancellation }
    private var uploadCancellation: FTPCancellationToken? {
        get { singleFileCoordinator.uploadCancellation }
        set { singleFileCoordinator.uploadCancellation = newValue }
    }
    private typealias UploadSnapshot = SingleFileTransferCoordinator.UploadSnapshot
    private var pendingOverwrite: UploadSnapshot? {
        get { singleFileCoordinator.pendingOverwrite }
        set { singleFileCoordinator.pendingOverwrite = newValue }
    }
    private var pendingUploadJob: TransferJob? {
        get { singleFileCoordinator.pendingUploadJob }
        set { singleFileCoordinator.pendingUploadJob = newValue }
    }

    private func matchesContext(_ snapshot: UploadSnapshot) -> Bool {
        snapshot.matches(version: draftVersion, endpoint: endpoint, path: path,
            encoding: encoding, file: selectedFile, credentials: activeCredentials)
    }

    private func matchesContent(_ snapshot: UploadSnapshot, cancellation: FTPCancellationToken) async throws -> Bool {
        guard matchesContext(snapshot) else { return false }
        let local = try await snapshot.file.snapshot(cancellation: cancellation)
        return matchesContext(snapshot) && local == snapshot.local
    }

    private func clearOverwrite(preserveJob: Bool = false) {
        singleFileCoordinator.clearOverwrite(preserveJob: preserveJob, history: history, target: uploadTarget ?? "")
        overwriteTarget = nil; overwriteRequestID = nil
        if uploadState == .awaitingOverwrite { uploadState = .idle }
    }

    func cancelOverwrite(_ id: UUID) {
        guard pendingOverwrite?.id == id else { return }
        clearOverwrite()
        uploadState = .cancelled
    }

    func confirmOverwrite(_ id: UUID) {
        guard let snapshot = pendingOverwrite, snapshot.id == id, let job = pendingUploadJob else { return }
        clearOverwrite(preserveJob: true)
        uploadConnection?.resume()
        startUpload(authorization: snapshot, existingJob: job)
        if !isUploading { snapshot.file.endAccess() }
    }

    private let makeDownload: (URL, LocalDownload.Identity?) throws -> LocalDownload
    private let diagnostics: TransferDiagnostics?
    private var diagnosticsObservation: AnyCancellable?
    private var sitesObservation: AnyCancellable?

    init(client: FTPServing = FTPClient(), sites: SiteManager? = nil, history: TransferHistory? = nil, keyAccess: PrivateKeyAccessing = PrivateKeyAccess(), rootScope: LocalSecurityScope = .system, diagnostics: TransferDiagnostics? = nil,
         makeDownload: ((URL, LocalDownload.Identity?) throws -> LocalDownload)? = nil) {
        self.makeDownload = makeDownload ?? { try LocalDownload(destination: $0, authorizedIdentity: $1, scope: rootScope) }
        self.diagnostics = diagnostics
        self.rootScope = rootScope
        self.keyAccess = keyAccess
        self.client = client; self.sites = sites ?? SiteManager()
        let executor = TransferExecutor(); transferExecutor = executor
        connectionCoordinator = ConnectionSessionCoordinator(client: client, executor: executor)
        singleFileCoordinator = SingleFileTransferCoordinator(client: client, executor: executor)
        let transferHistory = history ?? TransferHistory()
        self.history = transferHistory
        let monitor = TransferMetricsMonitor()
        metrics = monitor
        collectionCoordinator = CollectionTransferCoordinator(client: client, executor: executor,
            scope: rootScope, history: transferHistory, metrics: monitor)
        retryBatch = collectionCoordinator.retryBatch
        collectionCoordinator.onRetryQueueChange = { [weak self] queue in self?.retryBatch = queue }
        collectionCoordinator.onChange = { [weak self] in self?.objectWillChange.send() }
        if let diagnostics {
            diagnosticsObservation = objectWillChange.sink { diagnostics.record(.notifications) }
        }
        sitesObservation = self.sites.objectWillChange.sink { [weak self] _ in
            // Only saved-site consumers depend on recovery guards. Do not add unrelated
            // startup notifications to manual connections or independent queue observers.
            guard let self, self.selectedSiteID != nil else { return }
            self.objectWillChange.send()
        }
        // TransferPanel and TransferActivityObserver observe history directly. Async
        // loading/saving must not fan out unrelated startup notifications through AppModel.
        metricsObservation = metrics.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var isUploading: Bool { uploadState == .checkingTarget || uploadState == .uploading || uploadState == .awaitingCompletion || uploadState == .cancelling }
    var isDownloading: Bool { [.checkingTarget, .uploading, .awaitingCompletion, .cancelling, .awaitingOverwrite].contains(downloadState) }
    var isBusy: Bool { isDirectoryLoading || isUploading || isDownloading || isSiteOperationBusy || sessionQueues.contains(where: \.isLocked) || collectionScan.isLocked }
    var canEditConnection: Bool { !isBusy }
    var canCancel: Bool { (isDirectoryLoading && !isDirectoryCancelling) || (isUploading && uploadState != .cancelling) || (isDownloading && downloadState != .cancelling) || sessionQueues.contains(where: { $0.isLocked && $0.state != .cancelling }) || [.scanning, .preview].contains(collectionScan.phase) }

    var cancellationID: UUID? {
        collectionScan.isLocked ? collectionScan.cancellationID : (isDirectoryLoading ? directoryCancellation?.id : (isUploading ? uploadCancellation?.id : (downloadCancellation?.id ?? retryBatch.cancellationID ?? batch.cancellationID)))
    }

    func cancelOperation(id: UUID? = nil) {
        if let id, id != cancellationID { return }
        if collectionScan.isLocked {
            collectionScan.cancel(id: id)
        } else if isDirectoryLoading, !isDirectoryCancelling {
            isDirectoryCancelling = true
            directoryCancellation?.cancel()
        } else if retryBatch.isLocked {
            if retryBatch.isExecuting { retryBatch.cancelCurrent() } else { retryBatch.cancelAll() }
        } else if batch.isLocked {
            if batch.isExecuting { batch.cancelCurrent() } else { batch.cancelAll() }
        } else if isDownloading, downloadState != .cancelling {
            downloadCancellation?.cancel()
            if downloadState == .awaitingOverwrite {
                cancelDownloadConfirmation()
            } else { downloadState = .cancelling }
        } else if isUploading, uploadState != .cancelling {
            uploadState = .cancelling
            uploadCancellation?.cancel()
        }
    }
    var canCancelAllTransfers: Bool { collectionScan.isLocked || sessionQueues.contains(where: \.isLocked) }
    func cancelAllTransfers(id: UUID? = nil) {
        if let id, id != cancellationID { return }
        guard canCancelAllTransfers || canCancel else { return }
        if collectionPreparation?.isRetry == true || sessionQueues.contains(where: { $0.retryPending }) {
            // Each ancestor stays locked until its descendant reports backend stop.
            sessionQueues.filter(\.isLocked).forEach { $0.cancelAll() }
            if collectionScan.isLocked { collectionScan.cancel(id: id) }
        } else if collectionScan.isLocked { collectionScan.cancel(id: id) }
        else if sessionQueues.contains(where: \.isLocked) { sessionQueues.filter(\.isLocked).forEach { $0.cancelAll() } }
        else { cancelOperation(id: id) }
    }
    var canConnect: Bool {
        canEditConnection && sites.canUseSite(selectedSiteID) && !isPasswordLoading && !isDirectoryLoading
            && !address.trimmingCharacters(in: .whitespaces).isEmpty
    }
    var connectionIdentity: String {
        guard let credentials = activeCredentials, let endpoint else { return transport.title }
        return endpoint.transport.title + (credentials.mode == .anonymous ? " · 匿名访问" : " · 账户：\(credentials.username)" + (credentials.authenticationMethod == .privateKey ? " · 私钥认证" : ""))
    }
    var canChooseFile: Bool { hasDirectory && !isBusy && sites.canUseSite(selectedSiteID) }
    var canPrepareCollection: Bool { canChooseFile && uploadState != .awaitingOverwrite }
    var canUpload: Bool { canChooseFile && selectedFile != nil && uploadState != .awaitingOverwrite }
    /// Safe UI context derived only from the effective directory, never a draft.
    var effectiveDirectoryContext: DirectoryContext? {
        guard hasDirectory, let endpoint, let credentials = activeCredentials else { return nil }
        return DirectoryContext(identity: FTPIdentity(host: endpoint.host, port: endpoint.port,
            username: credentials.username, mode: credentials.mode, transport: endpoint.transport,
            authenticationMethod: credentials.authenticationMethod), path: path)
    }
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
            next = try FTPEndpoint(address: address, transport: transport)
            if authenticationMethod == .privateKey {
                guard next.transport == .sftp else { throw FieldIssue(field: .privateKey, message: "私钥认证仅适用于 SFTP。") }
                let selection: PrivateKeySelection
                if let chosen = privateKeySelection { selection = chosen }
                else if let reference = privateKeyReference {
                    selection = PrivateKeySelection(url: try keyAccess.resolve(reference.bookmark), digest: reference.digest)
                } else { throw FieldIssue(field: .privateKey, message: "请选择私钥文件。") }
                credentials = try .key(username: username, material: selection.material(access: keyAccess), passphrase: passphrase)
            } else { credentials = loginMode == .anonymous ? .anonymous : try .account(username: username, password: password) }
        } catch let issue as FieldIssue {
            if issue.field == .privateKey { clearPrivateKeyPhrase(); invalidateConnection() }
            setFieldIssue(issue)
            return
        } catch {
            setFieldIssue(nil)
            directoryError = error.localizedDescription
            return
        }
        setFieldIssue(nil)
        requestDirectory(endpoint: next, path: next.initialPath, preferredEncoding: nil, credentials: credentials, resolveInitial: true)
    }

    /// Reconnect from the path popover. The draft address is validated before it is
    /// applied, so an invalid draft keeps the old directory, the popover and the draft.
    /// Returns `true` only when the connection request was actually started.
    @discardableResult
    func reconnect(to draftAddress: String) -> Bool {
        guard canEditConnection, !isDirectoryLoading else { return false }
        do { _ = try FTPEndpoint(address: draftAddress, transport: transport) }
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
        hostTrustRequest = nil; hostTrustVersion = nil; changedHost = nil
        connectionCoordinator.invalidate()
        endpoint = nil
        path = .root
        entries = []
        hasDirectory = false
        isDirectoryLoading = false
        isDirectoryCancelling = false
        directoryCancelled = false
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
        passphrase = nil; privateKeyIdentityNotice = false; privateKeySelection = nil; privateKeyReference = nil
        selectedSiteID = id
        updatingDraft = true
        defer { updatingDraft = false }
        if let site = sites.sites.first(where: { $0.id == id }) {
            transport = site.transport
            encodingPolicy = site.encodingPolicy
            address = site.address; loginMode = site.loginMode; username = site.username; password = nil
            authenticationMethod = site.authenticationMethod; privateKeyReference = site.privateKeyReference
            if site.rememberPassword && site.authenticationMethod == .password { loadPassword(site) }
        } else { authenticationMethod = .password; transport = .ftp; encodingPolicy = .automatic; address = ""; loginMode = .anonymous; username = ""; password = nil }
    }

    private func loadPassword(_ site: FTPSite) {
        let version = draftVersion
        isPasswordLoading = true
        Task {
            do {
                let saved = try await sites.password(for: site)
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
        if let endpoint = try? FTPEndpoint(address: address, transport: transport) {
            draft.host = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
            draft.port = String(endpoint.port)
            draft.initialDirectory = "/" + endpoint.initialSegments.map(\.source).joined(separator: "/")
        }
        draft.authenticationMethod = authenticationMethod; draft.privateKeyReference = privateKeyReference
        draft.privateKeySelection = privateKeySelection; draft.passphrase = passphrase
        draft.transport = transport
        draft.encodingPolicy = encodingPolicy
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
            if saved.authenticationMethod == .privateKey {
                updatingDraft = true; passphrase = draft.passphrase; updatingDraft = false
            }
            if saved.authenticationMethod == .password, saved.loginMode == .account, let supplied = draft.password {
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
                                  preferredEncoding: FTPTextEncoding?, credentials: FTPCredentials, resolveInitial: Bool = false) {
        guard sites.canUseSite(selectedSiteID) else {
            directoryError = "此站点恢复未完成，未发起网络请求。请先恢复或使用独立手动连接。"
            return
        }
        clearOverwrite()
        let request = connectionCoordinator.begin()
        let id = request.generation
        let policy = encodingPolicy
        let cancellation = request.cancellation
        isDirectoryLoading = true
        isDirectoryCancelling = false
        directoryCancelled = false
        directoryError = nil
        Task {
            do {
                let resolved = try await connectionCoordinator.list(endpoint: requestedEndpoint, path: requestedPath,
                    preferredEncoding: preferredEncoding, policy: policy, credentials: credentials,
                    resolveInitial: resolveInitial, cancellation: cancellation)
                let listing = resolved.listing, resolvedPath = resolved.path
                guard id == directoryRequestID else { return }
                endpoint = requestedEndpoint
                activeCredentials = credentials
                path = resolvedPath
                entries = listing.entries
                encoding = listing.encoding
                hasDirectory = true
                isDirectoryLoading = false
                connectionCoordinator.finish(id)
            } catch {
                guard id == directoryRequestID else { return }
                isDirectoryLoading = false
                isDirectoryCancelling = false
                connectionCoordinator.finish(id)
                if credentials.authenticationMethod == .privateKey,
                   !(error is HostTrustError) {
                    activeCredentials = nil
                    clearPrivateKeyPhrase()
                    hasDirectory = false
                }
                if cancellation.isCancelled || error is CancellationError {
                    directoryCancelled = true
                } else {
                    if case HostTrustError.unknown(let identity) = error {
                        hostTrustRequest = identity; hostTrustVersion = draftVersion
                    } else if case HostTrustError.changed(let identity) = error {
                        changedHost = identity
                    }
                    if let issue = error as? FieldIssue { setFieldIssue(issue) }
                    else { directoryError = credentials.redacting(error.localizedDescription) }
                }
            }
        }
    }

    @discardableResult
    func selectDroppedFiles(_ urls: [URL]) -> Bool {
        guard canChooseFile else { return false }
        guard !urls.isEmpty, urls.count <= TransferPlan.maximumNodes,
              Set(urls.map(\.standardizedFileURL)).count == urls.count else {
            selectionError = "拖入项目为空、重复或超过批次上限。"; return false
        }
        var accesses: [LocalSourceRoot] = []
        defer { accesses.forEach { $0.endAccess() } }
        do {
            for url in urls { accesses.append(try LocalSourceRoot(url: url, scope: rootScope)) }
            if urls.count == 1, accesses[0].identity.kind == .regularFile {
                selectFile(urls[0]); return selectionError == nil
            }
            return prepareUploadCollection(urls)
        } catch {
            selectionError = activeCredentials?.redacting(error.localizedDescription) ?? "无法读取拖入项目。"
            return false
        }
    }

    /// Providers may complete after navigation, a new drop or a transfer starts.
    /// Preserve provider order and publish only when the original connection generation is current.
    @discardableResult
    func receiveFileDrop(loaders: [() async throws -> URL]) -> Bool {
        guard canChooseFile, !loaders.isEmpty, loaders.count <= TransferPlan.maximumNodes else { return false }
        let generation = UUID(), version = draftVersion, directory = directoryRequestID
        dropGeneration = generation
        Task {
            do {
                var urls: [URL] = []
                for load in loaders { urls.append(try await load()) }
                guard dropGeneration == generation, draftVersion == version,
                      directoryRequestID == directory, canChooseFile else { return }
                _ = selectDroppedFiles(urls)
            } catch {
                guard dropGeneration == generation, draftVersion == version,
                      directoryRequestID == directory, canChooseFile else { return }
                selectionError = activeCredentials?.redacting(error.localizedDescription) ?? "无法读取拖入项目。"
            }
        }
        return true
    }

    func selectFile(_ url: URL) {
        guard canChooseFile else { return }
        selectionError = nil
        do {
            let file = try SelectedLocalFile(url: url, diagnostics: diagnostics)
            clearFile()
            selectedFile = file
            resetUpload()
        } catch {
            clearFile()
            selectionError = error.localizedDescription
        }
    }

    func fileSelectionFailed(_ error: Error) {
        guard canChooseFile, (error as NSError).code != NSUserCancelledError else { return }
        selectionError = error.localizedDescription
    }

    func upload() { startUpload(authorization: nil) }

    private func startUpload(authorization: UploadSnapshot?, existingJob: TransferJob? = nil) {
        guard canUpload, let endpoint, let file = selectedFile, let credentials = activeCredentials else { return }
        let targetPath = path
        let targetEncoding = encoding
        uploadTarget = pendingTarget
        uploadTrafficOverflow = false
        sent = 0
        total = file.size
        metrics.reset(total: total)
        let cancellation = existingJob?.cancellation ?? FTPCancellationToken()
        let job = existingJob ?? TransferJob(direction: .upload, endpoint: endpoint, path: targetPath,
                                            encoding: targetEncoding, credentials: credentials, localURL: file.url,
                                            cancellation: cancellation)
        let version = draftVersion
        let connection = singleFileCoordinator.uploadSession(endpoint: endpoint, credentials: credentials,
            continuing: existingJob != nil)
        let files = FileTransferRunner(client: connection, executor: transferExecutor)
        do {
            try file.beginAccessAndValidate()
            _ = try endpoint.fileURL(targetPath, name: file.name, encoding: targetEncoding)
        } catch {
            singleFileCoordinator.closeUpload(connection)
            file.endAccess()
            job.finish(.failed(credentials.redacting(error.localizedDescription)))
            job.byteCounter.finish()
            history.record(job, target: uploadTarget ?? "", bytes: 0); metrics.stop()
            uploadState = .failed(credentials.redacting(error.localizedDescription))
            return
        }
        total = file.size
        uploadRequestID += 1
        let id = uploadRequestID
        uploadCancellation = cancellation
        uploadState = .checkingTarget
        let progressGeneration = job.id, historyTarget = uploadTarget ?? "", expectedTotal = file.size
        let progressBox = TransferProgressMailbox(generation: progressGeneration, contentSent: { [weak self] in
            guard let self, self.uploadRequestID == id, self.isUploading, !cancellation.isCancelled else { return }
            self.uploadState = .awaitingCompletion
        }, deliver: { [weak self] sample in
            guard let self, self.uploadRequestID == id, self.isUploading, !cancellation.isCancelled else { return }
            _ = self.metrics.update(bytes: sample.bytes, total: sample.total, force: true)
            self.sent = max(self.sent, sample.bytes)
            if sample.total >= 0 { self.total = sample.total }
        })
        Task { [self, file] in
            defer {
                progressBox.stop()
                if pendingUploadJob !== job {
                    connection.close()
                    singleFileCoordinator.closeUpload(connection)
                }
                file.endAccess(); if id == uploadRequestID { uploadCancellation = nil }
                if job.outcome != nil {
                    job.byteCounter.finish()
                    if id == uploadRequestID {
                        sent = job.byteCounter.bytes
                        uploadTrafficOverflow = job.byteCounter.hasOverflow
                        metrics.finish(bytes: sent, total: expectedTotal)
                    }
                    history.record(job, target: historyTarget, bytes: job.byteCounter.bytes)
                } else { metrics.stop() }
            }
            do {
                let local = try await file.snapshot(cancellation: cancellation)
                try cancellation.checkCancellation()
                let snapshot = UploadSnapshot(version: version, endpoint: endpoint, path: targetPath,
                                              credentials: credentials, encoding: targetEncoding, file: file, local: local)
                if let authorization, !matchesContext(authorization) || local != authorization.local {
                    job.finish(.cancelled)
                    uploadState = .cancelled
                    selectionError = "来源或上传上下文已变化，旧覆盖授权已取消。请重新点击上传并核对目标。"
                    return
                }
                if authorization == nil {
                    let existing = try await connection.checkUploadTarget(endpoint: endpoint, path: targetPath, name: file.name,
                                                                    encoding: targetEncoding, credentials: credentials, cancellation: cancellation)
                    try cancellation.checkCancellation()
                    guard id == uploadRequestID else { return }
                    guard matchesContext(snapshot) else { throw FTPError.localFile("目标检查期间上传上下文已变化，请重新选择或上传。") }
                    if let existing {
                        guard try await matchesContent(snapshot, cancellation: cancellation) else { throw FTPError.localFile("文件在目标检查期间发生变化，请重新选择或上传。") }
                        if existing.kind != .regularFile { throw FTPError.uploadTargetConflict }
                        pendingOverwrite = snapshot
                        pendingUploadJob = job
                        metrics.stop()
                        overwriteRequestID = snapshot.id
                        overwriteTarget = uploadTarget
                        connection.pause()
                        uploadState = .awaitingOverwrite
                        return
                    }
                } else {
                    guard let authorization, matchesContext(authorization) else {
                        throw FTPError.localFile("本次覆盖授权已失效，请重新检查目标。")
                    }
                }
                uploadState = .uploading
                try await files.run(job, preparing: {
                    let approved = authorization ?? snapshot
                    guard matchesContext(approved) else { throw FTPError.localFile("发送前上传上下文已变化。") }
                    job.uploadSource = try await file.verifiedSource(matching: approved.local, cancellation: cancellation)
                    guard matchesContext(approved) else { throw FTPError.localFile("最终内容核对期间上传上下文已变化。") }
                }, progress: { bytes, _ in
                    progressBox.submit(bytes: bytes, total: expectedTotal, generation: progressGeneration)
                    if bytes >= expectedTotal { progressBox.signalContentSent() }
                })
                try cancellation.checkCancellation()
                guard id == uploadRequestID else { return }
                connection.close(); file.endAccess()
                sent = total
                uploadState = .succeeded
                refresh()
            } catch {
                connection.close(); file.endAccess()
                job.finish(cancellation.isCancelled || error is CancellationError ? .cancelled : .failed(credentials.redacting(error.localizedDescription)))
                guard id == uploadRequestID else { return }
                if case HostTrustError.changed(let identity) = error { changedHost = identity }
                uploadState = cancellation.isCancelled || error is CancellationError ? .cancelled : .failed(credentials.redacting(error.localizedDescription))
            }
        }
    }

    /// A new batch rechecks the selected key association once; active/paused jobs never reread it.
    private func newCollectionCredentials() -> FTPCredentials? {
        guard let credentials = activeCredentials else { return nil }
        guard credentials.authenticationMethod == .privateKey else { return credentials }
        do {
            let selection: PrivateKeySelection
            if let chosen = privateKeySelection { selection = chosen }
            else if let reference = privateKeyReference {
                selection = PrivateKeySelection(url: try keyAccess.resolve(reference.bookmark), digest: reference.digest)
            } else { throw FieldIssue(field: .privateKey, message: "请重新选择私钥文件。") }
            return try .key(username: credentials.username, material: selection.material(access: keyAccess), passphrase: credentials.passphrase)
        } catch let issue as FieldIssue {
            if issue.field == .privateKey { clearPrivateKeyPhrase() }
            setFieldIssue(issue)
        } catch { selectionError = credentials.redacting(error.localizedDescription) }
        return nil
    }

    @discardableResult
    func prepareUploadCollection(_ urls: [URL]) -> Bool {
        guard canPrepareCollection, let endpoint,
              !urls.isEmpty, urls.count <= TransferPlan.maximumNodes, let credentials = newCollectionCredentials() else { return false }
        return collectionCoordinator.prepareUpload(urls, endpoint: endpoint, path: path,
            encoding: encoding, credentials: credentials)
    }

    @discardableResult
    func prepareDownloadCollection(_ selected: [RemoteEntry], to destination: URL) -> Bool {
        guard canPrepareCollection, let endpoint,
              !selected.isEmpty, selected.count <= TransferPlan.maximumNodes,
              selected.allSatisfy({ entries.contains($0) }), let credentials = newCollectionCredentials() else { return false }
        let selections: [RemoteTransferScanner.Selection]
        do {
            selections = try selected.map { .init(entry: $0, path: try path.appending(name: $0.name, bytes: $0.rawName), encoding: encoding) }
        } catch { selectionError = credentials.redacting(error.localizedDescription); return false }
        return collectionCoordinator.prepareDownload(selections, to: destination, endpoint: endpoint,
            path: path, encoding: encoding, credentials: credentials)
    }

    @discardableResult
    func removeCollectionRoot(_ id: UUID) -> Bool {
        guard collectionScan.phase == .preview, let plan = collectionScan.plan,
              plan.roots.contains(where: { $0.id == id }), let context = collectionPreparation,
              !context.isRetry else { return false }
        let remaining = plan.roots.filter { $0.id != id }
        let destination = context.destination?.url
        let uploads = remaining.compactMap { root -> URL? in
            if case .local(let url) = root.source { return url }; return nil
        }
        let downloads = remaining.compactMap { root -> RemoteEntry? in
            guard case .remote(let path, _) = root.source, let bytes = path.components.last?.bytes else { return nil }
            return entries.first { $0.rawName == bytes }
        }
        collectionScan.cancel(id: collectionScan.cancellationID)
        if remaining.isEmpty { return true }
        if plan.direction == .upload { return prepareUploadCollection(uploads) }
        guard let destination, downloads.count == remaining.count else { return false }
        return prepareDownloadCollection(downloads, to: destination)
    }
    var canRemoveCollectionRoots: Bool { collectionPreparation?.isRetry == false && collectionScan.phase == .preview }

    struct BatchOverwritePrompt: Identifiable {
        let id: UUID
        let queue: BatchTransferQueue
        let target: String
    }
    var batchOverwritePrompt: BatchOverwritePrompt? {
        for queue in sessionQueues {
            if let id = queue.overwriteID { return .init(id: id, queue: queue, target: queue.overwriteTarget ?? "") }
        }
        return nil
    }
    private var queueControlAvailable: Bool {
        !collectionScan.isLocked && !isDirectoryLoading && !isUploading && !isDownloading && !isSiteOperationBusy && uploadState != .awaitingOverwrite
    }
    func canContinueQueue(_ queue: BatchTransferQueue) -> Bool {
        queueControlAvailable && sessionQueues.contains { $0 === queue } && queue.canContinue && !sessionQueues.contains(where: \.isExecuting)
    }
    func continueQueue(_ queue: BatchTransferQueue) {
        guard canContinueQueue(queue) else { return }; queue.startOrContinue()
    }
    func canSkipQueue(_ queue: BatchTransferQueue) -> Bool {
        queueControlAvailable && sessionQueues.contains { $0 === queue } && queue.canSkipCurrent && !sessionQueues.contains(where: \.isExecuting)
    }
    func skipQueue(_ queue: BatchTransferQueue) {
        guard canSkipQueue(queue) else { return }; queue.skip()
    }
    private func retryOrigin(itemID: UUID?, batchID: UUID?) -> BatchTransferQueue? {
        if let itemID { return sessionQueues.first { $0.items.contains { $0.id == itemID } } }
        if let batchID { return sessionQueues.first { $0.collectionPlanID == batchID } }
        return batch
    }
    func canPrepareCollectionRetry(itemID: UUID? = nil, batchID: UUID? = nil) -> Bool {
        guard queueControlAvailable, collectionScan.phase == .finished,
              !sessionQueues.contains(where: { $0.isExecuting || $0.state == .preview || $0.state == .cancelling }),
              let origin = retryOrigin(itemID: itemID, batchID: batchID), origin.canBeginCollectionRetry(itemID: itemID) else { return false }
        return origin.state == .paused || (endpoint == origin.retryEndpoint && activeCredentials != nil)
    }
    @discardableResult
    func prepareCollectionRetry(itemID: UUID? = nil, batchID: UUID? = nil) -> Bool {
        guard canPrepareCollectionRetry(itemID: itemID, batchID: batchID),
              let origin = retryOrigin(itemID: itemID, batchID: batchID) else { return false }
        return collectionCoordinator.prepareRetry(origin: origin, itemID: itemID,
            endpoint: endpoint, currentCredentials: newCollectionCredentials)
    }

    @discardableResult
    func confirmCollection(_ planID: UUID, policy: TransferConflictPolicy = .ask) -> Bool {
        do { return try collectionCoordinator.confirm(planID, policy: policy) }
        catch { selectionError = error.localizedDescription; return false }
    }

    func prepareBatch(_ urls: [URL]) {
        guard canChooseFile, uploadState != .awaitingOverwrite, let endpoint, let credentials = newCollectionCredentials() else { return }
        do { try batch.prepare(urls, endpoint: endpoint, path: path, encoding: encoding, credentials: credentials) }
        catch { selectionError = error.localizedDescription }
    }

    struct DownloadSelectionContext {
        let entries: [RemoteEntry]
        fileprivate let directoryGeneration: Int
        fileprivate let draft: Int
    }
    func canDownloadSelection(_ selected: [RemoteEntry]) -> Bool {
        canPrepareCollection && RemoteDirectorySelection.downloadRoute(selected) != nil && selected.allSatisfy { entries.contains($0) }
    }
    func captureDownloadSelection(_ selected: [RemoteEntry]) -> DownloadSelectionContext? {
        guard canDownloadSelection(selected) else { return nil }
        return DownloadSelectionContext(entries: selected, directoryGeneration: directoryRequestID, draft: draftVersion)
    }
    func isCurrentDownloadSelection(_ context: DownloadSelectionContext) -> Bool {
        context.directoryGeneration == directoryRequestID && context.draft == draftVersion && canDownloadSelection(context.entries)
    }
    /// A delayed system picker must not download from a replacement connection.
    func downloadSelection(_ context: DownloadSelectionContext, to destination: URL,
                           authorizedIdentity: LocalDownload.Identity? = nil) {
        guard isCurrentDownloadSelection(context), let route = RemoteDirectorySelection.downloadRoute(context.entries) else { return }
        switch route {
        case .singleFile(let entry): download(entry, to: destination, authorizedIdentity: authorizedIdentity)
        case .collection(let entries): _ = prepareDownloadCollection(entries, to: destination)
        }
    }
    func downloadSelectionFailed(_ error: Error) {
        guard canPrepareCollection else { return }
        downloadState = .failed(error.localizedDescription)
    }

    func download(_ entry: RemoteEntry, to destination: URL, authorizedIdentity: LocalDownload.Identity? = nil) {
        guard canPrepareCollection, entry.kind == .regularFile, entries.contains(entry),
              let endpoint, let credentials = activeCredentials else { return }
        let remote: RemotePath
        let sink: LocalDownload
        do {
            remote = try path.appending(name: entry.name, bytes: entry.rawName)
            sink = try makeDownload(destination, authorizedIdentity)
        } catch { downloadState = .failed(error.localizedDescription); return }
        let token = FTPCancellationToken()
        downloadCancellation = token
        downloadCleanupError = nil
        downloadConfirmationID = nil
        downloadName = entry.name
        downloadTarget = endpoint.display + remote.display + " → " + destination.path
        downloadTrafficOverflow = false
        downloadBytes = 0; downloadTotal = entry.size ?? -1; downloadState = .uploading
        let job = TransferJob(direction: .download, endpoint: endpoint, path: remote, encoding: encoding,
                              credentials: credentials, localURL: destination, cancellation: token, name: entry.name)
        metrics.reset(total: downloadTotal)
        let historyTarget = downloadTarget ?? "", progressGeneration = job.id, knownEmpty = entry.size == 0
        let progressBox = TransferProgressMailbox(generation: progressGeneration, contentSent: { [weak self] in
            guard let self, self.downloadCancellation === token, !token.isCancelled,
                  [.uploading, .awaitingCompletion].contains(self.downloadState) else { return }
            self.downloadState = .awaitingCompletion
        }, deliver: { [weak self] sample in
            guard let self, self.downloadCancellation === token, !token.isCancelled,
                  [.uploading, .awaitingCompletion].contains(self.downloadState) else { return }
            _ = self.metrics.update(bytes: sample.bytes, total: sample.total, force: true)
            self.downloadBytes = max(self.downloadBytes, sample.bytes)
            if sample.total >= 0 { self.downloadTotal = sample.total }
        })
        let connection = singleFileCoordinator.downloadSession(endpoint: endpoint, credentials: credentials)
        let files = FileTransferRunner(client: connection, executor: transferExecutor)
        Task {
            defer {
                singleFileCoordinator.closeDownload(connection)
                progressBox.stop(); job.byteCounter.finish()
                downloadBytes = job.byteCounter.bytes
                downloadTrafficOverflow = job.byteCounter.hasOverflow
                metrics.finish(bytes: downloadBytes, total: downloadTotal)
                history.record(job, target: historyTarget, bytes: job.byteCounter.bytes)
            }
            do {
                _ = try await files.runDownload(job, sink: sink, confirmTarget: { target, identity in
                    try token.checkCancellation()
                    guard downloadCancellation === token, job.outcome == nil else { throw CancellationError() }
                    let decisionID = UUID()
                    connection.pause()
                    return try await withCheckedThrowingContinuation { continuation in
                        singleFileCoordinator.waitForDownloadDecision(id: decisionID, job: job, target: target,
                            identity: identity, continuation: continuation)
                        downloadConfirmationID = decisionID
                        downloadState = .awaitingOverwrite
                    }
                }, cleanupFailure: { error in
                    downloadCleanupError = credentials.redacting(error.localizedDescription)
                }, progress: { bytes, total in
                    progressBox.submit(bytes: bytes, total: total, generation: progressGeneration)
                    if (total > 0 || (total == 0 && knownEmpty)) && bytes >= total { progressBox.signalContentSent() }
                })
                connection.close()
                downloadBytes = sink.byteCount
                downloadState = .succeeded; downloadCancellation = nil
            } catch {
                connection.close()
                let message = credentials.redacting(error.localizedDescription)
                if token.isCancelled || error is CancellationError { downloadState = .cancelled }
                else { downloadState = .failed(message) }
                if case HostTrustError.changed(let identity) = error { changedHost = identity }
                downloadCancellation = nil
            }
        }
    }

    func confirmDownloadCommit(_ id: UUID) {
        guard downloadConfirmationID == id, singleFileCoordinator.confirmDownload(id) else { return }
        downloadConfirmationID = nil
    }

    func cancelDownloadConfirmation(_ id: UUID? = nil) {
        guard singleFileCoordinator.cancelDownloadDecision(id) else { return }
        downloadConfirmationID = nil
        downloadState = .cancelling
    }

    private func clearFile() {
        selectedFile?.endAccess()
        selectedFile = nil
        selectionError = nil
    }

    private func resetUpload() {
        uploadState = .idle
        clearOverwrite()
        uploadTarget = nil
        uploadTrafficOverflow = false
        sent = 0
        total = 0
    }
}
