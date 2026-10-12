import Foundation
import Combine

/// Memory-only admission owned by a terminal attempt; copies share its one-way claim.
/// It retains no id, record, credentials or store and is never encoded into an archive.
final class TransferHistoryAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    @discardableResult func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true; return true
    }
}

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
    var trafficOverflow: Bool? = nil
    var historyAdmission = TransferHistoryAdmission()
    var taskKind: TransferTaskKind { kind ?? .file }
    private enum CodingKeys: String, CodingKey {
        case id, direction, name, transport, server, target, started, ended, bytes, result, error
        case kind, batchID, blockedParentID, blockedReason, trafficOverflow
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.direction == rhs.direction && lhs.name == rhs.name && lhs.transport == rhs.transport
            && lhs.server == rhs.server && lhs.target == rhs.target && lhs.started == rhs.started && lhs.ended == rhs.ended
            && lhs.bytes == rhs.bytes && lhs.result == rhs.result && lhs.error == rhs.error && lhs.kind == rhs.kind
            && lhs.batchID == rhs.batchID && lhs.blockedParentID == rhs.blockedParentID && lhs.blockedReason == rhs.blockedReason
            && (lhs.trafficOverflow ?? false) == (rhs.trafficOverflow ?? false)
    }

    static func task(id: UUID, direction: TransferDirection, kind: TransferTaskKind, name: String,
                     endpoint: FTPEndpoint, target: String, credentials: FTPCredentials,
                     result: TransferTaskResult, started: Date, bytes: Int64, batchID: UUID?,
                     admission: TransferHistoryAdmission = TransferHistoryAdmission(), trafficOverflow: Bool = false) -> Self {
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
            kind: kind, batchID: batchID, blockedParentID: parent, blockedReason: reason,
            trafficOverflow: trafficOverflow ? true : nil, historyAdmission: admission)
    }
}

