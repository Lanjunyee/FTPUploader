import Foundation

enum TransferDirection: String, Codable { case upload, download }
enum TransferOutcome: Equatable { case succeeded, failed(String), cancelled }

/// A request snapshot lives only in memory. Credentials never enter a persisted job.
@MainActor
final class TransferJob: Identifiable {
    let id = UUID()
    let started = Date()
    let name: String
    let direction: TransferDirection
    let endpoint: FTPEndpoint
    let path: RemotePath
    let encoding: FTPTextEncoding
    let credentials: FTPCredentials
    let localURL: URL
    let cancellation: FTPCancellationToken
    private(set) var outcome: TransferOutcome?

    init(direction: TransferDirection, endpoint: FTPEndpoint, path: RemotePath,
         encoding: FTPTextEncoding, credentials: FTPCredentials, localURL: URL,
         cancellation: FTPCancellationToken = FTPCancellationToken(), name: String? = nil) {
        self.name = name ?? localURL.lastPathComponent
        self.direction = direction; self.endpoint = endpoint; self.path = path
        self.encoding = encoding; self.credentials = credentials; self.localURL = localURL
        self.cancellation = cancellation
    }

    @discardableResult
    func finish(_ result: TransferOutcome) -> Bool {
        guard outcome == nil else { return false }
        outcome = result
        return true
    }
}

/// One operation owns the executor until its backend has stopped and released resources.
@MainActor
final class TransferExecutor {
    private(set) var activeJob: TransferJob?

    func execute(_ job: TransferJob, operation: () async throws -> Void) async throws {
        guard activeJob == nil, job.outcome == nil else {
            throw FTPError.localFile("已有传输正在运行，或该任务已经结束。")
        }
        activeJob = job
        defer { activeJob = nil }
        do {
            try job.cancellation.checkCancellation()
            try await operation()
            try job.cancellation.checkCancellation()
            job.finish(.succeeded)
        } catch {
            if job.cancellation.isCancelled || error is CancellationError {
                job.finish(.cancelled)
                throw CancellationError()
            }
            job.finish(.failed(job.credentials.redacting(error.localizedDescription)))
            throw error
        }
    }
}

import Combine

@MainActor
final class BatchTransferQueue: ObservableObject {
    enum State: Equatable { case preview, running, paused, finished }
    enum ItemState: Equatable {
        case waiting, running, awaitingCompletion, awaitingOverwrite, succeeded, cancelled
        case failed(String)
        var title: String {
            switch self {
            case .waiting: return "等待"
            case .running: return "正在上传"
            case .awaitingCompletion: return "等待最终确认"
            case .awaitingOverwrite: return "等待覆盖确认"
            case .succeeded: return "成功"
            case .cancelled: return "取消"
            case .failed(let message): return "失败：" + message
            }
        }
    }
    struct Item: Identifiable {
        let id: UUID
        let url: URL
        let name: String
        let target: String
        let snapshot: SelectedLocalFile.Snapshot
        var state: ItemState = .waiting
        var bytes: Int64 = 0
    }
    private struct Context {
        let endpoint: FTPEndpoint
        let path: RemotePath
        let encoding: FTPTextEncoding
        let credentials: FTPCredentials
    }
    @Published private(set) var items: [Item] = []
    @Published private(set) var state: State = .finished
    @Published private(set) var error: String?
    @Published private(set) var overwriteID: UUID?
    private let client: FTPServing
    private let executor: TransferExecutor
    private var context: Context?
    private var active: TransferJob?
    private var decision: CheckedContinuation<Void, Error>?
    private var cancelledAll = false
    private var index = 0
    var isLocked: Bool { state != .finished }
    var isExecuting: Bool { active != nil }
    var cancellationID: UUID? { active?.cancellation.id }
    var hasCredentials: Bool { context != nil }
    var onFinish: ((TransferJob, String, Int64) -> Void)?
    var onProgress: ((UUID, Int64, Int64) -> Bool)?
    var onStart: ((Int64) -> Void)?
    private var actualBytes: Int64 = 0

    init(client: FTPServing, executor: TransferExecutor) { self.client = client; self.executor = executor }

