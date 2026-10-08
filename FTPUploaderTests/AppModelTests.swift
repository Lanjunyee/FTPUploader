import XCTest

@MainActor
private func isolatedHistory() -> TransferHistory {
    TransferHistory(url: FileManager.default.temporaryDirectory.appendingPathComponent("transfer-test-" + UUID().uuidString).appendingPathComponent("history.json"))
}

@MainActor
private final class ControlledFTP: FTPServing {
    struct BrowseRequest {
        let endpoint: FTPEndpoint
        let path: RemotePath
        let credentials: FTPCredentials
        let cancellation: FTPCancellationToken
        let continuation: CheckedContinuation<DirectoryListing, Error>
    }
    struct UploadRequest {
        let endpoint: FTPEndpoint
        let path: RemotePath
        let credentials: FTPCredentials
        let cancellation: FTPCancellationToken
        let progress: (Int64, Int64) -> Void
        let continuation: CheckedContinuation<Void, Error>
    }
    struct DownloadRequest {
        let path: RemotePath
        let credentials: FTPCredentials
        let cancellation: FTPCancellationToken
        let receive: (Data) throws -> Void
        let progress: (Int64, Int64) -> Void
        let continuation: CheckedContinuation<Void, Error>
    }
    var downloads: [DownloadRequest] = []
    func download(endpoint: FTPEndpoint, path: RemotePath, credentials: FTPCredentials, cancellation: FTPCancellationToken,
                  receive: @escaping (Data) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws {
        try await withCheckedThrowingContinuation {
            downloads.append(DownloadRequest(path: path, credentials: credentials, cancellation: cancellation,
                                              receive: receive, progress: progress, continuation: $0))
        }
    }
    var browses: [BrowseRequest] = []
    var uploads: [UploadRequest] = []
    var autoCheckTargets = true

    func checkUploadTarget(endpoint: FTPEndpoint, path: RemotePath, name: String, encoding: FTPTextEncoding,
                           credentials: FTPCredentials, cancellation: FTPCancellationToken) async throws -> RemoteEntry? {
        if autoCheckTargets { return nil }
        let listing = try await list(endpoint: endpoint, path: path, encoding: encoding, credentials: credentials, cancellation: cancellation)
        try cancellation.checkCancellation()
        let bytes = try encoding.encode(name)
        return listing.entries.first { $0.rawName == bytes }
    }
    func list(endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding?, credentials: FTPCredentials, cancellation: FTPCancellationToken) async throws -> DirectoryListing {
        return try await withCheckedThrowingContinuation {
            browses.append(BrowseRequest(endpoint: endpoint, path: path, credentials: credentials, cancellation: cancellation, continuation: $0))
        }
    }
    func upload(endpoint: FTPEndpoint, path: RemotePath, file: URL, encoding: FTPTextEncoding, credentials: FTPCredentials, cancellation: FTPCancellationToken,
                progress: @escaping (Int64, Int64) -> Void) async throws {
        try await withCheckedThrowingContinuation {
            uploads.append(UploadRequest(endpoint: endpoint, path: path, credentials: credentials, cancellation: cancellation, progress: progress, continuation: $0))
        }
    }
}

private final class InMemorySites: SiteStoring {
    var sites: [FTPSite]
    init(_ sites: [FTPSite] = []) { self.sites = sites }
    func load() throws -> [FTPSite] { sites }
    func save(_ sites: [FTPSite]) throws { self.sites = sites }
}

@MainActor
private final class DelayedPasswords: PasswordStoring {
    var reads: [(UUID, CheckedContinuation<String?, Error>)] = []
    func password(for site: FTPSite) async throws -> String? {
        try await withCheckedThrowingContinuation { reads.append((site.id, $0)) }
    }
    func save(_ password: String, for site: FTPSite) async throws {}
    func remove(id: UUID) async throws {}
}

@MainActor
final class SiteStateTests: XCTestCase {
    private func settle(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition())
    }

    private func site(username: String, remember: Bool = false) throws -> FTPSite {
        var d = SiteDraft(); d.host = "same.example"; d.loginMode = .account
        d.username = username; d.rememberPassword = remember
        return try d.configuration()
    }

    func testSelectedSiteDoesNotConnectAndLateDirectoryIsIgnored() async throws {
        let first = try site(username: "first"); let second = try site(username: "second")
        let fake = ControlledFTP()
        let model = AppModel(client: fake, sites: SiteManager(store: InMemorySites([first, second]), passwords: DelayedPasswords()), history: isolatedHistory())
        model.selectSite(first.id)
        XCTAssertTrue(fake.browses.isEmpty)
        model.password = "one"; model.connect()
        try await settle { fake.browses.count == 1 }
        XCTAssertEqual(fake.browses[0].credentials.username, "first")
        model.cancelOperation()
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await settle { !model.isDirectoryLoading }
        model.selectSite(second.id)
        XCTAssertFalse(model.hasDirectory); XCTAssertFalse(model.canUpload)
        XCTAssertNil(model.password)
        model.password = "two"; model.connect()
        try await settle { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await settle { model.hasDirectory }
        XCTAssertEqual(model.connectionIdentity, "FTP（不加密） · 账户：second")
        model.refresh()
        try await settle { fake.browses.count == 3 }
        XCTAssertEqual(fake.browses[2].credentials.password, "two")
        fake.browses[2].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await settle { !model.isDirectoryLoading }
        model.username = "third"
        XCTAssertFalse(model.hasDirectory); XCTAssertNil(model.password)
    }

    func testLatePasswordCannotOverwriteAnotherSiteOrManualInput() async throws {
        let first = try site(username: "first", remember: true)
        let second = try site(username: "second", remember: true)
        let passwords = DelayedPasswords()
        let model = AppModel(client: ControlledFTP(), sites: SiteManager(store: InMemorySites([first, second]), passwords: passwords), history: isolatedHistory())
        model.selectSite(first.id)
        try await settle { passwords.reads.count == 1 }
        model.selectSite(second.id)
        try await settle { passwords.reads.count == 2 }
        passwords.reads[1].1.resume(returning: "second-password")
        try await settle { !model.isPasswordLoading }
        passwords.reads[0].1.resume(returning: "first-password")
        await Task.yield()
        XCTAssertEqual(model.password, "second-password")
        model.selectSite(first.id)
        try await settle { passwords.reads.count == 3 }
        model.password = "manual"
        passwords.reads[2].1.resume(returning: "saved")
        await Task.yield()
        XCTAssertEqual(model.password, "manual")
    }

    func testAccountUploadSnapshotAndAllMutationEntrypointsAreLocked() async throws {
        let first = try site(username: "first")
        let fake = ControlledFTP()
        let manager = SiteManager(store: InMemorySites([first]), passwords: DelayedPasswords())
        let model = AppModel(client: fake, sites: manager, history: isolatedHistory())
        model.selectSite(first.id); model.password = "one"; model.connect()
        try await settle { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await settle { model.hasDirectory }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("bytes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        model.selectFile(file); model.upload(); model.upload()
        model.selectSite(nil); model.username = "other"; model.password = "other"; model.address = "other.example"
        model.loginMode = .anonymous
        let saved = await model.saveSite(SiteDraft(site: first)); XCTAssertFalse(saved)
        let deleted = await model.deleteSite(first); XCTAssertFalse(deleted)
        try await settle { fake.uploads.count == 1 }
        XCTAssertEqual(model.selectedSiteID, first.id); XCTAssertEqual(model.username, "first")
        XCTAssertEqual(model.password, "one"); XCTAssertEqual(model.loginMode, .account)
        XCTAssertEqual(fake.uploads[0].credentials.password, "one")
        fake.uploads[0].continuation.resume()
        try await settle { fake.browses.count == 2 }
        XCTAssertEqual(fake.browses[1].credentials.username, "first")
        fake.browses[1].continuation.resume(throwing: FTPError.incompatibleListing)
        try await settle { !model.isDirectoryLoading }
        XCTAssertEqual(model.uploadState, .succeeded)
    }

    func testSaveAndDeleteCurrentSiteNeverIssueNetworkCommands() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, sites: SiteManager(store: InMemorySites(), passwords: DelayedPasswords()), history: isolatedHistory())
        var draft = SiteDraft(); draft.host = "example.test"
        XCTAssertTrue(model.sites.sites.isEmpty)
        let saved = await model.saveSite(draft); XCTAssertTrue(saved)
        XCTAssertTrue(fake.browses.isEmpty)
        XCTAssertEqual(model.address, model.sites.sites[0].address)
        let deleted = await model.deleteSite(model.sites.sites[0]); XCTAssertTrue(deleted)
        XCTAssertTrue(model.sites.sites.isEmpty); XCTAssertNil(model.selectedSiteID)
        XCTAssertFalse(model.hasDirectory); XCTAssertTrue(fake.browses.isEmpty); XCTAssertTrue(fake.uploads.isEmpty)
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    private let destination = RemoteEntry(name: "共享", rawName: Data("共享".utf8), isDirectory: true, size: nil)

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition(), "State did not settle")
    }

