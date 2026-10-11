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
    @Published private(set) var entries: [RemoteEntry] = []
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
    @Published private(set) var total: Int64 = 0

    @Published private(set) var downloadState = UploadState.idle
    @Published private(set) var downloadTarget: String?
    @Published private(set) var downloadName: String?
    @Published private(set) var downloadCleanupError: String?
    @Published private(set) var downloadBytes: Int64 = 0
    @Published private(set) var downloadTotal: Int64 = -1
    @Published private(set) var downloadConfirmationID: UUID?
    private var downloadCancellation: FTPCancellationToken?
    private var pendingDownload: LocalDownload?
    private var downloadCommitContinuation: CheckedContinuation<Void, Error>?
    private let files: FileTransferRunner
    let batch: BatchTransferQueue
    /// A retry has independent ids/results; the original queue never executes it in place.
    @Published private(set) var retryBatch: BatchTransferQueue
    private(set) var retryBatches: [BatchTransferQueue] = []
    private let transferExecutor: TransferExecutor
    var sessionQueues: [BatchTransferQueue] { [batch] + retryBatches }
    var sessionSummary: TransferSessionSummary? {
        guard let original = batch.summary else { return nil }
        return TransferSessionSummary(original: original, retries: retryBatches.compactMap(\.summary))
    }
    let collectionScan = TransferScanSession()
    private let rootScope: LocalSecurityScope
    private final class CollectionPreparation {
        let endpoint: FTPEndpoint
        let remoteRoot: RemotePath
        let encoding: FTPTextEncoding
        let credentials: FTPCredentials
        var roots: [LocalSourceRoot] = []
        var sources: [UUID: LocalSourceRoot] = [:]
        var destination: LocalDestinationRoot?
        var isRetry = false
        var retryOrigin: BatchTransferQueue?
        var retryHoldID: UUID?
        var heldQueues: [BatchTransferQueue] = []
        @MainActor
        func endRetryPreparation() {
            retryOrigin?.endCollectionRetry()
            if let id = retryHoldID { heldQueues.forEach { $0.releaseRetryHold(id) } }
        }
        init(endpoint: FTPEndpoint, remoteRoot: RemotePath, encoding: FTPTextEncoding, credentials: FTPCredentials) {
            self.endpoint = endpoint; self.remoteRoot = remoteRoot; self.encoding = encoding; self.credentials = credentials
        }
        func release() {
            roots.forEach { $0.endAccess() }; destination?.endAccess()
            roots = []; sources = [:]; destination = nil
        }
    }
    private var collectionPreparation: CollectionPreparation?
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
    let metrics = TransferMetricsMonitor()
    private var historyObservation: AnyCancellable?
    private var metricsObservation: AnyCancellable?
    private var batchObservation: AnyCancellable?
    private var scanObservation: AnyCancellable?
    private var retryObservation: AnyCancellable?
    private let client: FTPServing
    private var encoding = FTPTextEncoding.utf8
    private var directoryRequestID = 0
    private var uploadRequestID = 0
    private var draftVersion = 0
    private var dropGeneration = UUID()
    private var updatingDraft = false
    private var activeCredentials: FTPCredentials?
    private var directoryCancellation: FTPCancellationToken?
    private var uploadCancellation: FTPCancellationToken?
    private struct UploadSnapshot {
        let id = UUID()
        let version: Int
        let endpoint: FTPEndpoint
        let path: RemotePath
        let credentials: FTPCredentials
        let encoding: FTPTextEncoding
        let file: SelectedLocalFile
        let local: SelectedLocalFile.Snapshot
    }
    private var pendingOverwrite: UploadSnapshot?
    private var pendingUploadJob: TransferJob?

    private func matches(_ snapshot: UploadSnapshot, cancellation: FTPCancellationToken) async throws -> Bool {
        guard snapshot.version == draftVersion, snapshot.endpoint == endpoint,
              snapshot.path == path, snapshot.encoding == encoding,
              snapshot.file === selectedFile, let credentials = activeCredentials,
              snapshot.credentials.sameAuthentication(as: credentials) else { return false }
        return try await snapshot.file.snapshot(cancellation: cancellation) == snapshot.local
    }

    private func clearOverwrite(preserveJob: Bool = false) {
        if !preserveJob, let job = pendingUploadJob {
            job.finish(.cancelled)
            history.record(job, target: uploadTarget ?? "", bytes: 0)
        }
        pendingUploadJob = nil
        pendingOverwrite = nil; overwriteTarget = nil; overwriteRequestID = nil
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
        startUpload(authorization: snapshot, existingJob: job)
        if !isUploading { snapshot.file.endAccess() }
    }

    init(client: FTPServing = FTPClient(), sites: SiteManager? = nil, history: TransferHistory? = nil, keyAccess: PrivateKeyAccessing = PrivateKeyAccess(), rootScope: LocalSecurityScope = .system) {
        self.rootScope = rootScope
        self.keyAccess = keyAccess
        self.client = client; self.sites = sites ?? SiteManager()
        let executor = TransferExecutor(); transferExecutor = executor
        files = FileTransferRunner(client: client, executor: executor)
        batch = BatchTransferQueue(client: client, executor: executor)
        retryBatch = BatchTransferQueue(client: client, executor: executor)
        self.history = history ?? TransferHistory()
        batch.onFinish = { [weak self] job, target, bytes in
            if self?.batch.isCollection == false { self?.history.record(job, target: target, bytes: bytes) }
            if self?.batch.isExecuting == false { self?.metrics.stop() }
        }
        batch.onHistoryRecord = { [weak self] record in self?.history.record(record) }
        batch.onStart = { [weak self] total in self?.metrics.reset(total: total) }
        batch.onProgress = { [weak self] _, bytes, total in self?.metrics.update(bytes: bytes, total: total) ?? false }
        historyObservation = self.history.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        metricsObservation = metrics.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        batchObservation = batch.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        scanObservation = collectionScan.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        retryObservation = retryBatch.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        collectionScan.onDiscard = { [weak self] in
            guard let self else { return }
            let context = collectionPreparation
            context?.release(); collectionPreparation = nil
            context?.endRetryPreparation()
        }
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
        canEditConnection && !isPasswordLoading && !isDirectoryLoading
            && !address.trimmingCharacters(in: .whitespaces).isEmpty
    }
    var connectionIdentity: String {
        guard let credentials = activeCredentials, let endpoint else { return transport.title }
        return endpoint.transport.title + (credentials.mode == .anonymous ? " · 匿名访问" : " · 账户：\(credentials.username)" + (credentials.authenticationMethod == .privateKey ? " · 私钥认证" : ""))
    }
    var canChooseFile: Bool { hasDirectory && !isBusy }
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
        draftVersion += 1
        directoryRequestID += 1
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
        clearOverwrite()
        directoryRequestID += 1
        let id = directoryRequestID
        let policy = encodingPolicy
        let cancellation = FTPCancellationToken()
        directoryCancellation = cancellation
        isDirectoryLoading = true
        isDirectoryCancelling = false
        directoryCancelled = false
        directoryError = nil
        Task {
            do {
                let listing: DirectoryListing
                let resolvedPath: RemotePath
                if resolveInitial {
                    let resolved = try await client.resolveInitialDirectory(endpoint: requestedEndpoint, policy: policy,
                                                                           credentials: credentials, cancellation: cancellation)
                    listing = resolved.listing; resolvedPath = resolved.path
                } else {
                    listing = try await client.list(endpoint: requestedEndpoint, path: requestedPath, encoding: preferredEncoding, credentials: credentials, cancellation: cancellation)
                    resolvedPath = requestedPath
                }
                try cancellation.checkCancellation()
                guard id == directoryRequestID else { return }
                endpoint = requestedEndpoint
                activeCredentials = credentials
                path = resolvedPath
                entries = listing.entries
                encoding = listing.encoding
                hasDirectory = true
                isDirectoryLoading = false
                directoryCancellation = nil
            } catch {
                guard id == directoryRequestID else { return }
                isDirectoryLoading = false
                isDirectoryCancelling = false
                directoryCancellation = nil
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
        guard canChooseFile, (error as NSError).code != NSUserCancelledError else { return }
        selectionError = error.localizedDescription
    }

    func upload() { startUpload(authorization: nil) }

    private func startUpload(authorization: UploadSnapshot?, existingJob: TransferJob? = nil) {
        guard canUpload, let endpoint, let file = selectedFile, let credentials = activeCredentials else { return }
        let targetPath = path
        let targetEncoding = encoding
        uploadTarget = pendingTarget
        sent = 0
        total = file.size
        metrics.reset(total: total)
        let cancellation = existingJob?.cancellation ?? FTPCancellationToken()
        let job = existingJob ?? TransferJob(direction: .upload, endpoint: endpoint, path: targetPath,
                                            encoding: targetEncoding, credentials: credentials, localURL: file.url,
                                            cancellation: cancellation)
        let version = draftVersion
        do {
            try file.beginAccessAndValidate()
            _ = try endpoint.fileURL(targetPath, name: file.name, encoding: targetEncoding)
        } catch {
            file.endAccess()
            job.finish(.failed(credentials.redacting(error.localizedDescription)))
            history.record(job, target: uploadTarget ?? "", bytes: 0); metrics.stop()
            uploadState = .failed(credentials.redacting(error.localizedDescription))
            return
        }
        total = file.size
        uploadRequestID += 1
        let id = uploadRequestID
        uploadCancellation = cancellation
        uploadState = .checkingTarget
        Task { [self, file] in
            defer {
                file.endAccess(); if id == uploadRequestID { uploadCancellation = nil }
                if job.outcome != nil { history.record(job, target: uploadTarget ?? "", bytes: metrics.bytes); metrics.stop() }
            }
            do {
                let local = try await file.snapshot(cancellation: cancellation)
                try cancellation.checkCancellation()
                let snapshot = UploadSnapshot(version: version, endpoint: endpoint, path: targetPath,
                                              credentials: credentials, encoding: targetEncoding, file: file, local: local)
                if let authorization, !(try await matches(authorization, cancellation: cancellation)) {
                    job.finish(.cancelled)
                    uploadState = .idle
                    // A changed source requires a fresh target check, never the old authorization.
                    Task { self.upload() }
                    return
                }
                if authorization == nil {
                    let existing = try await client.checkUploadTarget(endpoint: endpoint, path: targetPath, name: file.name,
                                                                    encoding: targetEncoding, credentials: credentials, cancellation: cancellation)
                    try cancellation.checkCancellation()
                    guard id == uploadRequestID else { return }
                    guard try await matches(snapshot, cancellation: cancellation) else { throw FTPError.localFile("文件在目标检查期间发生变化，请重新选择或上传。") }
                    if let existing {
                        if existing.kind != .regularFile { throw FTPError.uploadTargetConflict }
                        pendingOverwrite = snapshot
                        pendingUploadJob = job
                        metrics.stop()
                        overwriteRequestID = snapshot.id
                        overwriteTarget = uploadTarget
                        uploadState = .awaitingOverwrite
                        return
                    }
                } else {
                    guard let authorization, try await matches(authorization, cancellation: cancellation) else {
                        throw FTPError.localFile("本次覆盖授权已失效，请重新检查目标。")
                    }
                }
                uploadState = .uploading
                try await files.run(job, preparing: {
                    job.uploadSource = try await file.verifiedSource(matching: authorization?.local ?? local, cancellation: cancellation)
                }, progress: { [weak self] sent, total in
                    Task { @MainActor [weak self] in
                        guard let self, self.uploadRequestID == id, self.isUploading, !cancellation.isCancelled else { return }
                        let nextSent = max(0, sent)
                        let nextTotal = max(0, total)
                        let nextState: UploadState = total == 0 || sent >= total ? .awaitingCompletion : .uploading
                        guard self.sent != nextSent || self.total != nextTotal || self.uploadState != nextState else { return }
                        if self.metrics.update(bytes: nextSent, total: nextTotal) {
                            self.sent = nextSent; self.total = nextTotal
                        }
                        self.uploadState = nextState
                    }
                })
                try cancellation.checkCancellation()
                guard id == uploadRequestID else { return }
                sent = total
                uploadState = .succeeded
                refresh()
            } catch {
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
        let context = CollectionPreparation(endpoint: endpoint, remoteRoot: path, encoding: encoding, credentials: credentials)
        collectionPreparation = context
        return collectionScan.start(operation: { [self] token in
            for url in urls {
                try token.checkCancellation()
                context.roots.append(try LocalSourceRoot(url: url, scope: rootScope))
            }
            let plan = try await LocalTransferScanner().scan(roots: context.roots, destination: context.remoteRoot,
                encoding: context.encoding, cancellation: token, discovered: { [weak self] count in
                    Task { @MainActor in self?.collectionScan.discovered(count, cancellationID: token.id) }
                })
            try token.checkCancellation()
            context.sources = Dictionary(uniqueKeysWithValues: zip(plan.roots.map(\.id), context.roots))
            guard plan.canStart else { return plan }
            return try await TransferRetryPlanner().inspectTargets(plan, client: client, endpoint: context.endpoint,
                credentials: context.credentials, destination: nil, cancellation: token)
        }, redact: { credentials.redacting($0) })
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
        let context = CollectionPreparation(endpoint: endpoint, remoteRoot: path, encoding: encoding, credentials: credentials)
        collectionPreparation = context
        return collectionScan.start(operation: { [self] token in
            try token.checkCancellation()
            let root = try LocalDestinationRoot(url: destination, scope: rootScope)
            context.destination = root
            let plan = try await RemoteTransferScanner(client: client).scan(endpoint: context.endpoint, selections: selections,
                destination: root, credentials: context.credentials, cancellation: token, discovered: { [weak self] count in
                    Task { @MainActor in self?.collectionScan.discovered(count, cancellationID: token.id) }
                })
            guard plan.canStart else { return plan }
            return try await TransferRetryPlanner().inspectTargets(plan, client: client, endpoint: context.endpoint,
                credentials: context.credentials, destination: root, cancellation: token)
        }, redact: { credentials.redacting($0) })
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
              let origin = retryOrigin(itemID: itemID, batchID: batchID),
              let request = origin.beginCollectionRetry(itemID: itemID) else { return false }
        let credentials: FTPCredentials
        if let fixed = request.fixedCredentials { credentials = fixed }
        else {
            // Finished plans retain targets, not authentication. Never send old targets to a different server.
            guard endpoint == request.endpoint, let current = newCollectionCredentials() else {
                origin.endCollectionRetry(); return false
            }
            credentials = current
        }
        let context = CollectionPreparation(endpoint: request.endpoint, remoteRoot: request.remoteRoot,
            encoding: request.encoding, credentials: credentials)
        context.isRetry = true; context.retryOrigin = origin
        let holdID = UUID(); context.retryHoldID = holdID
        context.heldQueues = sessionQueues.filter { $0 !== origin && $0.state == .paused }
        context.heldQueues.forEach { $0.holdForRetry(holdID) }
        collectionPreparation = context
        let started = collectionScan.start(operation: { [self] token in
            let plan = TransferRetryPlanner.remap(request.plan)
            if plan.direction == .upload {
                for root in plan.roots {
                    try token.checkCancellation()
                    guard case .local(let url) = root.source else { throw FTPError.invalidName }
                    let access = try LocalSourceRoot(url: url, scope: rootScope)
                    context.roots.append(access); context.sources[root.id] = access
                    guard access.identity.kind == root.kind else { throw FTPError.localFile("重试来源根类型变化。") }
                }
                let result = try await TransferRetryPlanner().upload(plan, sources: context.sources, cancellation: token)
                return try await TransferRetryPlanner().inspectTargets(result, client: client, endpoint: context.endpoint,
                    credentials: context.credentials, destination: nil, cancellation: token)
            }
            guard let url = request.destinationURL else { throw FTPError.localFile("重试目的根丢失。") }
            let destination = try LocalDestinationRoot(url: url, scope: rootScope)
            context.destination = destination
            let lease = try destination.lease()
            defer { withExtendedLifetime(lease) {} }
            let result = try await TransferRetryPlanner().download(plan, client: client, endpoint: context.endpoint,
                credentials: context.credentials, cancellation: token)
            let checked = try await TransferRetryPlanner().inspectTargets(result, client: client, endpoint: context.endpoint,
                credentials: context.credentials, destination: destination, cancellation: token)
            try destination.validateIdentity()
            return checked
        }, redact: { credentials.redacting($0) })
        if !started {
            context.release(); collectionPreparation = nil; context.endRetryPreparation()
        }
        return started
    }

    @discardableResult
    func confirmCollection(_ planID: UUID, policy: TransferConflictPolicy = .ask) -> Bool {
        guard collectionScan.phase == .preview, let plan = collectionScan.plan, plan.id == planID,
              plan.canStart, let context = collectionPreparation else { return false }
        let queue = context.isRetry ? BatchTransferQueue(client: client, executor: transferExecutor) : batch
        guard !queue.isLocked, !context.isRetry || context.retryOrigin?.retryPending == true else { return false }
        do {
            try queue.prepare(plan: plan, endpoint: context.endpoint, remoteRoot: context.remoteRoot,
                encoding: context.encoding, credentials: context.credentials, sources: context.sources, destination: context.destination)
        } catch { selectionError = context.credentials.redacting(error.localizedDescription); return false }
        guard queue.chooseConflictPolicy(policy, planID: planID), collectionScan.consume(planID: planID) else { return false }
        collectionPreparation = nil // Queue now owns roots and the fixed authentication context.
        if context.isRetry {
            let origin = context.retryOrigin!, holdID = context.retryHoldID!, held = context.heldQueues
            origin.acceptCollectionRetry()
            retryBatch = queue; retryBatches.append(queue)
            retryObservation = queue.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            queue.onHistoryRecord = { [weak self] record in self?.history.record(record) }
            queue.onStart = { [weak self] total in self?.metrics.reset(total: total) }
            queue.onProgress = { [weak self] _, bytes, total in self?.metrics.update(bytes: bytes, total: total) ?? false }
            queue.onFinish = { [weak self] _, _, _ in self?.metrics.stop() }
            queue.onEnd = { [weak self, weak queue] in
                origin.endCollectionRetry()
                held.forEach { $0.releaseRetryHold(holdID) }
                if origin !== self?.batch, origin.state == .paused, self?.retryBatch === queue {
                    self?.retryBatch = origin
                    self?.retryObservation = origin.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
                }
            }
        }
        else {
            retryBatches = []; retryObservation = nil
            retryBatch = BatchTransferQueue(client: client, executor: transferExecutor)
        }
        queue.startOrContinue()
        return true
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
            sink = try LocalDownload(destination: destination, authorizedIdentity: authorizedIdentity)
        } catch { downloadState = .failed(error.localizedDescription); return }
        let token = FTPCancellationToken()
        downloadCancellation = token
        downloadCleanupError = nil
        downloadConfirmationID = nil
        downloadName = entry.name
        downloadTarget = endpoint.display + remote.display + " → " + destination.path
        downloadBytes = 0; downloadTotal = entry.size ?? -1; downloadState = .uploading
        let job = TransferJob(direction: .download, endpoint: endpoint, path: remote, encoding: encoding,
                              credentials: credentials, localURL: destination, cancellation: token, name: entry.name)
        metrics.reset(total: downloadTotal)
        Task {
            defer { history.record(job, target: downloadTarget ?? "", bytes: sink.byteCount); metrics.stop() }
            do {
                try await files.run(job, receive: sink.receive, finalizing: {
                    try sink.closeFile()
                    // A newly created target needs a separate confirmation after reception.
                    do { try sink.commit() }
                    catch LocalDownload.CommitError.confirmationRequired {
                        pendingDownload = sink; downloadConfirmationID = job.id
                        downloadState = .awaitingOverwrite
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            downloadCommitContinuation = continuation
                        }
                    }
                }, progress: { [weak self] bytes, total in
                    Task { @MainActor [weak self] in
                        guard let self, self.downloadCancellation === token, !token.isCancelled, [.uploading, .awaitingCompletion].contains(self.downloadState) else { return }
                        if self.metrics.update(bytes: bytes, total: total) {
                            self.downloadBytes = max(self.downloadBytes, bytes)
                            if total >= 0 { self.downloadTotal = total }
                        }
                        self.downloadState = total >= 0 && bytes >= total ? .awaitingCompletion : .uploading
                    }
                })
                downloadBytes = sink.byteCount
                downloadState = .succeeded; downloadCancellation = nil
            } catch {
                var message = credentials.redacting(error.localizedDescription)
                do { try sink.cleanUp() } catch { downloadCleanupError = error.localizedDescription; message += " " + error.localizedDescription }
                if token.isCancelled || error is CancellationError { downloadState = .cancelled }
                else { downloadState = .failed(message) }
                if case HostTrustError.changed(let identity) = error { changedHost = identity }
                downloadCancellation = nil
            }
        }
    }

    func confirmDownloadCommit(_ id: UUID) {
        guard downloadConfirmationID == id, let sink = pendingDownload,
              let continuation = downloadCommitContinuation else { return }
        downloadCommitContinuation = nil; pendingDownload = nil; downloadConfirmationID = nil
        do { try sink.authorizeCurrentTarget(); try sink.commit(); continuation.resume() }
        catch { continuation.resume(throwing: error) }
    }

    func cancelDownloadConfirmation() {
        guard let continuation = downloadCommitContinuation else { return }
        downloadCancellation?.cancel()
        downloadCommitContinuation = nil; pendingDownload = nil; downloadConfirmationID = nil
        downloadState = .cancelling
        continuation.resume(throwing: CancellationError())
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
        sent = 0
        total = 0
    }
}
