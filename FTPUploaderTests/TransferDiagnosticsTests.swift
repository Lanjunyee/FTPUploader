import XCTest

@MainActor
final class TransferDiagnosticsTests: XCTestCase {
    func testReleaseWireBaseline() async throws {
        func wait(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(60)
            while !condition() {
                guard Date() < deadline else { throw POSIXError(.ETIMEDOUT) }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        for transport in [FileTransport.ftp, .ftpsExplicit, .ftpsImplicit, .sftp] {
            let ftp = transport == .sftp ? nil : try FTPFixture(transport: transport, countOperations: true)
            let ssh = transport == .sftp ? try SFTPFixture(countOperations: true) : nil
            defer { ftp?.stop(); ssh?.stop() }
            let endpoint = ftp?.endpoint ?? ssh!.endpoint
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let trust = HostTrustStore(url: base.appendingPathComponent("hosts.json"))
            if let ssh { try trust.trust(ssh.identity) }
            let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            let diagnostics = TransferDiagnostics()
            let model = AppModel(client: FTPClient(caFile: project.appendingPathComponent(".build/tls-fixtures/ca.pem").path, trust: trust),
                history: TransferHistory(url: base.appendingPathComponent("history.json")), diagnostics: diagnostics)
            model.transport = transport
            model.address = "127.0.0.1:\(endpoint.port)"
            model.loginMode = .account; model.username = "member"; model.password = "fixture-pass:@ "
            model.connect(); try await wait { !model.isBusy }
            XCTAssertTrue(model.hasDirectory)
            let source = base.appendingPathComponent("large.bin")
            try TransferScaleInput.largeFile(at: source)
            model.selectFile(source)
            let start = ProcessInfo.processInfo.systemUptime
            model.upload(); try await wait { !model.isBusy }
            XCTAssertEqual(model.uploadState, .succeeded)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            var usage = rusage(); XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
            let wire = try ftp?.operationCounts() ?? ssh?.operationCounts()
            let result: [String: Any] = ["case": "wire-upload", "transport": transport.rawValue,
                "bytes": 64 * 1024 * 1024, "seconds": elapsed, "peak_rss_bytes": usage.ru_maxrss,
                "counters": diagnostics.snapshot, "wire": wire ?? [:]]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print("HARDENING_BASELINE " + String(decoding: data, as: UTF8.self))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "hardening-baseline-" + transport.rawValue
            attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testControlledListingAndModelNotificationsAreOptIn() async throws {
        for enabled in [false, true] {
            let counts = TransferDiagnostics()
            let fake = ControlledFTP(diagnostics: enabled ? counts : nil)
            let model = AppModel(client: fake, history: isolatedHistory(), diagnostics: enabled ? counts : nil)
            model.address = "127.0.0.1:2121"
            model.connect()
            let deadline = Date().addingTimeInterval(3)
            while fake.browses.isEmpty && Date() < deadline { await Task.yield() }
            let request = try XCTUnwrap(fake.browses.first)
            request.continuation.resume(returning: DirectoryListing(entries: [], encoding: .utf8))
            while model.isDirectoryLoading && Date() < deadline { await Task.yield() }
            XCTAssertTrue(model.hasDirectory)
            XCTAssertEqual(counts.snapshot["listings"], enabled ? 1 : 0)
            XCTAssertEqual(counts.snapshot["connections"], 0, "A fake does not perform a handshake")
            XCTAssertEqual(counts.snapshot["authentications"], 0)
            XCTAssertEqual((counts.snapshot["notifications"] ?? 0) > 0, enabled)
        }
    }

    func testHashCountersMeasureOnlyReadsAndHaveFixedNumericSchema() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data(repeating: 42, count: 2 * 1024 * 1024 + 7)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let counts = TransferDiagnostics()
        let file = try SelectedLocalFile(url: url, diagnostics: counts)
        defer { file.endAccess() }
        let first = try await file.snapshot()
        let source = try await file.verifiedSource(matching: first, cancellation: FTPCancellationToken())
        XCTAssertEqual(source.expected, first)
        XCTAssertEqual(counts.snapshot["hashPasses"], 2)
        XCTAssertEqual(counts.snapshot["hashBytes"], Int64(bytes.count * 2))
        let unmeasured = try SelectedLocalFile(url: url)
        defer { unmeasured.endAccess() }
        let second = try await unmeasured.snapshot()
        XCTAssertEqual(first, second)
        XCTAssertEqual(counts.snapshot["hashPasses"], 2)
        XCTAssertEqual(Set(counts.snapshot.keys), Set(TransferDiagnostics.Event.allCases.map(\.rawValue)))
        let encoded = try JSONEncoder().encode(counts.snapshot)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(url.path))
    }

    nonisolated func testConcurrentCountersDoNotLoseEvents() {
        let counts = TransferDiagnostics()
        DispatchQueue.concurrentPerform(iterations: 10_000) { _ in counts.record(.notifications) }
        XCTAssertEqual(counts.snapshot["notifications"], 10_000)
        counts.record(.hashBytes, count: Int64.max)
        counts.record(.hashBytes)
        XCTAssertEqual(counts.snapshot["hashBytes"], Int64.max)
    }
}