    private func connect(_ model: AppModel, _ fake: ControlledFTP) async throws {
        model.address = "first.example"
        model.connect()
        try await waitUntil { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [destination], encoding: .utf8))
        try await waitUntil { model.hasDirectory }
    }

    func testRefreshAndNavigationFailureKeepConsistentTarget() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        try await connect(model, fake)
        model.enter(destination)
        XCTAssertTrue(model.isDirectoryLoading)
        XCTAssertFalse(model.canChooseFile)
        try await waitUntil { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(throwing: FTPError.transport(code: 9, response: 550, message: "Denied", upload: false))
        try await waitUntil { !model.isDirectoryLoading }
        XCTAssertEqual(model.path, .root)
        XCTAssertEqual(model.entries, [destination])
        XCTAssertNotNil(model.directoryError)
        XCTAssertTrue(model.canChooseFile)
        model.refresh()
        XCTAssertFalse(model.canChooseFile)
        try await waitUntil { fake.browses.count == 3 }
        fake.browses[2].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { !model.isDirectoryLoading }
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testOldServerResultCannotReplaceNewConnection() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        model.address = "old.example"; model.connect()
        try await waitUntil { fake.browses.count == 1 }
        model.cancelOperation()
        model.address = "new.example"; model.connect()
        XCTAssertEqual(model.address, "old.example")
        XCTAssertTrue(model.isBusy)
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [destination], encoding: .utf8))
        try await waitUntil { !model.isBusy }
        XCTAssertTrue(model.directoryCancelled); XCTAssertFalse(model.hasDirectory)
        model.address = "new.example"; model.connect()
        try await waitUntil { fake.browses.count == 2 }
        fake.browses[0].cancellation.cancel()
        XCTAssertFalse(fake.browses[1].cancellation.isCancelled)
        fake.browses[1].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { model.hasDirectory }
        XCTAssertEqual(model.endpoint?.host, "new.example")
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testRepeatedConnectWhileLoadingIssuesOneRequestAndRetriesAfter() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        model.address = "first.example"
        model.connect()
        try await waitUntil { fake.browses.count == 1 }
        XCTAssertFalse(model.canConnect, "Connecting must be unavailable while the directory is loading")
        model.connect()
        model.connect()
        await Task.yield()
        XCTAssertEqual(fake.browses.count, 1, "Repeat submits must not issue another request")
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { model.hasDirectory }
        XCTAssertTrue(model.canConnect, "A finished request restores connecting")
        model.connect()
        try await waitUntil { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(throwing: FTPError.transport(code: 9, response: 550, message: "Denied", upload: false))
        try await waitUntil { !model.isDirectoryLoading }
        XCTAssertTrue(model.canConnect, "A failed request also restores connecting")
        model.connect()
        try await waitUntil { fake.browses.count == 3 }
        fake.browses[2].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { !model.isDirectoryLoading }
    }

    func testReconnectIsRejectedWhileLoadingWithoutTouchingTheDraft() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        model.address = "first.example"
        model.connect()
        try await waitUntil { fake.browses.count == 1 }
        XCTAssertFalse(model.reconnect(to: "second.example"))
        XCTAssertEqual(model.address, "first.example")
        await Task.yield()
        XCTAssertEqual(fake.browses.count, 1)
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { model.hasDirectory }
        XCTAssertTrue(model.reconnect(to: "second.example"))
        try await waitUntil { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { model.hasDirectory && model.endpoint?.host == "second.example" }
    }

    func testIdentityChangeRequiresANewPasswordWithoutClaimingFirstEmptyInput() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        model.address = "first.example"
        model.loginMode = .account
        XCTAssertFalse(model.identityChangedNotice, "An empty first form must not claim a cleared password")
        model.username = "member"
        model.password = "top-secret"
        XCTAssertFalse(model.identityChangedNotice)
        model.username = "other"
        XCTAssertNil(model.password, "The old password must not be reused for a new identity")
        XCTAssertTrue(model.identityChangedNotice)
        model.username = "otherx"
        XCTAssertTrue(model.identityChangedNotice, "Typing each character must not clear the requirement")
        model.password = "second"
        XCTAssertFalse(model.identityChangedNotice)
        model.address = "second.example"
        XCTAssertTrue(model.identityChangedNotice)
        model.password = ""
        XCTAssertFalse(model.identityChangedNotice, "An explicit empty password satisfies the prompt")
    }

    func testLocalFieldFailureDoesNotReachNetworkOrLookLikeDirectoryError() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        model.address = "ftp://host:70000"
        model.connect()
        await Task.yield()
        XCTAssertTrue(fake.browses.isEmpty)
        XCTAssertFalse(model.hasDirectory)
        XCTAssertNil(model.directoryError, "A local field problem must not read as a directory failure")
        XCTAssertEqual(model.fieldIssue?.field, .address)
        XCTAssertTrue(model.fieldIssue?.message.contains("端口") == true)
        model.address = "first.example"
        XCTAssertNil(model.fieldIssue, "Editing the field clears its stale reason")
        model.connect()
        try await waitUntil { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { model.hasDirectory }
        XCTAssertNil(model.fieldIssue)
    }

    func testMissingAccountFieldsReportTheirFieldAndCorrectingConnects() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        model.address = "first.example"
        model.loginMode = .account
        model.connect()
        await Task.yield()
        XCTAssertTrue(fake.browses.isEmpty)
        XCTAssertEqual(model.fieldIssue?.field, .username)
        XCTAssertNil(model.directoryError)
        model.username = "member"
        XCTAssertNil(model.fieldIssue)
        model.connect()
        await Task.yield()
        XCTAssertTrue(fake.browses.isEmpty)
        XCTAssertEqual(model.fieldIssue?.field, .password)
        model.password = "secret"
        model.connect()
        try await waitUntil { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { model.hasDirectory }
        XCTAssertNil(model.fieldIssue)
    }

    func testServerRejectionStaysADirectoryErrorWithRedactedDetail() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        model.address = "first.example"
        model.loginMode = .account
        model.username = "member"; model.password = "secret"
        model.connect()
        try await waitUntil { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(throwing: FTPError.transport(code: 9, response: 530, message: "bad secret", upload: false, mode: .account))
        try await waitUntil { !model.isDirectoryLoading }
        XCTAssertNil(model.fieldIssue)
        let detail = try XCTUnwrap(model.directoryError)
        XCTAssertTrue(detail.contains("530"))
        XCTAssertFalse(detail.contains("secret"))
    }

    func testInvalidReconnectKeepsDirectoryDraftAndPopoverState() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        try await connect(model, fake)
        let location = model.currentLocation
        XCTAssertFalse(model.reconnect(to: "sftp://elsewhere"))
        XCTAssertEqual(model.currentLocation, location)
        XCTAssertTrue(model.hasDirectory)
        XCTAssertEqual(model.fieldIssue?.field, .address)
        XCTAssertNil(model.directoryError)
        XCTAssertTrue(fake.browses.isEmpty == false)
        let browses = fake.browses.count
        XCTAssertTrue(model.reconnect(to: "other.example"))
        try await waitUntil { fake.browses.count == browses + 1 }
        XCTAssertFalse(model.hasDirectory, "A new address invalidates the old directory until it loads")
        fake.browses[browses].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { model.hasDirectory }
    }

    func testUploadIsSingleAndWaitsForFinalConfirmation() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        try await connect(model, fake)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("example".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        model.selectFile(file)
        model.upload()
        model.upload()
        model.goUp()
        model.address = "other.example"
        model.connect()
        try await waitUntil { fake.uploads.count == 1 }
        XCTAssertEqual(fake.uploads[0].endpoint.host, "first.example")
        XCTAssertFalse(model.canChooseFile)
        fake.uploads[0].progress(7, 7)
        try await waitUntil { model.uploadState == .awaitingCompletion }
        XCTAssertNotEqual(model.uploadState, .succeeded)
        fake.uploads[0].continuation.resume(throwing: FTPError.transport(code: 18, response: 552, message: "Rejected", upload: true))
        try await waitUntil { !model.isUploading }
        if case .failed = model.uploadState {} else { XCTFail("Expected failed state") }
        XCTAssertTrue(model.canUpload)
        model.upload()
        try await waitUntil { fake.uploads.count == 2 }
        XCTAssertEqual(model.sent, 0)
        fake.uploads[1].continuation.resume()
        try await waitUntil { model.uploadState == .succeeded && fake.browses.count == 2 }
        fake.browses[1].continuation.resume(throwing: FTPError.incompatibleListing)
        try await waitUntil { !model.isDirectoryLoading }
        XCTAssertEqual(model.uploadState, .succeeded, "Refresh must not undo confirmed success")
        fake.uploads[0].progress(0, 7)
        await Task.yield()
        XCTAssertEqual(model.uploadState, .succeeded)
    }

    func testCancelBeforeSuccessIgnoresLateProgressAndReleasesAccessAfterStop() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        try await connect(model, fake)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("bytes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        model.selectFile(file); model.upload()
        try await waitUntil { fake.uploads.count == 1 }
        let selected = try XCTUnwrap(model.selectedFile)
        XCTAssertTrue(selected.isAccessActive)
        model.cancelOperation(); model.cancelOperation()
        XCTAssertEqual(model.uploadState, .cancelling)
        XCTAssertTrue(model.isBusy); XCTAssertFalse(model.canChooseFile)
        XCTAssertTrue(fake.uploads[0].cancellation.isCancelled)
        fake.uploads[0].progress(5, 5)
        await Task.yield()
        XCTAssertEqual(model.uploadState, .cancelling); XCTAssertEqual(model.sent, 0)
        XCTAssertTrue(selected.isAccessActive)
        fake.uploads[0].continuation.resume()
        try await waitUntil { model.uploadState == .cancelled }
        XCTAssertFalse(selected.isAccessActive)
        XCTAssertTrue(model.canUpload)
        XCTAssertEqual(fake.browses.count, 1, "Cancelled success must not refresh")
        model.upload()
        try await waitUntil { fake.uploads.count == 2 }
        fake.uploads[0].progress(5, 5)
        fake.uploads[0].cancellation.cancel()
        await Task.yield()
        XCTAssertEqual(model.sent, 0)
        XCTAssertFalse(fake.uploads[1].cancellation.isCancelled)
        fake.uploads[1].continuation.resume(throwing: CancellationError())
        try await waitUntil { !model.isBusy }
        XCTAssertFalse(selected.isAccessActive)
    }

    func testCommittedSuccessSurvivesLaterCancelAndDirectoryCancelKeepsTarget() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        try await connect(model, fake)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("bytes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        model.selectFile(file); model.upload()
        try await waitUntil { fake.uploads.count == 1 }
        fake.uploads[0].continuation.resume()
        try await waitUntil { model.uploadState == .succeeded && fake.browses.count == 2 }
        model.cancelOperation()
        XCTAssertEqual(model.uploadState, .succeeded)
        XCTAssertTrue(model.isDirectoryCancelling)
        XCTAssertFalse(fake.uploads[0].cancellation.isCancelled)
        fake.browses[1].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { !model.isBusy }
        XCTAssertEqual(model.entries, [destination]); XCTAssertEqual(model.path, .root)
        XCTAssertTrue(model.directoryCancelled)
        model.cancelOperation()
        XCTAssertEqual(model.uploadState, .succeeded)
    }

    func testPreflightFailureDirectoryAndCancelledCheckNeverUpload() async throws {
        for result in ["directory", "file", "denied", "cancelled", "new"] {
            let fake = ControlledFTP(); fake.autoCheckTargets = false
            let model = AppModel(client: fake, history: isolatedHistory())
            try await connect(model, fake)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("bytes".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            model.selectFile(file); model.upload()
            try await waitUntil { fake.browses.count == 2 }
            XCTAssertEqual(model.uploadState, .checkingTarget)
            if result == "denied" { fake.browses[1].continuation.resume(throwing: FTPError.incompatibleListing) }
            else {
                if result == "cancelled" { model.cancelOperation() }
                let entry = RemoteEntry(name: file.lastPathComponent, rawName: Data(file.lastPathComponent.utf8), isDirectory: result == "directory", size: 5)
                fake.browses[1].continuation.resume(returning: DirectoryListing(entries: result == "new" ? [] : [entry], encoding: .utf8))
            }
            if result == "new" {
                try await waitUntil { fake.uploads.count == 1 }
                fake.uploads[0].continuation.resume(throwing: FTPError.incompatibleListing)
            }
            try await waitUntil { !model.isUploading }
            if result != "new" { XCTAssertTrue(fake.uploads.isEmpty) }
            if result == "file" { XCTAssertEqual(model.uploadState, .awaitingOverwrite); XCTAssertNotNil(model.overwriteTarget) }
            if result == "directory", case .failed(let message) = model.uploadState { XCTAssertTrue(message.contains("同名目录")) }
            if result == "cancelled" { XCTAssertEqual(model.uploadState, .cancelled) }
            XCTAssertFalse(try XCTUnwrap(model.selectedFile).isAccessActive)
        }
    }

    func testOverwriteCancelDefaultAndConfirmedServerRejection() async throws {
        let fake = ControlledFTP(); fake.autoCheckTargets = false
        let model = AppModel(client: fake, history: isolatedHistory())
        try await connect(model, fake)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("bytes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let entry = RemoteEntry(name: file.lastPathComponent, rawName: Data(file.lastPathComponent.utf8), isDirectory: false, size: 5)
        for attempt in 0..<2 {
            model.selectFile(file); model.upload()
            try await waitUntil { fake.browses.count == attempt + 2 }
            fake.browses[attempt + 1].continuation.resume(returning: DirectoryListing(entries: [entry], encoding: .utf8))
            try await waitUntil { model.overwriteRequestID != nil }
            let id = try XCTUnwrap(model.overwriteRequestID)
            XCTAssertFalse(model.canUpload); XCTAssertFalse(try XCTUnwrap(model.selectedFile).isAccessActive)
            if attempt == 0 {
                model.cancelOverwrite(id)
                XCTAssertEqual(model.uploadState, .cancelled); XCTAssertTrue(fake.uploads.isEmpty)
                XCTAssertEqual(model.history.records.count, 1); XCTAssertEqual(model.history.records.first?.result, "取消")
            } else {
                model.confirmOverwrite(id); model.confirmOverwrite(id)
                try await waitUntil { fake.uploads.count == 1 }
                fake.uploads[0].continuation.resume(throwing: FTPError.transport(code: 25, response: 553, message: "Protected", upload: true))
                try await waitUntil { !model.isUploading }
                if case .failed(let reason) = model.uploadState { XCTAssertTrue(reason.contains("553")) }
                else { XCTFail("Server rejection must fail") }
                XCTAssertEqual(fake.browses.count, 3, "No automatic retry")
                XCTAssertEqual(model.history.records.count, 2); XCTAssertEqual(model.history.records.first?.result, "失败")
            }
        }
    }

    func testOverwriteAuthorizationInvalidatesOnConfigurationPathSelectionOrContentChange() async throws {
        for change in ["server", "identity", "path", "selection", "content"] {
            let fake = ControlledFTP(); fake.autoCheckTargets = false
            let model = AppModel(client: fake, history: isolatedHistory())
            try await connect(model, fake)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("bytes".utf8).write(to: file); try Data("other".utf8).write(to: other)
            defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: other) }
            model.selectFile(file); model.upload()
            try await waitUntil { fake.browses.count == 2 }
            let entry = RemoteEntry(name: file.lastPathComponent, rawName: Data(file.lastPathComponent.utf8), isDirectory: false, size: 5)
            fake.browses[1].continuation.resume(returning: DirectoryListing(entries: [entry], encoding: .utf8))
            try await waitUntil { model.overwriteRequestID != nil }
            let id = try XCTUnwrap(model.overwriteRequestID)
            switch change {
            case "server": model.address = "new.example"
            case "identity": model.loginMode = .account
            case "path": model.enter(destination)
            case "selection": model.selectFile(other)
            default:
                // Same length and restored mtime still changes the content digest.
                let original = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]!
                try Data("BYTES".utf8).write(to: file)
                try FileManager.default.setAttributes([.modificationDate: original], ofItemAtPath: file.path)
            }
            model.confirmOverwrite(id)
            if change == "path" || change == "content" {
                try await waitUntil { fake.browses.count == 3 }
                if change == "content" {
                    XCTAssertTrue(fake.uploads.isEmpty)
                    fake.browses[2].continuation.resume(returning: DirectoryListing(entries: [entry], encoding: .utf8))
                    try await waitUntil { model.overwriteRequestID != nil }
                    XCTAssertNotEqual(model.overwriteRequestID, id)
                    model.confirmOverwrite(id)
                    XCTAssertTrue(fake.uploads.isEmpty)
                    model.cancelOverwrite(try XCTUnwrap(model.overwriteRequestID))
                } else {
                    fake.browses[2].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
                    try await waitUntil { !model.isBusy }
                }
            }
            XCTAssertTrue(fake.uploads.isEmpty, change)
        }
    }

    func testInitialResolutionCancelNeverEnablesRootAsTargetAndLocksPolicy() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        model.address = "first.example/共享"; model.connect()
        try await waitUntil { fake.browses.count == 1 }
        XCTAssertEqual(fake.browses[0].path, .root)
        model.encodingPolicy = .gb18030
        XCTAssertEqual(model.encodingPolicy, .automatic)
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [destination], encoding: .utf8))
        try await waitUntil { fake.browses.count == 2 }
        XCTAssertFalse(model.hasDirectory); XCTAssertFalse(model.canUpload)
        model.cancelOperation()
        fake.browses[1].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { !model.isBusy }
        XCTAssertTrue(model.directoryCancelled); XCTAssertFalse(model.hasDirectory)
        XCTAssertEqual(model.path, .root); XCTAssertNil(model.endpoint)
    }

    func testSavedEncodingPolicyDirectPathAndDraftPreserveUserText() async throws {
        var draft = SiteDraft(); draft.host = "legacy.example"; draft.initialDirectory = "/共享"
        draft.encodingPolicy = .gb18030
        let site = try draft.configuration()
        XCTAssertEqual(site.initialDirectory, "/共享/")
        let fake = ControlledFTP()
        let model = AppModel(client: fake, sites: SiteManager(store: InMemorySites([site]), passwords: DelayedPasswords()), history: isolatedHistory())
        model.selectSite(site.id)
        XCTAssertEqual(model.encodingPolicy, .gb18030); XCTAssertTrue(fake.browses.isEmpty)
        XCTAssertEqual(model.siteDraft().initialDirectory, "/共享")
        XCTAssertEqual(model.siteDraft().encodingPolicy, .gb18030)
        model.connect()
        try await waitUntil { fake.browses.count == 1 }
        XCTAssertEqual(fake.browses[0].path.components.first?.bytes, try FTPTextEncoding.gb18030.encode("共享"))
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [], encoding: .gb18030))
        try await waitUntil { model.hasDirectory }
        XCTAssertEqual(model.path.display, "/共享")
        model.encodingPolicy = .utf8
        XCTAssertFalse(model.hasDirectory)
    }

    func testCompleteTransferControlFlowAcrossBothEncodings() async throws {
        for scenario in ["normal", "legacy"] {
            let fixture = try FTPFixture(scenario: scenario)
            defer { fixture.stop() }
            let model = AppModel(client: FTPClient(), history: isolatedHistory())
            model.address = fixture.endpoint.display + "/中文 空格%25/第二层"
            model.connect()
            try await waitUntil { model.hasDirectory && !model.isBusy }
            XCTAssertEqual(model.path.display, "/中文 空格%/第二层")
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("资料 %#.txt")
            let bytes = Data("complete transfer control pipeline".utf8)
            try bytes.write(to: file)
            model.selectFile(file); model.upload()
            try await waitUntil { model.uploadState == .succeeded && !model.isBusy }
            XCTAssertFalse(try XCTUnwrap(model.selectedFile).isAccessActive)
            XCTAssertTrue(model.entries.contains { $0.name == file.lastPathComponent })
            let remote = fixture.root.appendingPathComponent("中文 空格%").appendingPathComponent("第二层").appendingPathComponent(file.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: remote), bytes)
            model.upload()
            try await waitUntil { model.overwriteRequestID != nil }
            model.cancelOverwrite(try XCTUnwrap(model.overwriteRequestID))
            XCTAssertEqual(try fixture.commands().filter { $0["command"] == "STOR" }.count, 1)
            model.upload()
            try await waitUntil { model.overwriteRequestID != nil }
            model.confirmOverwrite(try XCTUnwrap(model.overwriteRequestID))
            try await waitUntil { !model.isUploading }
            if case .failed(let reason) = model.uploadState { XCTAssertTrue(reason.contains("553")) }
            else { XCTFail("Protected file overwrite must fail") }
            XCTAssertEqual(try Data(contentsOf: remote), bytes)
            let commands = try fixture.commands()
            XCTAssertEqual(commands.filter { $0["command"] == "STOR" }.count, 2)
            XCTAssertTrue(Set(commands.compactMap { $0["command"] }).isDisjoint(with: ["DELE", "RNFR", "RNTO", "SITE", "MKD", "APPE", "REST"]))
            let attachment = XCTAttachment(string: try String(contentsOfFile: fixture.info.log))
            attachment.name = "complete-flow-" + scenario
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testStaleCancelIDCannotStopNewOperationAndReconnectCancelKeepsValidDirectory() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        try await connect(model, fake)
        let previousPath = model.path
        model.refresh()
        let oldID = try XCTUnwrap(model.cancellationID)
        try await waitUntil { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: DirectoryListing(entries: [destination], encoding: .utf8))
        try await waitUntil { !model.isBusy }
        model.connect()
        let newID = try XCTUnwrap(model.cancellationID)
        try await waitUntil { fake.browses.count == 3 }
        XCTAssertNotEqual(oldID, newID)
        model.cancelOperation(id: oldID)
        XCTAssertFalse(model.isDirectoryCancelling)
        XCTAssertFalse(fake.browses[2].cancellation.isCancelled)
        model.cancelOperation(id: newID)
        fake.browses[2].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { !model.isBusy }
        XCTAssertTrue(model.hasDirectory)
        XCTAssertEqual(model.path, previousPath); XCTAssertEqual(model.entries, [destination])
        XCTAssertTrue(model.directoryCancelled)
    }

    func testDirectoriesAndUnreadableFilesDoNotUpload() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        try await connect(model, fake)
        model.selectFile(FileManager.default.temporaryDirectory)
        XCTAssertNil(model.selectedFile)
        XCTAssertNotNil(model.selectionError)
        model.upload()
        XCTAssertTrue(fake.uploads.isEmpty)
        model.selectFile(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertNil(model.selectedFile)
        XCTAssertNotNil(model.selectionError)
    }

    func testDropSelectsOneFileWithoutStartingUpload() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("drop".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertFalse(model.selectDroppedFiles([file]), "An unconnected app rejects drops")
        XCTAssertNil(model.selectedFile)
        XCTAssertNil(model.selectionError)
        try await connect(model, fake)
        XCTAssertTrue(model.selectDroppedFiles([file]))
        XCTAssertEqual(model.selectedFile?.url, file)
        XCTAssertEqual(model.selectedFile?.size, 4)
        XCTAssertEqual(model.pendingTarget, "ftp://first.example/" + file.lastPathComponent)
        XCTAssertEqual(model.uploadState, .idle)
        XCTAssertNil(model.uploadTarget)
        XCTAssertTrue(fake.uploads.isEmpty)
    }

    func testInvalidDropsDoNotStartUploadOrChangeResult() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        try await connect(model, fake)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("drop".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        model.selectFile(file)
        model.upload()
        try await waitUntil { fake.uploads.count == 1 }
        fake.uploads[0].continuation.resume(throwing: FTPError.incompatibleListing)
        try await waitUntil { !model.isUploading }
        let state = model.uploadState
        let target = model.uploadTarget
        let pending = model.pendingTarget
        XCTAssertFalse(model.selectDroppedFiles([file, file]))
        XCTAssertEqual(model.selectionError, "每次只能上传一个文件。")
        XCTAssertEqual(model.selectedFile?.url, file)
        XCTAssertEqual(model.pendingTarget, pending)
        XCTAssertEqual(model.uploadState, state)
        XCTAssertEqual(model.uploadTarget, target)
        XCTAssertFalse(model.selectDroppedFiles([FileManager.default.temporaryDirectory]))
        XCTAssertNil(model.selectedFile, "A folder must never become the selected file")
        XCTAssertNotNil(model.selectionError)
        XCTAssertEqual(model.uploadState, state)
        XCTAssertEqual(model.uploadTarget, target)
        XCTAssertEqual(fake.uploads.count, 1)
    }

    func testBusyDropsPreserveFileTargetAndUploadState() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake, history: isolatedHistory())
        try await connect(model, fake)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("drop".utf8).write(to: file)
        try Data("other".utf8).write(to: other)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: other)
        }
        model.selectFile(file)
        let pending = model.pendingTarget
        model.refresh()
        XCTAssertFalse(model.selectDroppedFiles([other]))
        XCTAssertEqual(model.selectedFile?.url, file)
        XCTAssertEqual(model.pendingTarget, pending)
        XCTAssertEqual(model.uploadState, .idle)
        XCTAssertNil(model.selectionError)
        try await waitUntil { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: DirectoryListing(entries: [destination], encoding: .utf8))
        try await waitUntil { !model.isDirectoryLoading }
        model.upload()
        try await waitUntil { fake.uploads.count == 1 }
        let target = model.uploadTarget
        for state in [UploadState.uploading, .awaitingCompletion] {
            if state == .awaitingCompletion {
                fake.uploads[0].progress(4, 4)
                try await waitUntil { model.uploadState == .awaitingCompletion }
            }
            XCTAssertFalse(model.selectDroppedFiles([other]))
            XCTAssertFalse(model.selectDroppedFiles([file, other]))
            XCTAssertEqual(model.selectedFile?.url, file)
            XCTAssertEqual(model.pendingTarget, pending)
            XCTAssertEqual(model.uploadTarget, target)
            XCTAssertEqual(model.uploadState, state)
            XCTAssertNil(model.selectionError)
        }
        fake.uploads[0].continuation.resume(throwing: FTPError.incompatibleListing)
        try await waitUntil { !model.isUploading }
    }
    func testFourProtocolBrowseUploadOverwriteAndCancelMatrix() async throws {
        func settled(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertTrue(condition(), "Protocol matrix state did not settle")
        }
        for transport in FileTransport.allCases {
            let ftp = transport == .sftp ? nil : try FTPFixture(transport: transport)
            let ssh = transport == .sftp ? try SFTPFixture() : nil
            defer { ftp?.stop(); ssh?.stop() }
            let endpoint = ftp?.endpoint ?? ssh!.endpoint
            let root = ftp?.root ?? ssh!.root
            let trustURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+"/hosts.json")
            defer { try? FileManager.default.removeItem(at: trustURL.deletingLastPathComponent()) }
            let trust = HostTrustStore(url: trustURL)
            if let ssh { try trust.trust(ssh.identity) }
            let ca = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/tls-fixtures/ca.pem").path
            let model = AppModel(client: FTPClient(caFile: ca, trust: trust), sites: SiteManager(store: InMemorySites(), passwords: DelayedPasswords()), history: isolatedHistory())
            model.transport = transport; model.address = endpoint.display
            model.loginMode = .account; model.username = "member"; model.password = "fixture-pass:@ "
            model.connect(); try await settled { !model.isDirectoryLoading }
            XCTAssertTrue(model.hasDirectory, model.directoryError ?? "No directory")
            XCTAssertEqual(model.endpoint?.transport, transport)
            XCTAssertTrue(model.connectionIdentity.contains(transport.title))
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("矩阵 %#.bin")
            let bytes = Data((0..<4096).map { UInt8($0 % 256) }); try bytes.write(to: file)
            model.selectFile(file); model.upload()
            try await settled { !model.isBusy }
            XCTAssertEqual(model.uploadState, .succeeded)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(file.lastPathComponent)), bytes)
            model.upload(); try await settled { model.uploadState == .awaitingOverwrite }
            let cancelledID = try XCTUnwrap(model.overwriteRequestID)
            model.cancelOverwrite(cancelledID)
            XCTAssertEqual(model.uploadState, .cancelled)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(file.lastPathComponent)), bytes)
            model.upload(); try await settled { model.uploadState == .awaitingOverwrite }
            model.confirmOverwrite(try XCTUnwrap(model.overwriteRequestID))
            try await settled { !model.isBusy }
            if transport == .sftp { XCTAssertEqual(model.uploadState, .succeeded) }
            else { if case .failed(let reason) = model.uploadState { XCTAssertTrue(reason.contains("553")) } else { XCTFail("Server overwrite refusal ignored") } }
            let wait = try XCTUnwrap(model.entries.first { $0.name == "等待确认" })
            model.enter(wait); try await settled { !model.isDirectoryLoading }
            model.selectFile(file); model.upload()
            try await settled { model.uploadState == .awaitingCompletion }
            let started = Date(); model.cancelOperation()
            XCTAssertEqual(model.uploadState, .cancelling)
            try await settled { !model.isBusy }
            XCTAssertEqual(model.uploadState, .cancelled)
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("等待确认").appendingPathComponent(file.lastPathComponent).path))
        }
    }

}