/// All filesystem access, migration backup verification and encoding execute on this
/// dedicated serial queue, not MainActor or a blocked cooperative Swift executor.
private final class TransferHistoryStorage: @unchecked Sendable {
    private struct Archive: Codable { let version: Int; let records: [TransferRecord] }
    private let queue = DispatchQueue(label: "local.schoolftpuploader.history", qos: .utility)
    private let url: URL
    private let writer: (Data, URL) throws -> Void
    private let backupWriter: (Data, URL) throws -> Void
    private var loaded = false
    private var loadedData: Data?
    private var legacyData: Data?
    private var backupURL: URL { url.appendingPathExtension("v1-backup") }
    init(url: URL, writer: @escaping (Data, URL) throws -> Void, backupWriter: @escaping (Data, URL) throws -> Void) {
        self.url = url; self.writer = writer; self.backupWriter = backupWriter
    }
    private func perform<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func data(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
    func load() async throws -> [TransferRecord] {
        try await perform { [self] in
            loaded = false
            let original = try data(at: url)
            let records: [TransferRecord]
            if let original {
                let archive = try JSONDecoder().decode(Archive.self, from: original)
                guard [1, 2].contains(archive.version), archive.records.count <= 100,
                      Set(archive.records.map(\.id)).count == archive.records.count,
                      archive.records.allSatisfy({ TransferHistory.valid($0, version: archive.version) }) else {
                    throw FTPError.localFile("记录格式或版本无效。")
                }
                records = archive.records.sorted { $0.ended > $1.ended }
                legacyData = archive.version == 1 ? original : nil
            } else { records = []; legacyData = nil }
            loadedData = original; loaded = true
            return records
        }
    }
    func save(_ records: [TransferRecord]) async throws {
        try await perform { [self] in
            guard loaded, try data(at: url) == loadedData else {
                throw FTPError.localFile("历史原件已变化，未覆盖未知数据。")
            }
            if let legacyData {
                if let backup = try data(at: backupURL) {
                    guard backup == legacyData else {
                        throw FTPError.localFile("旧历史备份已存在且内容不同，未覆盖备份或原历史。")
                    }
                } else { try backupWriter(legacyData, backupURL) }
                guard try data(at: backupURL) == legacyData else {
                    throw FTPError.localFile("旧历史备份核对失败，未迁移原历史。")
                }
            }
            let bytes = try JSONEncoder().encode(Archive(version: 2, records: records))
            try writer(bytes, url)
            guard try data(at: url) == bytes else { throw FTPError.localFile("历史写入核对失败。") }
            loadedData = bytes; legacyData = nil
        }
    }
}

/// Normal termination waits for accepted local records, not a network retry. The host
/// reports failure and asks the user before discarding pending state; force kill cannot drain.
@MainActor
final class HistoryTerminationCoordinator {
    private(set) var isDraining = false
    func requestExit(history: TransferHistory, onFailure: @escaping (Error) -> Bool, reply: @escaping (Bool) -> Void) {
        guard !isDraining else { return }
        isDraining = true
        Task {
            do {
                repeat { try await history.drain() } while history.hasPendingSave
                isDraining = false; reply(true)
            } catch {
                let mayExit = onFailure(error)
                isDraining = false; reply(mayExit)
            }
        }
    }
}

@MainActor
final class TransferHistory: ObservableObject {
    private struct Snapshot { let revision: UInt64; let records: [TransferRecord] }
    @Published private(set) var records: [TransferRecord] = []
    @Published private(set) var error: String?
    @Published private(set) var isLoading = true
    @Published private(set) var isSaving = false
    @Published private(set) var isClearing = false
    @Published private(set) var acceptedRevision: UInt64 = 0
    @Published private(set) var durableRevision: UInt64 = 0
    @Published private(set) var clearCompletedRevision: UInt64?
    private(set) var isLoaded = false
    private let storage: TransferHistoryStorage
    private var pendingSnapshot: Snapshot?
    private var pendingClearRevision: UInt64?
    private var clearCutoffIDs = Set<UUID>()
    private var requiresExplicitRetry = false
    private var drainWaiters: [CheckedContinuation<Void, Error>] = []
    let url: URL
    var backupURL: URL { url.appendingPathExtension("v1-backup") }
    var hasPendingSave: Bool { acceptedRevision > durableRevision }
    var hasPendingClear: Bool { pendingClearRevision != nil }
    var persistenceStatus: String {
        if isLoading { return "正在加载本机记录…" }
        if !isLoaded { return "记录加载失败，原数据保留；本次终态尚未保存。" }
        if hasPendingClear { return isClearing ? "正在清除记录，等待本机提交…" : "清除未完成，原持久记录保留。" }
        return hasPendingSave ? "终态已接收，记录待保存。" : "没有待保存记录。"
    }
    var canRetrySave: Bool { isLoaded && !isLoading && !isSaving && requiresExplicitRetry }
    var canClear: Bool { isLoaded && !isLoading && pendingClearRevision == nil && !records.isEmpty }
    var queuedSnapshotCount: Int { pendingSnapshot == nil ? 0 : 1 }
    var inFlightSnapshotCount: Int { isSaving ? 1 : 0 }
    var retainedIdentityCount: Int { Set(records.map(\.id)).union(clearCutoffIDs).count }

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
         .appendingPathComponent("FTPUploader/transfer-history.json"),
         writer: @escaping (Data, URL) throws -> Void = { data, url in
             try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
             try data.write(to: url, options: .atomic)
         }, backupWriter: @escaping (Data, URL) throws -> Void = { data, url in
             try data.write(to: url, options: .withoutOverwriting)
         }) {
        self.url = url
        storage = TransferHistoryStorage(url: url, writer: writer, backupWriter: backupWriter)
        Task { await load() }
    }
    private func load() async {
        do {
            let prior = try await storage.load()
            let priorIDs = Set(prior.map(\.id))
            // Early terminal records never overwrite an existing result with the same id.
            records = Array((records.filter { !priorIDs.contains($0.id) } + prior)
                .sorted { $0.ended > $1.ended }.prefix(100))
            prior.forEach { $0.historyAdmission.claim() }
            isLoaded = true; isLoading = false; error = nil
            if acceptedRevision > 0 { pendingSnapshot = Snapshot(revision: acceptedRevision, records: records) }
            startNextWrite()
        } catch {
            isLoading = false
            self.error = "无法加载传输记录，已保留原数据；本次终态仍保留在内存。" + error.localizedDescription
            settleDrains()
        }
    }
    func record(_ job: TransferJob, target: String, bytes: Int64) {
        guard let outcome = job.outcome, job.historyAdmission.claim(),
              !records.contains(where: { $0.id == job.id }), !clearCutoffIDs.contains(job.id) else { return }
        let result: String; let detail: String?
        switch outcome {
        case .succeeded: result = "成功"; detail = nil
        case .cancelled: result = "取消"; detail = nil
        case .skipped(let message): result = "跳过"; detail = Self.sanitize(job.credentials.redacting(message))
        case .failed(let message): result = "失败"; detail = Self.sanitize(job.credentials.redacting(message))
        }
        accept(TransferRecord(id: job.id, direction: job.direction,
            name: Self.sanitize(job.credentials.redacting(job.name)),
            transport: job.endpoint.transport, server: job.endpoint.authority,
            target: Self.sanitize(job.credentials.redacting(target)), started: job.started,
            ended: Date(), bytes: job.byteCounter.hasOverflow ? Int64.max : max(0, bytes), result: result, error: detail,
            kind: .file, trafficOverflow: job.byteCounter.hasOverflow ? true : nil))
    }
    func record(_ record: TransferRecord) {
        guard Self.valid(record, version: 2), record.historyAdmission.claim(),
              !records.contains(where: { $0.id == record.id }), !clearCutoffIDs.contains(record.id) else { return }
        accept(TransferRecord(id: record.id, direction: record.direction, name: Self.sanitize(record.name),
            transport: record.transport, server: Self.sanitize(record.server), target: Self.sanitize(record.target),
            started: record.started, ended: record.ended, bytes: record.taskKind == .directory ? 0 : record.bytes,
            result: record.result, error: record.error.map(Self.sanitize), kind: record.taskKind,
            batchID: record.batchID, blockedParentID: record.blockedParentID, blockedReason: record.blockedReason,
            trafficOverflow: record.trafficOverflow))
    }
    private func accept(_ next: TransferRecord) {
        next.historyAdmission.claim() // Copies taken from display rows cannot later reenter history.
        records = Array(([next] + records).prefix(100))
        acceptedRevision += 1
        pendingSnapshot = Snapshot(revision: acceptedRevision, records: records.filter { !clearCutoffIDs.contains($0.id) })
        startNextWrite()
    }
    func retrySave() {
        guard canRetrySave else { return }
        requiresExplicitRetry = false; error = nil
        if pendingClearRevision != nil { isClearing = true }
        startNextWrite()
    }
    /// A control barrier, not another queued snapshot. Preserve visible old records on
    /// failure; after success, only records accepted after this request remain visible.
    func clear() {
        guard canClear else { return }
        acceptedRevision += 1
        pendingClearRevision = acceptedRevision
        clearCutoffIDs = Set(records.map(\.id))
        pendingSnapshot = nil
        isClearing = true; requiresExplicitRetry = false; error = nil
        startNextWrite()
    }
    private func startNextWrite() {
        guard isLoaded, !isLoading, !isSaving, !requiresExplicitRetry else { settleDrains(); return }
        if let revision = pendingClearRevision {
            isSaving = true
            Task {
                do {
                    try await storage.save([])
                    durableRevision = revision
                    records.removeAll { clearCutoffIDs.contains($0.id) }
                    clearCutoffIDs.removeAll(); pendingClearRevision = nil
                    clearCompletedRevision = revision; isClearing = false; error = nil
                } catch {
                    requiresExplicitRetry = true; isClearing = false
                    self.error = "无法清除传输记录，原记录保留；请明确重试本机保存。" + error.localizedDescription
                }
                isSaving = false; startNextWrite()
            }
        } else if let snapshot = pendingSnapshot {
            pendingSnapshot = nil; isSaving = true
            Task {
                do { try await storage.save(snapshot.records); durableRevision = snapshot.revision; error = nil }
                catch {
                    // Never replace a newer pending snapshot with the failed older one.
                    if pendingSnapshot == nil && pendingClearRevision == nil { pendingSnapshot = snapshot }
                    requiresExplicitRetry = true
                    if pendingClearRevision != nil { isClearing = false }
                    self.error = "无法保存传输记录；本次终态待保存，传输结果保持不变。" + error.localizedDescription
                }
                isSaving = false; startNextWrite()
            }
        } else { settleDrains() }
    }
    /// Wait for accepted local persistence work. Failure is observable; no automatic
    /// filesystem or network retry is performed, and force termination cannot await this.
    func drain() async throws {
        try await withCheckedThrowingContinuation { continuation in
            drainWaiters.append(continuation)
            settleDrains()
        }
    }
    private func settleDrains() {
        guard !isLoading, !isSaving else { return }
        if !isLoaded || requiresExplicitRetry {
            let waiters = drainWaiters; drainWaiters.removeAll()
            waiters.forEach { $0.resume(throwing: FTPError.localFile(error ?? "历史持久化未完成。")) }
        } else if pendingSnapshot == nil && pendingClearRevision == nil {
            let waiters = drainWaiters; drainWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
    nonisolated fileprivate static func valid(_ record: TransferRecord, version: Int) -> Bool {
        let titles = version == 1 ? ["成功", "失败", "取消"] : ["成功", "失败", "取消", "跳过", "依赖阻塞"]
        guard record.bytes >= 0, titles.contains(record.result),
              record.trafficOverflow != true || record.bytes == Int64.max,
              record.taskKind != .directory || record.bytes == 0 else { return false }
        if record.result == "依赖阻塞" { return record.blockedParentID != nil && record.blockedReason != nil }
        return record.blockedParentID == nil && record.blockedReason == nil
    }
    nonisolated static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)(ftp|ftps|sftp)://[^\s/]*@"#, with: "$1://[redacted]@", options: .regularExpression)
    }
}