    func prepare(_ urls: [URL], endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding, credentials: FTPCredentials) throws {
        guard !isLocked, !urls.isEmpty else { throw FTPError.localFile("请先结束当前批次并选择普通文件。") }
        var prepared: [Item] = []; var targets = Set<Data>()
        for url in urls {
            let file = try SelectedLocalFile(url: url)
            defer { file.endAccess() }
            let bytes = try encoding.encode(file.name); try RemotePath.validateName(bytes)
            guard targets.insert(bytes).inserted else { throw FTPError.localFile("同批目标重名：" + file.name) }
            _ = try endpoint.fileURL(path, name: file.name, encoding: encoding)
            prepared.append(Item(id: UUID(), url: url, name: file.name,
                                 target: endpoint.display + path.display + (path.components.isEmpty ? "" : "/") + file.name,
                                 snapshot: try file.snapshot()))
        }
        items = prepared; context = Context(endpoint: endpoint, path: path, encoding: encoding, credentials: credentials)
        index = 0; cancelledAll = false; error = nil; state = .preview
    }

    func startOrContinue() {
        guard !isExecuting, state == .preview || state == .paused, context != nil else { return }
        guard index < items.count else { finishBatch(); return }
        state = .running
        Task { await run() }
    }

    private func run() async {
        while index < items.count, !cancelledAll, let context {
            let current = index
            guard items[current].state == .waiting else { state = .paused; return }
            let item = items[current]
            let job = TransferJob(direction: .upload, endpoint: context.endpoint, path: context.path,
                                  encoding: context.encoding, credentials: context.credentials, localURL: item.url)
            active = job; items[current].state = .running; actualBytes = 0
            onStart?(item.snapshot.size)
            var file: SelectedLocalFile?
            do {
                try await executor.execute(job) {
                    let selected = try SelectedLocalFile(url: item.url); file = selected
                    guard try selected.snapshot() == item.snapshot else {
                        throw FTPError.localFile("等待期间文件已变化，请明确重试以重新核对：" + item.name)
                    }
                    let existing = try await client.checkUploadTarget(endpoint: job.endpoint, path: job.path, name: item.name,
                                                                     encoding: job.encoding, credentials: job.credentials, cancellation: job.cancellation)
                    try job.cancellation.checkCancellation()
                    if let existing {
                        guard !existing.isDirectory else { throw FTPError.uploadTargetConflict }
                        items[current].state = .awaitingOverwrite; overwriteID = item.id
                        try await withCheckedThrowingContinuation { decision = $0 }
                        try job.cancellation.checkCancellation()
                        guard try selected.snapshot() == item.snapshot else { throw FTPError.localFile("覆盖授权后文件发生变化，请重新核对。") }
                    }
                    items[current].state = .running
                    try await client.upload(endpoint: job.endpoint, path: job.path, file: job.localURL,
                                            encoding: job.encoding, credentials: job.credentials, cancellation: job.cancellation) { [weak self] bytes, total in
                        Task { @MainActor [weak self] in
                            guard let self, self.active === job, !job.cancellation.isCancelled,
                                  [.running, .awaitingCompletion].contains(self.items[current].state) else { return }
                            self.actualBytes = max(self.actualBytes, bytes)
                            if self.onProgress?(item.id, bytes, total) ?? true { self.items[current].bytes = self.actualBytes }
                            let next: ItemState = total >= 0 && bytes >= total ? .awaitingCompletion : .running
                            if self.items[current].state != next { self.items[current].state = next }
                        }
                    }
                }
                items[current].bytes = item.snapshot.size; items[current].state = .succeeded
            } catch {
                items[current].state = job.cancellation.isCancelled || error is CancellationError ? .cancelled : .failed(job.credentials.redacting(error.localizedDescription))
            }
            file?.endAccess(); active = nil; overwriteID = nil; decision = nil
            onFinish?(job, item.target, max(actualBytes, items[current].bytes))
            if cancelledAll { finishBatch(); return }
            if items[current].state != .succeeded { state = .paused; return }
            index += 1
        }
        finishBatch()
    }