@MainActor
final class TransferJobTests: XCTestCase {
    private func job(token: FTPCancellationToken = FTPCancellationToken()) throws -> TransferJob {
        TransferJob(direction: .upload, endpoint: try FTPEndpoint(address: "ftp://example.test:2121/fixed"),
                    path: .root, encoding: .utf8, credentials: try .account(username: "fixed", password: "secret"),
                    localURL: URL(fileURLWithPath: "/tmp/fixed.bin"), cancellation: token)
    }

    func testCancelledJobNeverStartsAndTerminalCannotBeRewritten() async throws {
        let executor = TransferExecutor(); let token = FTPCancellationToken(); token.cancel()
        let request = try job(token: token); var called = false
        do { try await executor.execute(request) { called = true }; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(called); XCTAssertEqual(request.outcome, .cancelled)
        XCTAssertFalse(request.finish(.succeeded)); XCTAssertNil(executor.activeJob)
        XCTAssertEqual(request.endpoint.port, 2121); XCTAssertEqual(request.credentials.username, "fixed")
        XCTAssertEqual(request.localURL.lastPathComponent, "fixed.bin")
    }

    func testConcurrentExecutionRefusedUntilBackendStops() async throws {
        let executor = TransferExecutor(); let first = try job(); let second = try job()
        var continuation: CheckedContinuation<Void, Never>?
        let running = Task { try await executor.execute(first) {
            await withCheckedContinuation { continuation = $0 }
        } }
        while continuation == nil { await Task.yield() }
        XCTAssertTrue(executor.activeJob === first)
        do { try await executor.execute(second) { XCTFail("Parallel operation") }; XCTFail("Expected busy") }
        catch { XCTAssertNil(second.outcome) }
        first.cancellation.cancel()
        XCTAssertTrue(executor.activeJob === first)
        continuation?.resume()
        do { try await running.value; XCTFail("Expected cancellation") } catch { }
        XCTAssertEqual(first.outcome, .cancelled); XCTAssertNil(executor.activeJob)
        try await executor.execute(second) {}
        XCTAssertEqual(second.outcome, .succeeded)
        do { try await executor.execute(second) { XCTFail("Terminal replay") }; XCTFail("Expected terminal refusal") }
        catch { XCTAssertEqual(second.outcome, .succeeded) }
    }

    func testFailureRedactsSecretAndReleasesExecutor() async throws {
        let executor = TransferExecutor(); let request = try job()
        do { try await executor.execute(request) { throw FTPError.localFile("secret refused") }; XCTFail("Expected failure") }
        catch { }
        guard case .failed(let message) = request.outcome else { return XCTFail("Expected failed outcome") }
        XCTAssertFalse(message.contains("secret")); XCTAssertNil(executor.activeJob)
    }
}

@MainActor
final class DownloadModelTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition())
    }
    func testExplicitDownloadLocksTargetAndSuccessWaitsForCommit() async throws {
        let fake = ControlledFTP(); let model = AppModel(client: fake, history: isolatedHistory())
        let entry = RemoteEntry(name: "raw.bin", rawName: Data("raw.bin".utf8), isDirectory: false, size: 3)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        model.address = "example.test"; model.connect()
        try await wait { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [entry], encoding: .utf8))
        try await wait { model.hasDirectory }
        XCTAssertTrue(fake.downloads.isEmpty)
        model.download(RemoteEntry(name: "folder", rawName: Data("folder".utf8), isDirectory: true, size: nil), to: url)
        XCTAssertTrue(fake.downloads.isEmpty)
        model.download(entry, to: url); model.address = "other.test"; model.refresh()
        try await wait { fake.downloads.count == 1 }
        XCTAssertEqual(model.address, "example.test"); XCTAssertEqual(fake.browses.count, 1)
        try fake.downloads[0].receive(Data("new".utf8))
        fake.downloads[0].progress(3, 3)
        try await wait { model.downloadState == .awaitingCompletion }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try Data("race".utf8).write(to: url)
        fake.downloads[0].continuation.resume()
        try await wait { model.downloadConfirmationID != nil }
        XCTAssertEqual(model.downloadState, .awaitingOverwrite); XCTAssertFalse(model.canEditConnection)
        XCTAssertEqual(try Data(contentsOf: url), Data("race".utf8))
        model.cancelOperation()
        try await wait { model.downloadState == .cancelled }
        XCTAssertTrue(model.canEditConnection); XCTAssertEqual(try Data(contentsOf: url), Data("race".utf8))
        model.download(entry, to: url, authorizedIdentity: try LocalDownload.identity(url))
        try await wait { fake.downloads.count == 2 }
        try fake.downloads[1].receive(Data("yes".utf8)); fake.downloads[1].continuation.resume()
        try await wait { model.downloadState == .succeeded }
        XCTAssertEqual(try Data(contentsOf: url), Data("yes".utf8))
        fake.downloads[0].progress(1, 3); await Task.yield()
        XCTAssertEqual(model.downloadState, .succeeded)
    }
}

