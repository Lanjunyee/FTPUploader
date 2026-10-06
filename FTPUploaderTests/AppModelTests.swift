import XCTest

@MainActor
private final class ControlledFTP: FTPServing {
    struct BrowseRequest {
        let endpoint: FTPEndpoint
        let path: RemotePath
        let credentials: FTPCredentials
        let continuation: CheckedContinuation<DirectoryListing, Error>
    }
    struct UploadRequest {
        let endpoint: FTPEndpoint
        let path: RemotePath
        let credentials: FTPCredentials
        let progress: (Int64, Int64) -> Void
        let continuation: CheckedContinuation<Void, Error>
    }
    var browses: [BrowseRequest] = []
    var uploads: [UploadRequest] = []

    func list(endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding?, credentials: FTPCredentials) async throws -> DirectoryListing {
        try await withCheckedThrowingContinuation {
            browses.append(BrowseRequest(endpoint: endpoint, path: path, credentials: credentials, continuation: $0))
        }
    }
    func upload(endpoint: FTPEndpoint, path: RemotePath, file: URL, encoding: FTPTextEncoding, credentials: FTPCredentials,
                progress: @escaping (Int64, Int64) -> Void) async throws {
        try await withCheckedThrowingContinuation {
            uploads.append(UploadRequest(endpoint: endpoint, path: path, credentials: credentials, progress: progress, continuation: $0))
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
        let model = AppModel(client: fake, sites: SiteManager(store: InMemorySites([first, second]), passwords: DelayedPasswords()))
        model.selectSite(first.id)
        XCTAssertTrue(fake.browses.isEmpty)
        model.password = "one"; model.connect()
        try await settle { fake.browses.count == 1 }
        XCTAssertEqual(fake.browses[0].credentials.username, "first")
        model.selectSite(second.id)
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        await Task.yield()
        XCTAssertFalse(model.hasDirectory); XCTAssertFalse(model.canUpload)
        XCTAssertNil(model.password)
        model.password = "two"; model.connect()
        try await settle { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await settle { model.hasDirectory }
        XCTAssertEqual(model.connectionIdentity, "FTP · 账户：second")
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
        let model = AppModel(client: ControlledFTP(), sites: SiteManager(store: InMemorySites([first, second]), passwords: passwords))
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
        let model = AppModel(client: fake, sites: manager)
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
        let model = AppModel(client: fake, sites: SiteManager(store: InMemorySites(), passwords: DelayedPasswords()))
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
        let model = AppModel(client: fake)
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
        let model = AppModel(client: fake)
        model.address = "old.example"
        model.connect()
        try await waitUntil { fake.browses.count == 1 }
        model.address = "new.example"
        model.connect()
        try await waitUntil { fake.browses.count == 2 }
        fake.browses[1].continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
        try await waitUntil { model.hasDirectory }
        fake.browses[0].continuation.resume(returning: DirectoryListing(entries: [destination], encoding: .utf8))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.endpoint?.host, "new.example")
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testRepeatedConnectWhileLoadingIssuesOneRequestAndRetriesAfter() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake)
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
        let model = AppModel(client: fake)
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
        let model = AppModel(client: fake)
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
        let model = AppModel(client: fake)
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
        let model = AppModel(client: fake)
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
        let model = AppModel(client: fake)
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
        let model = AppModel(client: fake)
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
        let model = AppModel(client: fake)
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

    func testDirectoriesAndUnreadableFilesDoNotUpload() async throws {
        let fake = ControlledFTP()
        let model = AppModel(client: fake)
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
}
