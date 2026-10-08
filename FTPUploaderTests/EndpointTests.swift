import XCTest

final class EndpointTests: XCTestCase {
    func testHostAndPortAndInitialDirectory() throws {
        let endpoint = try FTPEndpoint(address: "ftp://ftp.example:2121/共享/资料%20%25%23/")
        XCTAssertEqual(endpoint.port, 2121)
        XCTAssertEqual(endpoint.initialPath.display, "/共享/资料 %#")
        XCTAssertEqual(endpoint.directoryURL(endpoint.initialPath), "ftp://ftp.example:2121/%E5%85%B1%E4%BA%AB/%E8%B5%84%E6%96%99%20%25%23/")
        XCTAssertEqual(try FTPEndpoint(address: "ftp.example").port, 21)
        XCTAssertEqual(try FTPEndpoint(address: "127.0.0.1:2121").port, 2121)
        XCTAssertEqual(try FTPEndpoint(address: "ftp://[::1]:2121").display, "ftp://[::1]:2121")
    }

    func testInvalidInputsAreRejected() {
        let inputs = ["", " ", "ftp://", "ftp://host:70000", "ftp://host:0", "ftp://host:-1", "ftp://host:abc", "https://host", "ftp://user:secret@host", "ftp://@host", "ftp://host?x=1", "ftp://host/#destination", "ftp://bad host", "ftp://host/a%ZZ", "ftp://host/%2Fother", "ftp://host/%0ASTOR", "ftp://host/..", "host\n", "ftp://host\\other"]
        for input in inputs {
            XCTAssertThrowsError(try FTPEndpoint(address: input), "Accepted invalid input: \(input)")
        }
    }

    func testAddressFailuresReportTheAddressFieldAndReason() {
        let cases: [(String, String)] = [
            ("", "请输入"),
            ("ftp://host:70000", "端口"),
            ("ftp://host:0", "端口"),
            ("https://host", "ftp://"),
            ("ftp://user:secret@host", "账号密码"),
            ("ftp://@host", "账号密码"),
            ("host\n", "控制字符"),
            ("ftp://bad host", "ftp://"),
            ("ftp://host/a%ZZ", "百分号"),
        ]
        for (input, fragment) in cases {
            do {
                _ = try FTPEndpoint(address: input)
                XCTFail("Accepted invalid input: \(input)")
            } catch let issue as FieldIssue {
                XCTAssertEqual(issue.field, .address, "Wrong field for \(input)")
                XCTAssertTrue(issue.message.contains(fragment), "Reason for \(input): \(issue.message)")
                XCTAssertEqual(issue.errorDescription, issue.message)
            } catch {
                XCTFail("Unexpected error for \(input): \(error)")
            }
        }
    }

    func testFileNameIsOneSegmentAndPreservesSpecialCharacters() throws {
        let endpoint = try FTPEndpoint(address: "ftp.example/共享")
        let result = try endpoint.fileURL(endpoint.initialPath, name: "资料 %#.pdf", encoding: .utf8)
        XCTAssertTrue(result.hasSuffix("/%E8%B5%84%E6%96%99%20%25%23.pdf"))
        XCTAssertThrowsError(try endpoint.fileURL(.root, name: "../other", encoding: .utf8))
        XCTAssertThrowsError(try endpoint.fileURL(.root, name: "file\r\nDELE old", encoding: .utf8))
        XCTAssertEqual(endpoint.initialPath.parent, .root)
        XCTAssertNil(RemotePath.root.parent)
    }

    func testLegacyEncodingRoundTripPreservesOriginalBytes() throws {
        let bytes = try FTPTextEncoding.gb18030.encode("共享 资料")
        XCTAssertEqual(try FTPTextEncoding.detect(bytes), .gb18030)
        XCTAssertEqual(try FTPTextEncoding.gb18030.decode(bytes), "共享 资料")
        let path = try RemotePath.root.appending(name: "共享 资料", bytes: bytes)
        XCTAssertEqual(try RemotePath.percentDecode(String(path.encodedDirectory.dropFirst().dropLast())), bytes)
    }
    func testSecureProtocolDefaultsCustomPortsAndConflicts() throws {
        for transport in FileTransport.allCases {
            let endpoint = try FTPEndpoint(address: "example.test/中文", transport: transport)
            XCTAssertEqual(endpoint.transport, transport)
            XCTAssertEqual(endpoint.port, transport.defaultPort)
            let custom = try FTPEndpoint(address: "example.test:2022/中文", transport: transport)
            XCTAssertEqual(custom.port, 2022)
            XCTAssertEqual(custom.initialPath.display, "/中文")
        }
        XCTAssertEqual(try FTPEndpoint(address: "ftps://example.test").transport, .ftpsImplicit)
        XCTAssertEqual(try FTPEndpoint(address: "sftp://example.test").port, 22)
        XCTAssertThrowsError(try FTPEndpoint(address: "sftp://host", transport: .ftpsExplicit))
        XCTAssertThrowsError(try FTPEndpoint(address: "ftp://host", transport: .sftp))
        XCTAssertThrowsError(try FTPEndpoint(address: "ftps://host", transport: .ftpsExplicit))
        XCTAssertThrowsError(try FTPEndpoint(address: "sftp://host/%B9%B2"))
        XCTAssertThrowsError(try FTPEndpoint(address: "scp://host"))
    }

}
