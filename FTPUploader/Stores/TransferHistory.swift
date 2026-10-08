import Foundation
import Combine

struct TransferRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let direction: TransferDirection
    let name: String
    let transport: FileTransport
    let server: String
    let target: String
    let started: Date
    let ended: Date
    let bytes: Int64
    let result: String
    let error: String?
}

@MainActor
final class TransferHistory: ObservableObject {
    private struct Archive: Codable { let version: Int; let records: [TransferRecord] }
    @Published private(set) var records: [TransferRecord] = []
    @Published private(set) var error: String?
    private var seen = Set<UUID>()
    private var loaded = false
    let url: URL
    private let writer: (Data, URL) throws -> Void
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
         .appendingPathComponent("FTPUploader/transfer-history.json"),
         writer: @escaping (Data, URL) throws -> Void = { data, url in
             try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
             try data.write(to: url, options: .atomic)
         }) {
        self.url = url; self.writer = writer
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
                guard archive.version == 1, archive.records.count <= 100,
                      Set(archive.records.map(\.id)).count == archive.records.count,
                      archive.records.allSatisfy({ $0.bytes >= 0 && ["成功", "失败", "取消"].contains($0.result) }) else {
                    throw FTPError.localFile("记录格式或版本无效。")
                }
                records = archive.records.sorted { $0.ended > $1.ended }
                seen = Set(records.map(\.id))
            }
            loaded = true
        } catch { self.error = "无法加载传输记录，已保留原数据。" + error.localizedDescription }
    }
    func record(_ job: TransferJob, target: String, bytes: Int64) {
        guard let outcome = job.outcome, seen.insert(job.id).inserted else { return }
        guard loaded else { return }
        let result: String; let detail: String?
        switch outcome {
        case .succeeded: result = "成功"; detail = nil
        case .cancelled: result = "取消"; detail = nil
        case .failed(let message): result = "失败"; detail = Self.sanitize(job.credentials.redacting(message))
        }
        let next = TransferRecord(id: job.id, direction: job.direction,
                                  name: Self.sanitize(job.credentials.redacting(job.name)),
                                  transport: job.endpoint.transport, server: job.endpoint.authority,
                                  target: Self.sanitize(job.credentials.redacting(target)), started: job.started,
                                  ended: Date(), bytes: max(0, bytes), result: result, error: detail)
        let updated = Array(([next] + records).prefix(100))
        do { try save(updated); records = updated; error = nil }
        catch { self.error = "无法保存传输记录；传输结果保持不变。" + error.localizedDescription }
    }
    func clear() {
        guard loaded else { return }
        do { try save([]); records = []; error = nil }
        catch { self.error = "无法清除传输记录，原记录保留。" + error.localizedDescription }
    }
    private func save(_ records: [TransferRecord]) throws {
        try writer(JSONEncoder().encode(Archive(version: 1, records: records)), url)
    }
    static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)(ftp|ftps|sftp)://[^\s/]*@"#, with: "$1://[redacted]@", options: .regularExpression)
    }
}
