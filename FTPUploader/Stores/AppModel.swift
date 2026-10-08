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
            let hadPassword = password != nil
            updatingDraft = true
            password = nil
            if transport == .sftp { loginMode = .account; encodingPolicy = .utf8 }
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
    @Published private(set) var downloadCleanupError: String?
    @Published private(set) var downloadBytes: Int64 = 0
    @Published private(set) var downloadTotal: Int64 = -1
    @Published private(set) var downloadConfirmationID: UUID?
    private var downloadCancellation: FTPCancellationToken?
    private var pendingDownload: LocalDownload?
    private var downloadCommitContinuation: CheckedContinuation<Void, Error>?
    private let executor: TransferExecutor
    let batch: BatchTransferQueue
    let history: TransferHistory
    let metrics = TransferMetricsMonitor()
    private var historyObservation: AnyCancellable?
    private var metricsObservation: AnyCancellable?
    private var batchObservation: AnyCancellable?
    private let client: FTPServing
    private var encoding = FTPTextEncoding.utf8
    private var directoryRequestID = 0
    private var uploadRequestID = 0
    private var draftVersion = 0
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

    private func matches(_ snapshot: UploadSnapshot) throws -> Bool {
        guard snapshot.version == draftVersion, snapshot.endpoint == endpoint,
              snapshot.path == path, snapshot.encoding == encoding,
              snapshot.file === selectedFile, let credentials = activeCredentials,
              snapshot.credentials.mode == credentials.mode, snapshot.credentials.username == credentials.username,
              snapshot.credentials.password == credentials.password else { return false }
        return try snapshot.file.snapshot() == snapshot.local
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
        defer { if !isUploading { snapshot.file.endAccess() } }
        do {
            if try matches(snapshot) { startUpload(authorization: snapshot, existingJob: job) }
            else {
                job.finish(.cancelled); history.record(job, target: uploadTarget ?? "", bytes: 0)
                upload()
            } // Changed local data requires a fresh check and confirmation.
        } catch {
            job.finish(.failed(job.credentials.redacting(error.localizedDescription)))
            history.record(job, target: uploadTarget ?? "", bytes: 0)
            uploadState = .failed(job.credentials.redacting(error.localizedDescription))
        }
    }

    init(client: FTPServing = FTPClient(), sites: SiteManager? = nil, history: TransferHistory? = nil) {
        self.client = client; self.sites = sites ?? SiteManager()
        let executor = TransferExecutor(); self.executor = executor
        batch = BatchTransferQueue(client: client, executor: executor)
        self.history = history ?? TransferHistory()
        batch.onFinish = { [weak self] job, target, bytes in
            self?.history.record(job, target: target, bytes: bytes)
            if self?.batch.isExecuting == false { self?.metrics.stop() }
        }
        batch.onStart = { [weak self] total in self?.metrics.reset(total: total) }
        batch.onProgress = { [weak self] _, bytes, total in self?.metrics.update(bytes: bytes, total: total) ?? false }
        historyObservation = self.history.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        metricsObservation = metrics.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        batchObservation = batch.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var isUploading: Bool { uploadState == .checkingTarget || uploadState == .uploading || uploadState == .awaitingCompletion || uploadState == .cancelling }
    var isDownloading: Bool { [.checkingTarget, .uploading, .awaitingCompletion, .cancelling, .awaitingOverwrite].contains(downloadState) }
    var isBusy: Bool { isDirectoryLoading || isUploading || isDownloading || isSiteOperationBusy || batch.isLocked }
    var canEditConnection: Bool { !isBusy }
    var canCancel: Bool { (isDirectoryLoading && !isDirectoryCancelling) || (isUploading && uploadState != .cancelling) || (isDownloading && downloadState != .cancelling) || batch.isExecuting }

    var cancellationID: UUID? {
        isDirectoryLoading ? directoryCancellation?.id : (isUploading ? uploadCancellation?.id : (downloadCancellation?.id ?? batch.cancellationID))
    }

    func cancelOperation(id: UUID? = nil) {
        if let id, id != cancellationID { return }
        if isDirectoryLoading, !isDirectoryCancelling {
            isDirectoryCancelling = true
            directoryCancellation?.cancel()
        } else if batch.isExecuting {
            batch.cancelCurrent()
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
    var canConnect: Bool {
        canEditConnection && !isPasswordLoading && !isDirectoryLoading
            && !address.trimmingCharacters(in: .whitespaces).isEmpty
    }
    var connectionIdentity: String {
        guard let credentials = activeCredentials, let endpoint else { return transport.title }
        return endpoint.transport.title + (credentials.mode == .anonymous ? " · 匿名访问" : " · 账户：\(credentials.username)")
    }
    var canChooseFile: Bool { hasDirectory && !isBusy }
    var canUpload: Bool { canChooseFile && selectedFile != nil && uploadState != .awaitingOverwrite }
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
        selectedSiteID = id
        updatingDraft = true
        defer { updatingDraft = false }
        if let site = sites.sites.first(where: { $0.id == id }) {
            transport = site.transport
            encodingPolicy = site.encodingPolicy
            address = site.address; loginMode = site.loginMode; username = site.username; password = nil
            if site.rememberPassword { loadPassword(site) }
        } else { transport = .ftp; encodingPolicy = .automatic; address = ""; loginMode = .anonymous; username = ""; password = nil }
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
                if cancellation.isCancelled || error is CancellationError {
                    directoryCancelled = true
                } else {
                    if case HostTrustError.unknown(let identity) = error {
                        hostTrustRequest = identity; hostTrustVersion = draftVersion
                    } else if case HostTrustError.changed(let identity) = error {
                        changedHost = identity
                    }
                    directoryError = credentials.redacting(error.localizedDescription)
                }
            }
        }
    }

    @discardableResult
    func selectDroppedFiles(_ urls: [URL]) -> Bool {
        guard canChooseFile else { return false }
        guard urls.count == 1 else {
            selectionError = "每次只能上传一个文件。"
            return false
        }
        selectFile(urls[0])
        return selectionError == nil
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
        let snapshot: UploadSnapshot
        do {
            try file.beginAccessAndValidate()
            _ = try endpoint.fileURL(targetPath, name: file.name, encoding: targetEncoding)
            snapshot = UploadSnapshot(version: draftVersion, endpoint: endpoint, path: targetPath,
                                      credentials: credentials, encoding: targetEncoding, file: file, local: try file.snapshot())
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
                if authorization == nil {
                    let existing = try await client.checkUploadTarget(endpoint: endpoint, path: targetPath, name: file.name,
                                                                    encoding: targetEncoding, credentials: credentials, cancellation: cancellation)
                    try cancellation.checkCancellation()
                    guard id == uploadRequestID else { return }
                    guard try matches(snapshot) else { throw FTPError.localFile("文件在目标检查期间发生变化，请重新选择或上传。") }
                    if let existing {
                        if existing.isDirectory { throw FTPError.uploadTargetConflict }
                        pendingOverwrite = snapshot
                        pendingUploadJob = job
                        metrics.stop()
                        overwriteRequestID = snapshot.id
                        overwriteTarget = uploadTarget
                        uploadState = .awaitingOverwrite
                        return
                    }
                } else {
                    guard let authorization, try matches(authorization) else {
                        throw FTPError.localFile("本次覆盖授权已失效，请重新检查目标。")
                    }
                }
                uploadState = .uploading
                try await executor.execute(job) {
                try await client.upload(endpoint: job.endpoint, path: job.path, file: job.localURL, encoding: job.encoding, credentials: job.credentials, cancellation: job.cancellation) { [weak self] sent, total in
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
                }
                }
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

    func prepareBatch(_ urls: [URL]) {
        guard canChooseFile, let endpoint, let credentials = activeCredentials else { return }
        do { try batch.prepare(urls, endpoint: endpoint, path: path, encoding: encoding, credentials: credentials) }
        catch { selectionError = error.localizedDescription }
    }

    func downloadSelectionFailed(_ error: Error) { downloadState = .failed(error.localizedDescription) }

    func download(_ entry: RemoteEntry, to destination: URL, authorizedIdentity: LocalDownload.Identity? = nil) {
        guard hasDirectory, !isBusy, !entry.isDirectory, entries.contains(entry),
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
        downloadTarget = endpoint.display + remote.display + " → " + destination.path
        downloadBytes = 0; downloadTotal = entry.size ?? -1; downloadState = .uploading
        let job = TransferJob(direction: .download, endpoint: endpoint, path: remote, encoding: encoding,
                              credentials: credentials, localURL: destination, cancellation: token, name: entry.name)
        metrics.reset(total: downloadTotal)
        Task {
            defer { history.record(job, target: downloadTarget ?? "", bytes: sink.byteCount); metrics.stop() }
            do {
                try await executor.execute(job) {
                    try await client.download(endpoint: job.endpoint, path: job.path, credentials: job.credentials,
                                              cancellation: token, receive: sink.receive) { [weak self] bytes, total in
                        Task { @MainActor in
                            guard let self, self.downloadCancellation === token, !token.isCancelled, [.uploading, .awaitingCompletion].contains(self.downloadState) else { return }
                            if self.metrics.update(bytes: bytes, total: total) {
                                self.downloadBytes = max(self.downloadBytes, bytes)
                                if total >= 0 { self.downloadTotal = total }
                            }
                            self.downloadState = total >= 0 && bytes >= total ? .awaitingCompletion : .uploading
                        }
                    }
                    try token.checkCancellation()
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
                }
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
