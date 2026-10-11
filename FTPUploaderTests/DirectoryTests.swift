import XCTest

final class DirectoryCreationTests: XCTestCase {
    private var caFile: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/tls-fixtures/ca.pem").path
    }
    private func path(_ names: [String], _ encoding: FTPTextEncoding = .utf8) throws -> RemotePath {
        try names.reduce(RemotePath.root) { try $0.appending(name: $1, bytes: encoding.encode($1)) }
    }
    func testFTPAndFTPSDedicatedMKD257PreservesRawNamesWithoutDataTransfer() async throws {
        for transport in [FileTransport.ftp, .ftpsExplicit, .ftpsImplicit] {
            for scenario in ["normal", "legacy"] {
                let fixture = try FTPFixture(scenario: scenario, transport: transport)
                defer { fixture.stop() }
                let client = FTPClient(caFile: caFile)
                let encoding: FTPTextEncoding = scenario == "legacy" ? .gb18030 : .utf8
                let name = "目录 中文 空格%#"
                let directory = try path([name], encoding)
                try await client.createDirectory(endpoint: fixture.endpoint, path: directory, encoding: encoding,
                    credentials: .anonymous, cancellation: FTPCancellationToken())
                try await client.createDirectory(endpoint: fixture.endpoint, path: path([name, "空目录"], encoding), encoding: encoding,
                    credentials: .anonymous, cancellation: FTPCancellationToken())
                XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(name + "/空目录").path))
                let logs = try fixture.commands()
                XCTAssertEqual(logs.filter { $0["command"] == "MKD" }.map { $0["argument"] ?? "" }, [name, "空目录"])
                XCTAssertFalse(logs.contains { ["STOR", "RETR", "LIST", "MLSD", "PASV", "EPSV", "DELE", "RNFR", "RNTO"].contains($0["command"] ?? "") })
            }
        }
    }
    @MainActor
    func testAuthorizedPlanCreatesOnlyConfirmedDirectoryNodesAcrossProtocols() async throws {
        for transport in [FileTransport.ftp, .ftpsExplicit, .ftpsImplicit, .sftp] {
            let ftp = transport == .sftp ? nil : try FTPFixture(transport: transport)
            let ssh = transport == .sftp ? try SFTPFixture() : nil
            defer { ftp?.stop(); ssh?.stop() }
            let remoteRoot = ftp?.root ?? ssh!.root, endpoint = ftp?.endpoint ?? ssh!.endpoint
            let trust = HostTrustStore(url: remoteRoot.appendingPathComponent(".trust.json"))
            if let ssh { try trust.trust(ssh.identity) }
            let client = FTPClient(caFile: caFile, trust: trust)
            let credentials = transport == .sftp ? try FTPCredentials.account(username: "member", password: "fixture-pass:@ ") : .anonymous
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let source = folder.appendingPathComponent("only-planned")
            try FileManager.default.createDirectory(at: source.appendingPathComponent("空目录"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let sourceRoot = try LocalSourceRoot(url: source)
            let plan = try await LocalTransferScanner().scan(roots: [sourceRoot], destination: .root, encoding: .utf8, cancellation: FTPCancellationToken())
            let authorization = try UploadPlanAuthorization(plan: plan, endpoint: endpoint, destination: .root, credentials: credentials, client: client)
            do { _ = try await authorization.executeDirectory(nodeID: plan.nodes[0].id); XCTFail("Unconfirmed plan executed") } catch {}
            XCTAssertTrue(try (ftp?.commands() ?? ssh!.commands()).isEmpty)
            XCTAssertTrue(authorization.confirm(planID: plan.id))
            do { _ = try await authorization.executeDirectory(nodeID: plan.nodes[1].id); XCTFail("Child executed before parent") } catch {}
            do { _ = try await authorization.executeDirectory(nodeID: UUID()); XCTFail("Outside node executed") } catch {}
            XCTAssertTrue(try (ftp?.commands() ?? ssh!.commands()).isEmpty)
            for node in plan.nodes { _ = try await authorization.executeDirectory(nodeID: node.id) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: remoteRoot.appendingPathComponent("only-planned/空目录").path))
            let commands = try ftp?.commands() ?? ssh!.commands()
            let creates = commands.filter { ["MKD", "MKDIR"].contains($0["command"] ?? "") }
            XCTAssertEqual(creates.count, 2)
            XCTAssertFalse(commands.contains { ["STOR", "RETR", "OPEN", "DELE", "RNFR", "RNTO", "SITE", "REMOVE", "RENAME", "SETSTAT"].contains($0["command"] ?? "") })
            let attachment = XCTAttachment(string: String(data: try JSONSerialization.data(withJSONObject: commands, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
            attachment.name = "directory-plan-commands-" + transport.rawValue
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testCheckedCreationReusesDirectoriesAndRejectsFileAndLinkWithoutManagementCommands() async throws {
        for sftp in [false, true] {
            let ftp = sftp ? nil : try FTPFixture()
            let ssh = sftp ? try SFTPFixture() : nil
            defer { ftp?.stop(); ssh?.stop() }
            let root = ftp?.root ?? ssh!.root, endpoint = ftp?.endpoint ?? ssh!.endpoint
            let trust = HostTrustStore(url: root.appendingPathComponent(".trust.json"))
            if let ssh { try trust.trust(ssh.identity) }
            let client = FTPClient(trust: trust)
            let credentials = sftp ? try FTPCredentials.account(username: "member", password: "fixture-pass:@ ") : .anonymous
            try Data([1]).write(to: root.appendingPathComponent("occupied-file"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("occupied-link"), withDestinationURL: root.appendingPathComponent("空目录"))
            let reused = try await client.ensureDirectory(endpoint: endpoint, path: path(["空目录"]), encoding: .utf8,
                credentials: credentials, cancellation: FTPCancellationToken())
            XCTAssertEqual(reused, .reused)
            for name in ["occupied-file", "occupied-link"] {
                do {
                    _ = try await client.ensureDirectory(endpoint: endpoint, path: path([name]), encoding: .utf8,
                        credentials: credentials, cancellation: FTPCancellationToken())
                    XCTFail("Type conflict accepted")
                } catch { XCTAssertTrue(error is FTPError) }
            }
            let created = try await client.ensureDirectory(endpoint: endpoint, path: path(["planned-directory"]), encoding: .utf8,
                credentials: credentials, cancellation: FTPCancellationToken())
            XCTAssertEqual(created, .created)
            let commands = try ftp?.commands() ?? ssh!.commands()
            XCTAssertEqual(commands.filter { ["MKD", "MKDIR"].contains($0["command"] ?? "") }.count, 1)
            XCTAssertFalse(commands.contains { ["DELE", "RNFR", "RNTO", "SITE", "REMOVE", "RENAME", "SETSTAT"].contains($0["command"] ?? "") })
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("occupied-file")), Data([1]))
        }
    }

    func testSFTPMkdirPasswordAndPrivateKeyAndDenial() async throws {
        let fixture = try SFTPFixture(keyAuth: true)
        defer { fixture.stop() }
        let trust = HostTrustStore(url: fixture.root.appendingPathComponent(".trust.json"))
        try trust.trust(fixture.identity)
        let client = FTPClient(trust: trust)
        let key = try PrivateKeyAccess().read(fixture.root.appendingPathComponent(".keys/openssh-ed25519"))
        let identities = [try FTPCredentials.account(username: "member", password: "fixture-pass:@ "),
                          try FTPCredentials.key(username: "member", material: key, passphrase: nil)]
        for (i, credentials) in identities.enumerated() {
            let names = ["目录 中文%# \(i)"]
            try await client.createDirectory(endpoint: fixture.endpoint, path: path(names), encoding: .utf8,
                credentials: credentials, cancellation: FTPCancellationToken())
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(names[0]).path))
            do {
                try await client.createDirectory(endpoint: fixture.endpoint, path: path(["拒绝写入", "denied-\(i)"]), encoding: .utf8,
                    credentials: credentials, cancellation: FTPCancellationToken())
                XCTFail("Denied SFTP mkdir succeeded")
            } catch { XCTAssertTrue(error.localizedDescription.contains("SFTP 3")) }
        }
        let commands = try fixture.commands()
        XCTAssertEqual(commands.filter { $0["command"] == "MKDIR" }.count, 4)
        XCTAssertTrue(commands.contains { $0["command"] == "AUTH_KEY" })
        XCTAssertFalse(commands.contains { ["OPEN", "REMOVE", "RENAME", "SETSTAT"].contains($0["command"] ?? "") })
    }

    func testSFTPHostChangePreventsAuthenticationAndMkdir() async throws {
        let fixture = try SFTPFixture()
        defer { fixture.stop() }
        let trust = HostTrustStore(url: fixture.root.appendingPathComponent(".trust.json"))
        try trust.trust(SSHHostIdentity(host: fixture.endpoint.host, port: fixture.endpoint.port, key: Data([1, 2, 3])))
        do {
            try await FTPClient(trust: trust).createDirectory(endpoint: fixture.endpoint, path: path(["not-created"]), encoding: .utf8,
                credentials: FTPCredentials.account(username: "member", password: "fixture-pass:@ "), cancellation: FTPCancellationToken())
            XCTFail("Changed host mkdir succeeded")
        } catch { XCTAssertTrue(error is HostTrustError) }
        XCTAssertFalse(try fixture.commands().contains { ["MKDIR", "AUTH", "AUTH_KEY"].contains($0["command"] ?? "") })
    }

    func testSFTPCancelMkdirFinalAcknowledgementHasBoundedCleanup() async throws {
        let fixture = try SFTPFixture(delay: 10)
        defer { fixture.stop() }
        let trust = HostTrustStore(url: fixture.root.appendingPathComponent(".trust.json"))
        try trust.trust(fixture.identity)
        let token = FTPCancellationToken()
        let target = try path(["等待确认", "created"])
        let credentials = try FTPCredentials.account(username: "member", password: "fixture-pass:@ ")
        let task = Task {
            try await FTPClient(trust: trust).createDirectory(endpoint: fixture.endpoint, path: target, encoding: .utf8,
                credentials: credentials, cancellation: token)
        }
        let deadline = Date().addingTimeInterval(3)
        while !(try fixture.commands().contains { $0["command"] == "MKDIR" }) && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(try fixture.commands().contains { $0["command"] == "MKDIR" })
        let began = Date(); token.cancel()
        do { try await task.value; XCTFail("Cancelled SFTP mkdir succeeded") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(began), 2)
        XCTAssertFalse(try fixture.commands().contains { ["REMOVE", "RENAME", "SETSTAT"].contains($0["command"] ?? "") })
    }

    func testRejectedExistingAndWrongSuccessCodeAreNotAccepted() async throws {
        let fixture = try FTPFixture()
        defer { fixture.stop() }
        let client = FTPClient()
        for names in [["空目录"], ["拒绝写入", "new"], ["最终拒绝", "wrong-code"]] {
            do {
                try await client.createDirectory(endpoint: fixture.endpoint, path: path(names), encoding: .utf8,
                    credentials: .anonymous, cancellation: FTPCancellationToken())
                XCTFail("MKD accepted an existing/refused target or wrong final code")
            } catch { XCTAssertTrue(error is FTPError) }
        }
        XCTAssertEqual(try fixture.commands().filter { $0["command"] == "MKD" }.count, 3)
        let invalid = RemotePath(components: [.init(name: "bad", bytes: Data("bad\r\nDELE victim".utf8))])
        do {
            try await client.createDirectory(endpoint: fixture.endpoint, path: invalid, encoding: .utf8,
                credentials: .anonymous, cancellation: FTPCancellationToken())
            XCTFail("Command injection accepted")
        } catch { XCTAssertTrue(error is FTPError) }
        XCTAssertFalse(try fixture.commands().contains { $0["command"] == "DELE" })
    }
    func testCancelDuringDelayedMKDWaitsForBackendAndLeavesPossibleDirectory() async throws {
        let fixture = try FTPFixture(delay: 10)
        defer { fixture.stop() }
        let token = FTPCancellationToken()
        let target = try path(["等待确认", "created"])
        let task = Task {
            try await FTPClient().createDirectory(endpoint: fixture.endpoint, path: target, encoding: .utf8,
                credentials: .anonymous, cancellation: token)
        }
        let deadline = Date().addingTimeInterval(3)
        while !(try fixture.commands().contains { $0["command"] == "MKD" }) && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(try fixture.commands().contains { $0["command"] == "MKD" })
        let began = Date(); token.cancel()
        do { try await task.value; XCTFail("Cancelled MKD succeeded") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(began), 2)
        XCTAssertFalse(try fixture.commands().contains { $0["command"] == "DELE" })
    }
}

final class DirectoryTests: XCTestCase {
    func testCancellationIsIdempotentAndDoesNotAffectNextOperation() async throws {
        let fixture = try FTPFixture()
        defer { fixture.stop() }
        let client = FTPClient()
        let cancelled = FTPCancellationToken()
        DispatchQueue.concurrentPerform(iterations: 100) { _ in cancelled.cancel() }
        XCTAssertTrue(cancelled.isCancelled)
        do {
            _ = try await client.list(endpoint: fixture.endpoint, path: .root, cancellation: cancelled)
            XCTFail("Cancelled operation succeeded")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(try fixture.commands().isEmpty)
        let next = FTPCancellationToken()
        let listing = try await client.list(endpoint: fixture.endpoint, path: .root, cancellation: next)
        XCTAssertFalse(listing.entries.isEmpty)
        cancelled.cancel()
        XCTAssertFalse(next.isCancelled)
    }

    func testCancellationStopsUnresponsiveConnectionAndSlowListingWithinTwoSeconds() async throws {
        for scenario in ["slow-greeting", "slow-list"] {
            let fixture = try FTPFixture(scenario: scenario, delay: 10)
            defer { fixture.stop() }
            let token = FTPCancellationToken()
            let task = Task { try await FTPClient().list(endpoint: fixture.endpoint, path: .root, cancellation: token) }
            if scenario == "slow-list" {
                let deadline = Date().addingTimeInterval(3)
                while !(try fixture.commands().contains { $0["command"] == "MLSD" }) && Date() < deadline {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                XCTAssertTrue(try fixture.commands().contains { $0["command"] == "MLSD" })
            } else { try await Task.sleep(nanoseconds: 200_000_000) }
            let start = Date()
            token.cancel(); token.cancel()
            do { _ = try await task.value; XCTFail("Cancellation succeeded") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 2, scenario)
            let timing = XCTAttachment(string: "Cancellation latency for \(scenario): \(elapsed) seconds")
            timing.name = "cancellation-" + scenario
            timing.lifetime = .keepAlways
            add(timing)
            XCTAssertFalse(try fixture.commands().contains { $0["command"] == "STOR" })
        }
    }

    func testAutomaticInitialPathUsesRawNamesAcrossUTF8AndGB18030() async throws {
        for scenario in ["normal", "legacy"] {
            let fixture = try FTPFixture(scenario: scenario)
            defer { fixture.stop() }
            let endpoint = try FTPEndpoint(address: fixture.endpoint.display + "/中文 空格%25/第二层")
            let resolved = try await FTPClient().resolveInitialDirectory(endpoint: endpoint, policy: .automatic, credentials: .anonymous, cancellation: FTPCancellationToken())
            XCTAssertEqual(resolved.path.display, "/中文 空格%/第二层")
            let expected: FTPTextEncoding = scenario == "legacy" ? .gb18030 : .utf8
            XCTAssertEqual(resolved.listing.encoding, expected)
            XCTAssertEqual(resolved.path.components[0].bytes, try expected.encode("中文 空格%"))
            XCTAssertEqual(resolved.path.components[1].bytes, try expected.encode("第二层"))
            let logs = try fixture.commands()
            XCTAssertEqual(logs.filter { $0["command"] == "MLSD" }.map { $0["cwd"]! }, ["/", "/中文 空格%", "/中文 空格%/第二层"])
            XCTAssertFalse(logs.contains { $0["command"] == "STOR" })
        }
    }

    func testASCIIOrEmptyRootTriesUTF8OnceAndExplainsExplicitEncodingOnFailure() async throws {
        for scenario in ["ascii-root", "empty-root", "legacy-ascii-root", "legacy-empty-root"] {
            let fixture = try FTPFixture(scenario: scenario)
            defer { fixture.stop() }
            let endpoint = try FTPEndpoint(address: fixture.endpoint.display + "/中文 空格%25/第二层")
            do {
                let resolved = try await FTPClient().resolveInitialDirectory(endpoint: endpoint, policy: .automatic, credentials: .anonymous, cancellation: FTPCancellationToken())
                XCTAssertFalse(scenario.hasPrefix("legacy"))
                XCTAssertEqual(resolved.path.display, "/中文 空格%/第二层")
            } catch {
                XCTAssertTrue(scenario.hasPrefix("legacy"))
                XCTAssertTrue(error.localizedDescription.contains("明确"))
                XCTAssertTrue(error.localizedDescription.contains("中文 空格%25"))
                XCTAssertEqual(try fixture.commands().filter { $0["command"] == "MLSD" }.count, 1, "No encoding guessing retries")
            }
            XCTAssertFalse(try fixture.commands().contains { $0["command"] == "STOR" })
        }
    }

    func testRejectedInitialSegmentDoesNotReturnRootAsTarget() async throws {
        let fixture = try FTPFixture()
        defer { fixture.stop() }
        for suffix in ["/拒绝访问", "/中文 空格%25/missing"] {
            do {
                _ = try await FTPClient().resolveInitialDirectory(endpoint: FTPEndpoint(address: fixture.endpoint.display + suffix), policy: .automatic, credentials: .anonymous, cancellation: FTPCancellationToken())
                XCTFail("Unreachable path resolved")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(suffix.contains("missing") ? "missing" : "拒绝访问"))
            }
        }
    }

    func testListingDataLimitExactAndOneByteBeyond() throws {
        let prefix = Data("type=file;size=0; ".utf8)
        var data = prefix
        data.append(Data(repeating: 97, count: TransferPlan.maximumListingBytes - prefix.count - 1))
        data.append(10)
        XCTAssertEqual(data.count, TransferPlan.maximumListingBytes)
        XCTAssertEqual(try DirectoryParser.parse(data, machineReadable: true, preferredEncoding: .utf8).entries.count, 1)
        data.append(10)
        XCTAssertThrowsError(try DirectoryParser.parse(data, machineReadable: true, preferredEncoding: .utf8))
    }

    func testExplicitListingNeverSilentlyChangesEncoding() throws {
        let gb = try FTPTextEncoding.gb18030.encode("type=dir; 共享\r\n")
        XCTAssertThrowsError(try DirectoryParser.parse(gb, machineReadable: true, preferredEncoding: .utf8))
        XCTAssertEqual(try DirectoryParser.parse(gb, machineReadable: true, preferredEncoding: .gb18030).encoding, .gb18030)
    }

    func testExplicitAndRawPathsWorkWithoutRootListingAndNeverDoubleEncode() async throws {
        for scenario in ["deny-root", "legacy-deny-root"] {
            let fixture = try FTPFixture(scenario: scenario)
            defer { fixture.stop() }
            let expected: FTPTextEncoding = scenario.hasPrefix("legacy") ? .gb18030 : .utf8
            let policy: FTPEncodingPolicy = scenario.hasPrefix("legacy") ? .gb18030 : .utf8
            let endpoint = try FTPEndpoint(address: fixture.endpoint.display + "/中文 空格%25/第二层")
            let resolved = try await FTPClient().resolveInitialDirectory(endpoint: endpoint, policy: policy, credentials: .anonymous, cancellation: FTPCancellationToken())
            XCTAssertEqual(resolved.path.display, "/中文 空格%/第二层")
            XCTAssertEqual(resolved.listing.encoding, expected)
            let encoded = try endpoint.initialPath(using: expected).encodedDirectory
            let rawEndpoint = try FTPEndpoint(address: fixture.endpoint.display + encoded)
            let raw = try await FTPClient().resolveInitialDirectory(endpoint: rawEndpoint, policy: .automatic, credentials: .anonymous, cancellation: FTPCancellationToken())
            XCTAssertEqual(raw.path, resolved.path)
            XCTAssertEqual(rawEndpoint.directoryURL(raw.path), fixture.endpoint.display + encoded)
            XCTAssertFalse(try fixture.commands().contains { $0["command"] == "MLSD" && $0["cwd"] == "/" })
            do {
                _ = try await FTPClient().resolveInitialDirectory(endpoint: endpoint, policy: .automatic, credentials: .anonymous, cancellation: FTPCancellationToken())
                XCTFail("Automatic text path must not guess when root is denied")
            } catch { XCTAssertTrue(error.localizedDescription.contains("明确")) }
            XCTAssertFalse(try fixture.commands().contains { $0["command"] == "STOR" })
        }
    }

    func testUnencodableExplicitNameFailsBeforeAnyRequest() async throws {
        let fixture = try FTPFixture()
        defer { fixture.stop() }
        // Foundation cannot encode U+FFFE without loss.
        for name in ["\u{FFFE}"] {
            let endpoint = try FTPEndpoint(address: fixture.endpoint.display + "/" + name)
            do {
                _ = try await FTPClient().resolveInitialDirectory(endpoint: endpoint, policy: .gb18030, credentials: .anonymous, cancellation: FTPCancellationToken())
                XCTFail("Unencodable name was sent")
            } catch { XCTAssertTrue(error is FTPError) }
        }
        XCTAssertTrue(try fixture.commands().isEmpty)
    }

    func testRealEntryTypesPreserveNamesAndDirectoryFirstSorting() throws {
        for encoding in [FTPTextEncoding.utf8, .gb18030] {
            let machine = "type=file;size=12; 普通 中文%#\r\ntype=dir; 目录\r\ntype=OS.unix=slink:/outside; 链接 中文\r\ntype=OS.unix=fifo; 管道\r\ntype=vendor; 未知\r\n"
            let unix = "-rw-r--r-- 1 ftp ftp 12 Oct 03 2026 普通 中文%#\r\ndrwxr-xr-x 1 ftp ftp 0 Oct 03 2026 目录\r\nlrwxrwxrwx 1 ftp ftp 9 Oct 03 2026 链接 中文 -> /outside\r\nprw------- 1 ftp ftp 0 Oct 03 2026 管道\r\ncrw------- 1 ftp ftp 1, 3 Oct 03 2026 设备\r\n"
            for (text, mlsd) in [(machine, true), (unix, false)] {
                let listing = try DirectoryParser.parse(encoding.encode(text), machineReadable: mlsd, preferredEncoding: encoding)
                XCTAssertEqual(listing.entries.first?.kind, .directory)
                for (name, kind) in [("普通 中文%#", RemoteEntry.Kind.regularFile), ("目录", .directory), ("链接 中文", .symbolicLink), ("管道", .other)] {
                    let entry = try XCTUnwrap(listing.entries.first { $0.name == name })
                    XCTAssertEqual(entry.kind, kind)
                    XCTAssertEqual(entry.rawName, try encoding.encode(name))
                    XCTAssertEqual(entry.size, kind == .regularFile ? 12 : nil)
                }
                XCTAssertEqual(listing.entries.first { $0.name == (mlsd ? "未知" : "设备") }?.kind, mlsd ? .unknown : .other)
            }
        }
        let old = RemoteEntry(name: "file", rawName: Data("file".utf8), isDirectory: false, size: 0)
        XCTAssertEqual(old.kind, .regularFile)
    }

    func testSFTPClassifiesLinksSpecialAndMissingPermissions() async throws {
        let fixture = try SFTPFixture(scenario: "entry-types")
        defer { fixture.stop() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/hosts.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let trust = HostTrustStore(url: url)
        try trust.trust(fixture.identity)
        let listing = try await FTPClient(trust: trust).list(endpoint: fixture.endpoint, path: .root,
            credentials: FTPCredentials.account(username: "member", password: "fixture-pass:@ "))
        for (name, kind) in [("普通 中文%#", RemoteEntry.Kind.regularFile), ("目录", .directory), ("链接", .symbolicLink), ("管道", .other), ("未知", .unknown)] {
            let entry = try XCTUnwrap(listing.entries.first { $0.name == name })
            XCTAssertEqual(entry.kind, kind)
            XCTAssertEqual(entry.rawName, Data(name.utf8))
            XCTAssertEqual(entry.size, kind == .regularFile ? 12 : nil)
        }
    }

    func testMachineListingWithUnicodeSpacesAndDotEntries() throws {
        let text = "type=cdir; .\r\ntype=pdir; ..\r\ntype=dir; 共享 %#\r\ntype=file;size=12; 资料.pdf\r\n"
        let listing = try DirectoryParser.parse(Data(text.utf8), machineReadable: true)
        XCTAssertEqual(listing.entries.map(\.name), ["共享 %#", "资料.pdf"])
        XCTAssertTrue(listing.entries[0].isDirectory)
        XCTAssertEqual(listing.entries[1].size, 12)
        XCTAssertEqual(listing.entries[0].rawName, Data("共享 %#".utf8))
        XCTAssertTrue(try DirectoryParser.parse(Data(), machineReadable: true).entries.isEmpty)
    }

    func testLegacyFormatsAndEncoding() throws {
        let unix = "total 2\r\ndrwxr-xr-x 1 ftp ftp 0 Oct 03 12:00 共享 资料%#\r\n-rw-r--r-- 1 ftp ftp 13 Oct 03 2026 report.pdf\r\n"
        let bytes = try FTPTextEncoding.gb18030.encode(unix)
        let listing = try DirectoryParser.parse(bytes, machineReadable: false)
        XCTAssertEqual(listing.encoding, .gb18030)
        XCTAssertEqual(listing.entries[0].name, "共享 资料%#")
        XCTAssertEqual(listing.entries[0].rawName, try FTPTextEncoding.gb18030.encode("共享 资料%#"))
        let dos = "10-03-26  12:00PM       <DIR>          共享\r\n10-03-26  12:00PM       123          file name.txt\r\n"
        let dosListing = try DirectoryParser.parse(Data(dos.utf8), machineReadable: false)
        XCTAssertTrue(dosListing.entries[0].isDirectory)
        XCTAssertEqual(dosListing.entries[1].name, "file name.txt")
        XCTAssertEqual(dosListing.entries[1].size, 123)
        XCTAssertEqual(try DirectoryParser.parse(Data(), machineReadable: true, preferredEncoding: .gb18030).encoding, .gb18030)
    }

    func testUnknownAndUnsafeListingsDoNotBecomeEmptySuccess() {
        for machine in [true, false] {
            XCTAssertThrowsError(try DirectoryParser.parse(Data("unrecognized list\r\n".utf8), machineReadable: machine))
        }
        XCTAssertThrowsError(try DirectoryParser.parse(Data("type=dir; ../outside\r\n".utf8), machineReadable: true))
        XCTAssertThrowsError(try DirectoryParser.parse(Data("type=dir; same\r\ntype=file; same\r\n".utf8), machineReadable: true))
    }

    func testAnonymousPassiveBrowsingAndFallback() async throws {
        for scenario in ["normal", "no-mlsd", "legacy"] {
            let fixture = try FTPFixture(scenario: scenario)
            defer { fixture.stop() }
            let client = FTPClient()
            let listing = try await client.list(endpoint: fixture.endpoint, path: .root)
            let destination = try XCTUnwrap(listing.entries.first { $0.name == "共享 资料%#" })
            let path = try RemotePath.root.appending(name: destination.name, bytes: destination.rawName)
            let child = try await client.list(endpoint: fixture.endpoint, path: path, encoding: listing.encoding)
            XCTAssertTrue(child.entries.contains { $0.name == "项目文件" && $0.isDirectory })
            let commands = try fixture.commands().map { $0["command"]! }
            XCTAssertTrue(commands.contains("USER"))
            XCTAssertTrue(commands.contains("EPSV") || commands.contains("PASV"))
            XCTAssertEqual(commands.contains("LIST"), scenario == "no-mlsd")
            if scenario == "legacy" { XCTAssertEqual(listing.encoding, .gb18030) }
        }
    }

    func testAccessDenialAndMalformedDataDoNotFallback() async throws {
        for scenario in ["deny-login", "deny-list", "malformed"] {
            let fixture = try FTPFixture(scenario: scenario)
            defer { fixture.stop() }
            do {
                _ = try await FTPClient().list(endpoint: fixture.endpoint, path: .root)
                XCTFail("Unexpected listing success")
            } catch {
                XCTAssertFalse(try fixture.commands().contains { $0["command"] == "LIST" })
                if scenario == "deny-login" { XCTAssertTrue(error.localizedDescription.contains("匿名")) }
            }
        }
    }

    func testUnavailableAndResponseTimeout() async throws {
        do {
            _ = try await FTPClient(connectTimeout: 1).list(endpoint: FTPEndpoint(address: "127.0.0.1:1"), path: .root)
            XCTFail("Unexpected connection")
        } catch { XCTAssertTrue(error.localizedDescription.contains("无法连接")) }
        let fixture = try FTPFixture(scenario: "slow-list", delay: 3)
        defer { fixture.stop() }
        do {
            _ = try await FTPClient(responseTimeout: 1, stallTimeout: 1).list(endpoint: fixture.endpoint, path: .root)
            XCTFail("Unexpected timeout success")
        } catch { XCTAssertTrue(error.localizedDescription.contains("无法连接")) }
    }
    func testSFTPStructuredDirectoryUTF8AbsolutePathsDenialAndCancellation() async throws {
        let credentials = try FTPCredentials.account(username: "member", password: "fixture-pass:@ ")
        for scenario in ["normal", "slow-list", "invalid-utf8"] {
            let fixture = try SFTPFixture(scenario: scenario, delay: 10); defer { fixture.stop() }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+"/hosts.json")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let trust = HostTrustStore(url: url); try trust.trust(fixture.identity)
            let client = FTPClient(responseTimeout: 3, trust: trust)
            if scenario == "normal" {
                let root = try await client.list(endpoint: fixture.endpoint, path: .root, credentials: credentials)
                XCTAssertEqual(root.encoding, .utf8)
                let entry = try XCTUnwrap(root.entries.first { $0.name == "中文 空格%#" })
                XCTAssertTrue(entry.isDirectory)
                let path = try RemotePath.root.appending(name: entry.name, bytes: entry.rawName)
                let listing = try await client.list(endpoint: fixture.endpoint, path: path, credentials: credentials)
                XCTAssertTrue(listing.entries.contains { $0.name == "已提交.txt" && !$0.isDirectory && $0.size == 10 })
                let endpoint = try FTPEndpoint(address: "sftp://127.0.0.1:\(fixture.info.port)/中文 空格%25%23")
                let resolved = try await client.resolveInitialDirectory(endpoint: endpoint, policy: .automatic, credentials: credentials, cancellation: FTPCancellationToken())
                XCTAssertEqual(resolved.path, path)
                let denied = try RemotePath.root.appending(name: "拒绝访问", bytes: Data("拒绝访问".utf8))
                do { _ = try await client.list(endpoint: fixture.endpoint, path: denied, credentials: credentials); XCTFail("Denied path accepted") }
                catch { XCTAssertTrue(error.localizedDescription.contains("SFTP 3")) }
            } else if scenario == "invalid-utf8" {
                do { _ = try await client.list(endpoint: fixture.endpoint, path: .root, credentials: credentials); XCTFail("Invalid UTF8 accepted") }
                catch { XCTAssertTrue(error.localizedDescription.contains("编码")) }
            } else {
                let token = FTPCancellationToken()
                let operation = Task { try await client.list(endpoint: fixture.endpoint, path: .root, credentials: credentials, cancellation: token) }
                try await Task.sleep(nanoseconds: 200_000_000)
                let started = Date(); token.cancel()
                do { _ = try await operation.value; XCTFail("Cancelled SFTP succeeded") }
                catch { XCTAssertTrue(error is CancellationError) }
                XCTAssertLessThan(Date().timeIntervalSince(started), 2)
            }
        }
    }

}
