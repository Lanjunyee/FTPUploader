import XCTest

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
        model.selectSite(first.id)
        try await settle { passwords.reads.count == 4 }
        model.transport = .sftp; model.authenticationMethod = .privateKey
        model.passphrase = "session phrase"
        passwords.reads[3].1.resume(returning: "late-password")
        await Task.yield()
        XCTAssertNil(model.password); XCTAssertEqual(model.authenticationMethod, .privateKey)
        XCTAssertEqual(model.passphrase, "session phrase")
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
