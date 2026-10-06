import XCTest

final class DirectoryTests: XCTestCase {
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
}