@MainActor
final class BatchQueueTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        let limit = Date().addingTimeInterval(3)
        while !condition() && Date() < limit { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition())
    }
    private func files() throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try ["first.bin", "second.bin"].map { name in
            let url = directory.appendingPathComponent(name); try Data(name.utf8).write(to: url); return url
        }
    }
    func testPreviewValidationAndSerialExecutionPauseExplicitRetry() async throws {
        let fake = ControlledFTP(), executor = TransferExecutor(); let queue = BatchTransferQueue(client: fake, executor: executor)
        let urls = try files(); let endpoint = try FTPEndpoint(address: "example.test")
        XCTAssertThrowsError(try queue.prepare([urls[0], urls[0]], endpoint: endpoint, path: .root, encoding: .utf8, credentials: .anonymous))
        XCTAssertThrowsError(try queue.prepare([urls[0].deletingLastPathComponent()], endpoint: endpoint, path: .root, encoding: .utf8, credentials: .anonymous))
        try queue.prepare(urls, endpoint: endpoint, path: .root, encoding: .utf8, credentials: .anonymous)
        XCTAssertEqual(queue.state, .preview); XCTAssertTrue(fake.uploads.isEmpty)
        queue.startOrContinue(); queue.startOrContinue()
        try await wait { fake.uploads.count == 1 }
        fake.uploads[0].continuation.resume(throwing: FTPError.localFile("denied"))
        try await wait { queue.state == .paused }
        XCTAssertEqual(fake.uploads.count, 1); XCTAssertTrue(queue.isLocked)
        queue.retry()
        try await wait { fake.uploads.count == 2 }
        XCTAssertNotEqual(queue.items[0].id, queue.items[1].id)
        fake.uploads[1].continuation.resume()
        try await wait { fake.uploads.count == 3 }
        fake.uploads[2].continuation.resume()
        try await wait { queue.state == .finished }
        XCTAssertFalse(queue.hasCredentials); XCTAssertNil(executor.activeJob)
        XCTAssertEqual(queue.items.filter { $0.state == .succeeded }.count, 2)
    }
    func testChangedWaitingFileFailsAndSkipDoesNotSendIt() async throws {
        let fake = ControlledFTP(); let queue = BatchTransferQueue(client: fake, executor: TransferExecutor())
        let urls = try files()
        try queue.prepare(urls, endpoint: FTPEndpoint(address: "example.test"), path: .root, encoding: .utf8, credentials: .anonymous)
        queue.startOrContinue(); try await wait { fake.uploads.count == 1 }
        try FileManager.default.removeItem(at: urls[1])
        fake.uploads[0].continuation.resume(); try await wait { queue.state == .paused }
        XCTAssertEqual(fake.uploads.count, 1)
        if case .failed = queue.items[1].state {} else { XCTFail("Missing file must fail") }
        queue.skip(); XCTAssertFalse(queue.isLocked); XCTAssertFalse(queue.hasCredentials)
    }
    func testOverwriteDecisionIsPerItemAndCancelAllWaitsForBackend() async throws {
        let fake = ControlledFTP(); fake.autoCheckTargets = false
        let queue = BatchTransferQueue(client: fake, executor: TransferExecutor()); let urls = try files()
        try queue.prepare(urls, endpoint: FTPEndpoint(address: "example.test"), path: .root, encoding: .utf8, credentials: .anonymous)
        queue.startOrContinue(); try await wait { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [RemoteEntry(name: "first.bin", rawName: Data("first.bin".utf8), isDirectory: false, size: 3)], encoding: .utf8))
        try await wait { queue.overwriteID != nil }
        XCTAssertTrue(fake.uploads.isEmpty)
        queue.confirmOverwrite(UUID()); XCTAssertTrue(fake.uploads.isEmpty)
        queue.confirmOverwrite(queue.overwriteID!)
        try await wait { fake.uploads.count == 1 }
        queue.cancelAll(); XCTAssertTrue(queue.isLocked); XCTAssertTrue(queue.hasCredentials)
        XCTAssertEqual(queue.items[1].state, .cancelled)
        fake.uploads[0].continuation.resume()
        try await wait { queue.state == .finished }
        XCTAssertEqual(fake.uploads.count, 1); XCTAssertFalse(queue.hasCredentials)
        XCTAssertEqual(queue.items[0].state, .cancelled)
    }
    func testModelLocksSiteThroughoutPreviewAndPausedBatch() async throws {
        let fake = ControlledFTP(); let model = AppModel(client: fake, history: isolatedHistory()); let urls = try files()
        model.address = "example.test"; model.connect(); try await wait { fake.browses.count == 1 }
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await wait { model.hasDirectory }
        model.prepareBatch(urls); XCTAssertFalse(model.canEditConnection)
        model.address = "other.test"; model.refresh(); XCTAssertEqual(model.address, "example.test")
        XCTAssertEqual(fake.browses.count, 1)
        model.batch.cancelAll(); XCTAssertTrue(model.canEditConnection)
        XCTAssertTrue(fake.uploads.isEmpty)
    }
}

