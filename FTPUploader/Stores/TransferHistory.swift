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
    var kind: TransferTaskKind? = nil
    var batchID: UUID? = nil
    var blockedParentID: UUID? = nil
    var blockedReason: TransferTaskResult.DependencyReason? = nil
    var taskKind: TransferTaskKind { kind ?? .file }

    static func task(id: UUID, direction: TransferDirection, kind: TransferTaskKind, name: String,
                     endpoint: FTPEndpoint, target: String, credentials: FTPCredentials,
                     result: TransferTaskResult, started: Date, bytes: Int64, batchID: UUID?) -> Self {
        let title: String, detail: String?
        var parent: UUID?, reason: TransferTaskResult.DependencyReason?
        switch result {
        case .succeeded: title = "成功"; detail = nil
        case .failed(let message): title = "失败"; detail = message
        case .cancelled: title = "取消"; detail = nil
        case .skipped(let message): title = "跳过"; detail = message
        case .blocked(let id, let category):
            title = "依赖阻塞"; detail = nil; parent = id; reason = category
        }
        func safe(_ text: String) -> String { TransferHistory.sanitize(credentials.redacting(text)) }
        return Self(id: id, direction: direction, name: safe(name), transport: endpoint.transport,
            server: safe(endpoint.authority), target: safe(target), started: started, ended: Date(),
            bytes: kind == .directory ? 0 : max(0, bytes), result: title, error: detail.map(safe),
            kind: kind, batchID: batchID, blockedParentID: parent, blockedReason: reason)
    }
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
    private let backupWriter: (Data, URL) throws -> Void
    private var legacyData: Data?
    var backupURL: URL { url.appendingPathExtension("v1-backup") }
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
         .appendingPathComponent("FTPUploader/transfer-history.json"),
         writer: @escaping (Data, URL) throws -> Void = { data, url in
             try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
             try data.write(to: url, options: .atomic)
         }, backupWriter: @escaping (Data, URL) throws -> Void = { data, url in
             try data.write(to: url, options: .withoutOverwriting)
         }) {
        self.url = url; self.writer = writer; self.backupWriter = backupWriter
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let original = try Data(contentsOf: url)
                let archive = try JSONDecoder().decode(Archive.self, from: original)
                guard [1, 2].contains(archive.version), archive.records.count <= 100,
                      Set(archive.records.map(\.id)).count == archive.records.count,
                      archive.records.allSatisfy({ Self.valid($0, version: archive.version) }) else {
                    throw FTPError.localFile("记录格式或版本无效。")
                }
                records = archive.records.sorted { $0.ended > $1.ended }
                seen = Set(records.map(\.id))
                if archive.version == 1 { legacyData = original }
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
        case .skipped(let message): result = "跳过"; detail = Self.sanitize(job.credentials.redacting(message))
        case .failed(let message): result = "失败"; detail = Self.sanitize(job.credentials.redacting(message))
        }
        let next = TransferRecord(id: job.id, direction: job.direction,
                                  name: Self.sanitize(job.credentials.redacting(job.name)),
                                  transport: job.endpoint.transport, server: job.endpoint.authority,
                                  target: Self.sanitize(job.credentials.redacting(target)), started: job.started,
                                  ended: Date(), bytes: max(0, bytes), result: result, error: detail, kind: .file)
        persist(next)
    }
    func record(_ record: TransferRecord) {
        guard loaded, Self.valid(record, version: 2), seen.insert(record.id).inserted else { return }
        let safe = TransferRecord(id: record.id, direction: record.direction, name: Self.sanitize(record.name),
            transport: record.transport, server: Self.sanitize(record.server), target: Self.sanitize(record.target),
            started: record.started, ended: record.ended, bytes: record.taskKind == .directory ? 0 : record.bytes,
            result: record.result, error: record.error.map(Self.sanitize), kind: record.taskKind,
            batchID: record.batchID, blockedParentID: record.blockedParentID, blockedReason: record.blockedReason)
        persist(safe)
    }
    private func persist(_ next: TransferRecord) {
        let updated = Array(([next] + records).prefix(100))
        do { try save(updated); records = updated; error = nil }
        catch { self.error = "无法保存传输记录；传输结果保持不变。" + error.localizedDescription }
    }
    private static func valid(_ record: TransferRecord, version: Int) -> Bool {
        let titles = version == 1 ? ["成功", "失败", "取消"] : ["成功", "失败", "取消", "跳过", "依赖阻塞"]
        guard record.bytes >= 0, titles.contains(record.result),
              record.taskKind != .directory || record.bytes == 0 else { return false }
        if record.result == "依赖阻塞" { return record.blockedParentID != nil && record.blockedReason != nil }
        return record.blockedParentID == nil && record.blockedReason == nil
    }
    func clear() {
        guard loaded else { return }
        do { try save([]); records = []; error = nil }
        catch { self.error = "无法清除传输记录，原记录保留。" + error.localizedDescription }
    }
    private func save(_ records: [TransferRecord]) throws {
        if let legacyData {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                guard try Data(contentsOf: backupURL) == legacyData else {
                    throw FTPError.localFile("旧历史备份已存在且内容不同，未覆盖备份或原历史：" + backupURL.path)
                }
            } else { try backupWriter(legacyData, backupURL) }
            guard try Data(contentsOf: backupURL) == legacyData else {
                throw FTPError.localFile("旧历史备份核对失败，未迁移原历史。")
            }
        }
        try writer(JSONEncoder().encode(Archive(version: 2, records: records)), url)
        legacyData = nil
    }
    nonisolated static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)(ftp|ftps|sftp)://[^\s/]*@"#, with: "$1://[redacted]@", options: .regularExpression)
    }
}
