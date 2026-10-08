import Foundation
import XCTest

final class FTPFixture {
    struct Info: Decodable { let port: Int; let root: String; let log: String }
    let process = Process()
    let info: Info
    let endpoint: FTPEndpoint
    private let exited = DispatchSemaphore(value: 0)
    private var stopped = false

    init(scenario: String = "normal", delay: Double = 2, transport: FileTransport = .ftp, certificate: String = "good", failDataTLS: Bool = false) throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [project.appendingPathComponent("script/ftp_fixture.py").path, "--scenario", scenario, "--delay", String(delay)]
        if transport.requiresTLS {
            let certs = project.appendingPathComponent(".build/tls-fixtures")
            process.arguments! += ["--tls", transport == .ftpsImplicit ? "implicit" : "explicit",
                                   "--cert", certs.appendingPathComponent(certificate + ".pem").path,
                                   "--key", certs.appendingPathComponent(certificate + ".key").path]
            if failDataTLS { process.arguments!.append("--fail-data-tls") }
        }
        let output = Pipe()
        process.standardOutput = output
        let exited = self.exited
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let data = output.fileHandleForReading.availableData
        info = try JSONDecoder().decode(Info.self, from: data)
        endpoint = try FTPEndpoint(address: "127.0.0.1:\(info.port)", transport: transport)
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

final class SFTPFixture {
    struct Info: Decodable { let port: Int; let root: String; let log: String; let key: String }
    let process = Process()
    private let exited = DispatchSemaphore(value: 0)
    private var stopped = false
    let info: Info
    let endpoint: FTPEndpoint
    var identity: SSHHostIdentity { SSHHostIdentity(host: endpoint.host, port: endpoint.port, key: Data(base64Encoded: info.key)!) }
    var root: URL { URL(fileURLWithPath: info.root) }
    init(scenario: String = "normal", delay: Double = 2) throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = project.appendingPathComponent(".build/ssh-fixture-env/bin/python")
        process.arguments = [project.appendingPathComponent("script/sftp_fixture.py").path,"--scenario",scenario,"--delay",String(delay)]
        let output = Pipe(); process.standardOutput = output
        let exited = self.exited
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        info = try JSONDecoder().decode(Info.self, from: output.fileHandleForReading.availableData)
        endpoint = try FTPEndpoint(address: "sftp://127.0.0.1:\(info.port)")
    }
    func commands() throws -> [[String: String]] {
        try String(contentsOfFile: info.log).split(separator: "\n").map {
            try JSONDecoder().decode([String: String].self, from: Data($0.utf8))
        }
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        if process.isRunning { process.terminate() }
        if exited.wait(timeout: .now() + 5) != .success {
            errno = 0
            if kill(process.processIdentifier, 0) == -1 && errno == ESRCH { return }
            XCTFail("SFTP fixture did not exit within 5 seconds")
        }
    }
    deinit { stop() }
}