@MainActor
final class TransferMetricsTests: XCTestCase {
    func testFiveSecondWindowStallUnknownZeroAndOutOfOrder() {
        var metrics = TransferMetrics()
        metrics.sample(bytes: 0, total: 1000, at: 0)
        metrics.sample(bytes: 100, total: 1000, at: 1)
        metrics.sample(bytes: 600, total: 1000, at: 6)
        XCTAssertEqual(metrics.estimate(at: 6).speed!, 100, accuracy: 0.001)
        XCTAssertEqual(metrics.estimate(at: 6).remaining!, 4, accuracy: 0.001)
        metrics.sample(bytes: 2, total: 1000, at: 5)
        XCTAssertEqual(metrics.bytes, 600)
        XCTAssertNil(metrics.estimate(at: 11).speed)
        metrics.sample(bytes: 700, total: -1, at: 12); XCTAssertNil(metrics.estimate(at: 12).remaining)
        var empty = TransferMetrics(); empty.sample(bytes: 0, total: 0, at: 1)
        XCTAssertNil(empty.estimate(at: 1).speed); XCTAssertNil(empty.estimate(at: 1).remaining)
    }
    func testMetricPresentationAtMostOncePerSecond() {
        var now = 0.0; let monitor = TransferMetricsMonitor(clock: { now })
        monitor.reset(total: 100)
        XCTAssertTrue(monitor.update(bytes: 1, total: 100))
        now = 0.2; XCTAssertFalse(monitor.update(bytes: 2, total: 100))
        now = 0.9; XCTAssertFalse(monitor.emit())
        now = 1; XCTAssertTrue(monitor.emit()); XCTAssertEqual(monitor.estimate.bytes, 2)
        monitor.stop()
    }
}

