import Foundation
import XCTest

final class FTPFixture {
    struct Info: Decodable { let port: Int; let root: String; let log: String }
    let process = Process()
    let info: Info
    let endpoint: FTPEndpoint
    private let exited = DispatchSemaphore(value: 0)
    private var stopped = false

    init(scenario: String = "normal", delay: Double = 2) throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [project.appendingPathComponent("script/ftp_fixture.py").path, "--scenario", scenario, "--delay", String(delay)]
        let output = Pipe()
        process.standardOutput = output
        let exited = self.exited
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let data = output.fileHandleForReading.availableData
        info = try JSONDecoder().decode(Info.self, from: data)
        endpoint = try FTPEndpoint(address: "127.0.0.1:\(info.port)")
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if process.isRunning { process.terminate() }
        if exited.wait(timeout: .now() + 5) != .success {
            // Foundation may miss the termination notification even though its
            // child has already been reaped. Check the actual process, bounded.
            errno = 0
            if kill(process.processIdentifier, 0) == -1 && errno == ESRCH { return }
            XCTFail("FTP fixture did not exit within 5 seconds")
        }
    }
    deinit { stop() }

    var root: URL { URL(fileURLWithPath: info.root) }

    func commands() throws -> [[String: String]] {
        let text = try String(contentsOfFile: info.log)
        return try text.split(separator: "\n").map { line in
            try JSONDecoder().decode([String: String].self, from: Data(line.utf8))
        }
    }
}