    func confirmOverwrite(_ id: UUID) {
        guard overwriteID == id, let continuation = decision else { return }
        decision = nil; overwriteID = nil; continuation.resume()
    }
    func cancelCurrent() {
        guard let active else { return }
        active.cancellation.cancel()
        if let decision { self.decision = nil; overwriteID = nil; decision.resume(throwing: CancellationError()) }
    }
    func skip() {
        guard state == .paused, !isExecuting else { return }
        index += 1
        if index >= items.count { finishBatch() }
    }
    func retry() {
        guard state == .paused, !isExecuting, index < items.count, let context else { return }
        do {
            let original = items[index]; let file = try SelectedLocalFile(url: original.url)
            defer { file.endAccess() }
            let retry = Item(id: UUID(), url: original.url, name: original.name, target: original.target, snapshot: try file.snapshot())
            items.insert(retry, at: index + 1); index += 1; error = nil
            // A retry has its own task id and always performs a fresh target check.
            _ = context; startOrContinue()
        } catch { self.error = error.localizedDescription }
    }
    func cancelAll() {
        guard isLocked else { return }
        cancelledAll = true
        for i in items.indices where items[i].state == .waiting {
            items[i].state = .cancelled
            if let context {
                let job = TransferJob(direction: .upload, endpoint: context.endpoint, path: context.path,
                                      encoding: context.encoding, credentials: context.credentials, localURL: items[i].url)
                job.finish(.cancelled); onFinish?(job, items[i].target, 0)
            }
        }
        if active != nil { cancelCurrent() } else { finishBatch() }
    }
    private func finishBatch() { context = nil; state = .finished; overwriteID = nil; decision = nil }
}

/// Uses a monotonic clock. A sample outside the window is retained only to interpolate its boundary.
struct TransferMetrics {
    struct Estimate: Equatable { let bytes: Int64; let total: Int64?; let speed: Double?; let remaining: Double? }
    private var samples: [(Double, Int64)] = []
    private var lastChange: Double?
    private(set) var bytes: Int64 = 0
    private(set) var total: Int64?
    mutating func sample(bytes: Int64, total: Int64, at time: Double) {
        guard time.isFinite, time >= (samples.last?.0 ?? -Double.infinity), bytes >= self.bytes else { return }
        let next = max(0, bytes)
        if next > self.bytes { lastChange = time }
        self.bytes = next; self.total = total >= 0 ? max(next, total) : nil
        if samples.last?.0 == time { samples[samples.count - 1].1 = next }
        else { samples.append((time, next)) }
        while samples.count > 2 && samples[1].0 <= time - 5 { samples.removeFirst() }
    }
    func estimate(at time: Double) -> Estimate {
        guard time.isFinite, let first = samples.first, let last = samples.last,
              let changed = lastChange, time >= last.0, time - changed < 5 else {
            return Estimate(bytes: bytes, total: total, speed: nil, remaining: nil)
        }
        let boundary = max(first.0, time - 5)
        var baseline = Double(first.1)
        if samples.count > 1, first.0 < boundary {
            let second = samples[1]
            if second.0 > first.0 { baseline += Double(second.1 - first.1) * (boundary - first.0) / (second.0 - first.0) }
        }
        let elapsed = time - boundary
        let rate = elapsed > 0 ? (Double(bytes) - baseline) / elapsed : 0
        let speed = rate.isFinite && rate > 0 ? rate : nil
        let eta = total.flatMap { size -> Double? in
            guard size > 0, let speed else { return nil }
            let value = Double(max(0, size - bytes)) / speed
            return value.isFinite ? value : nil
        }
        return Estimate(bytes: bytes, total: total, speed: speed, remaining: eta)
    }
}

@MainActor
final class TransferMetricsMonitor: ObservableObject {
    @Published private(set) var estimate = TransferMetrics.Estimate(bytes: 0, total: nil, speed: nil, remaining: nil)
    private var metrics = TransferMetrics()
    private var lastEmission = -Double.infinity
    private let clock: () -> Double
    private var timer: Timer?
    init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }
    func reset(total: Int64) {
        timer?.invalidate(); metrics = TransferMetrics(); lastEmission = -Double.infinity
        metrics.sample(bytes: 0, total: total, at: clock())
        estimate = metrics.estimate(at: clock())
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit() }
        }
    }
    @discardableResult
    func update(bytes: Int64, total: Int64) -> Bool {
        metrics.sample(bytes: bytes, total: total, at: clock())
        return emit()
    }
    @discardableResult
    func emit() -> Bool {
        let now = clock()
        guard now - lastEmission >= 1 else { return false }
        lastEmission = now; estimate = metrics.estimate(at: now); return true
    }
    var bytes: Int64 { metrics.bytes }
    func stop() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }
}