@MainActor
final class TransferHistoryTests: XCTestCase {
    private func location() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("history.json")
    }
    private func job() throws -> TransferJob {
        TransferJob(direction: .upload, endpoint: try FTPEndpoint(address: "example.test"), path: .root, encoding: .utf8,
                    credentials: try .account(username: "member", password: "secret"), localURL: URL(fileURLWithPath: "/tmp/file.bin"))
    }
    func testTerminalOnceRetentionRestartNoCredentialsAndClear() throws {
        let url = try location(); let store = TransferHistory(url: url)
        let first = try job(); first.finish(.failed("ftp://member:secret@example.test rejected secret"))
        store.record(first, target: "ftp://member:secret@example.test/file.bin", bytes: 4)
        store.record(first, target: "same", bytes: 4); XCTAssertEqual(store.records.count, 1)
        let text = try String(contentsOf: url)
        XCTAssertFalse(text.contains("secret")); XCTAssertFalse(text.contains("member:")); XCTAssertFalse(text.contains("password"))
        for _ in 0..<100 { let next = try job(); next.finish(.succeeded); store.record(next, target: "fixed", bytes: 8) }
        XCTAssertEqual(store.records.count, 100); XCTAssertFalse(store.records.contains { $0.id == first.id })
        let reopened = TransferHistory(url: url); XCTAssertEqual(reopened.records, store.records)
        XCTAssertNil(reopened.error)
        reopened.clear(); XCTAssertTrue(reopened.records.isEmpty)
        XCTAssertTrue(TransferHistory(url: url).records.isEmpty)
    }
    func testWriteFailureNeverChangesJobOutcomeAndCorruptionIsPreserved() throws {
        let url = try location(); let store = TransferHistory(url: url, writer: { _, _ in throw POSIXError(.ENOSPC) })
        let request = try job(); request.finish(.succeeded); store.record(request, target: "fixed", bytes: 2)
        XCTAssertEqual(request.outcome, .succeeded); XCTAssertNotNil(store.error)
        XCTAssertTrue(store.records.isEmpty)
        let damaged = Data("damaged history".utf8); try damaged.write(to: url)
        let broken = TransferHistory(url: url); XCTAssertNotNil(broken.error)
        broken.record(request, target: "fixed", bytes: 2); broken.clear()
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }
}
