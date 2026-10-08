import XCTest

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
