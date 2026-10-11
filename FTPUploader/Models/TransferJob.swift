import Foundation

enum TransferDirection: String, Codable { case upload, download }
enum TransferOutcome: Equatable { case succeeded, failed(String), cancelled, skipped(String) }

/// Backend callbacks may run off-main. Freeze at backend stop so retained late callbacks
/// cannot add traffic to a finished attempt. Counts payload bytes, not TLS/protocol overhead.
final class TransferByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: Int64 = 0, received: Int64 = 0
    private var closed = false
    private var overflow = false
    var bytes: Int64 { lock.lock(); defer { lock.unlock() }; return max(progress, received) }
    var hasOverflow: Bool { lock.lock(); defer { lock.unlock() }; return overflow }
    func sample(_ bytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        if !closed { progress = max(progress, max(0, bytes)) }
    }
    func receive(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, count >= 0 else { return }
        let (next, exceeded) = received.addingReportingOverflow(Int64(count))
        overflow = overflow || exceeded; received = exceeded ? Int64.max : next
    }
    func finish() { lock.lock(); closed = true; lock.unlock() }
}

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
    var uploadSource: SelectedLocalFile.VerifiedSource?
    let byteCounter = TransferByteCounter()
    var completedFileBytes: Int64 = 0

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
            if error is TransferSkipped { job.finish(.skipped("用户明确跳过同名文件")) }
            else { job.finish(.failed(job.credentials.redacting(error.localizedDescription))) }
            throw error
        }
    }
}

import Combine

@MainActor
final class BatchTransferQueue: ObservableObject, Identifiable {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
    enum State: Equatable { case scanning, preview, running, paused, cancelling, finished }
    enum ItemState: Equatable {
        case waiting, running, awaitingCompletion, awaitingOverwrite, succeeded, cancelled
        case failed(String)
        case skipped
        case blocked(parentID: UUID, reason: TransferTaskResult.DependencyReason)
        var terminalResult: TransferTaskResult? {
            switch self {
            case .succeeded: return .succeeded
            case .failed(let message): return .failed(message)
            case .cancelled: return .cancelled
            case .skipped: return .skipped("用户主动跳过")
            case .blocked(let parent, let reason): return .blocked(parentID: parent, reason: reason)
            default: return nil
            }
        }
        var title: String {
            switch self {
            case .waiting: return "等待"
            case .running: return "正在上传"
            case .awaitingCompletion: return "等待最终确认"
            case .awaitingOverwrite: return "等待覆盖确认"
            case .succeeded: return "成功"
            case .cancelled: return "取消"
            case .failed(let message): return "失败：" + message
            case .skipped: return "跳过"
            case .blocked(_, let reason):
                switch reason {
                case .failedAncestor: return "依赖阻塞：父目录失败"
                case .skippedAncestor: return "依赖阻塞：父目录主动跳过"
                case .cancelledAncestor: return "依赖阻塞：父目录取消"
                }
            }
        }
    }
    struct Item: Identifiable {
        let id: UUID
        let url: URL
        let name: String
        let target: String
        let snapshot: SelectedLocalFile.Snapshot?
        var kind: RemoteEntry.Kind = .regularFile
        var direction: TransferDirection = .upload
        var parentID: UUID?
        var reusedDirectory = false
        var sizeHint: Int64?
        var sizeDescription: String {
            if kind == .directory { return "目录" }
            guard let size = snapshot?.size ?? sizeHint else { return "大小未知" }
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        var state: ItemState = .waiting
        var bytes: Int64 = 0
        var actualBytes: Int64 = 0
        var successfulBytes: Int64 = 0
        var trafficOverflow = false
        var started: Date?
        var directionTitle: String { direction == .upload ? "↑ 上传" : "↓ 下载" }
        var kindTitle: String { kind == .directory ? "目录" : "文件" }
        var statusTitle: String {
            if state == .running {
                if kind == .directory { return direction == .upload ? "正在核对/创建远程目录" : "正在核对/创建本地目录" }
                return direction == .upload ? "正在上传" : "正在下载"
            }
            if state == .succeeded, reusedDirectory { return "成功 · 已有目录复用" }
            return state.title
        }
        func dependencyDescription(in items: [Item]) -> String? {
            let dependency: UUID?
            if case .blocked(let id, _) = state { dependency = id } else { dependency = parentID }
            guard let dependency else { return nil }
            guard let parent = items.first(where: { $0.id == dependency }) else { return "父目录依赖：" + dependency.uuidString }
            return "父目录：" + parent.name + " · " + parent.statusTitle + "\n" + parent.target
        }
        var isEligibleForFailureRetry: Bool {
            switch state {
            case .failed, .blocked(_, .failedAncestor): return true
            default: return false
            }
        }
    }
    private struct Context {
        let endpoint: FTPEndpoint
        let path: RemotePath
        let encoding: FTPTextEncoding
        let credentials: FTPCredentials
        var direction: TransferDirection = .upload
    }
    @Published private(set) var items: [Item] = []
    @Published private(set) var state: State = .finished
    @Published private(set) var error: String?
    @Published private(set) var overwriteID: UUID? {
        didSet { if overwriteID == nil { overwriteNodeID = nil } }
    }
    @Published private(set) var overwriteNodeID: UUID?
    var overwriteTarget: String? { items.first { $0.id == overwriteNodeID }?.target }
    @Published private(set) var conflictPolicy = TransferConflictPolicy.ask
    private let client: FTPServing
    private let files: FileTransferRunner
    private let executor: TransferExecutor
    private var collection: CollectionTransferExecution?
    /// Retains only the confirmed list and paths after execution releases authentication/scopes.
    struct RetryRequest {
        let plan: TransferPlan
        let endpoint: FTPEndpoint
        let remoteRoot: RemotePath
        let encoding: FTPTextEncoding
        let destinationURL: URL?
        let fixedCredentials: FTPCredentials?
    }
    private var retainedPlan: TransferPlan?
    private var retainedEndpoint: FTPEndpoint?
    private var retainedRemoteRoot: RemotePath?
    private var retainedEncoding: FTPTextEncoding?
    private var retainedDestinationURL: URL?
    private(set) var retryPending = false
    private var retryHolds = Set<UUID>()
    private var retryFailureIDs = Set<UUID>()
    var onEnd: (() -> Void)?
    private var context: Context?
    private var active: TransferJob?
    private var preparationCancellation: FTPCancellationToken?
    private var decision: CheckedContinuation<Void, Error>?
    private var cancelledAll = false
    private var index = 0
    private var taskStates: [UUID: TransferTaskState] = [:]
    private var childIndices: [UUID: [Int]] = [:]
    var taskResults: [UUID: TransferTaskResult] {
        taskStates.reduce(into: [:]) { values, pair in
            if let result = pair.value.result { values[pair.key] = result }
        }
    }
    var summary: TransferSummary? {
        guard !taskStates.isEmpty else { return nil }
        return TransferSummary(entries: items.filter { taskStates[$0.id] != nil }.map { item in
            .init(id: item.id, target: item.target, kind: item.kind == .directory ? .directory : .file,
                  direction: item.direction, result: item.state.terminalResult, size: item.snapshot?.size ?? item.sizeHint,
                  successfulBytes: item.successfulBytes,
                  actualBytes: active != nil && items.indices.contains(index) && items[index].id == item.id
                    ? max(item.actualBytes, active?.byteCounter.bytes ?? 0) : item.actualBytes,
                  trafficOverflow: item.trafficOverflow)
        }, isFinished: state == .finished && !isLocked)
    }
    var onResult: ((UUID, TransferTaskResult) -> Void)?
    var onHistoryRecord: ((TransferRecord) -> Void)?
    var isCollection: Bool { collection != nil }
    var collectionPlanID: UUID? { retainedPlan?.id }
    var isLocked: Bool { state != .finished || retryPending || !retryHolds.isEmpty }
    var isExecuting: Bool { active != nil || preparationCancellation != nil }
    var cancellationID: UUID? { active?.cancellation.id ?? preparationCancellation?.id }
    var hasCredentials: Bool { context != nil }
    var retryEndpoint: FTPEndpoint? { retainedEndpoint }
    var canContinue: Bool {
        guard !retryPending, retryHolds.isEmpty, !isExecuting, state == .preview || state == .paused, context != nil else { return false }
        return index >= items.count || items[index].state == .waiting
    }
    var canSkipCurrent: Bool {
        !retryPending && retryHolds.isEmpty && state == .paused && !isExecuting && index < items.count
    }
    func canBeginCollectionRetry(itemID: UUID? = nil) -> Bool {
        guard !retryPending, retryHolds.isEmpty, !isExecuting, state == .paused || state == .finished,
              retainedPlan != nil, retainedEndpoint != nil, retainedRemoteRoot != nil, retainedEncoding != nil,
              state != .paused || context != nil else { return false }
        if let itemID {
            return items.contains { item in
                guard item.id == itemID else { return false }
                if case .failed = item.state { return true }; return false
            }
        }
        return state == .finished && items.contains { if case .failed = $0.state { return true }; return false }
    }
    var onFinish: ((TransferJob, String, Int64) -> Void)?
    var onProgress: ((UUID, Int64, Int64) -> Bool)?
    var onStart: ((Int64) -> Void)?
    private var actualBytes: Int64 = 0

    init(client: FTPServing, executor: TransferExecutor) {
        self.client = client; self.executor = executor; files = FileTransferRunner(client: client, executor: executor)
    }

    func prepare(_ urls: [URL], endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding, credentials: FTPCredentials) throws {
        guard !isLocked, !urls.isEmpty else { throw FTPError.localFile("请先结束当前批次并选择普通文件。") }
        var files: [SelectedLocalFile] = []; var targets = Set<Data>()
        for url in urls {
            let file = try SelectedLocalFile(url: url)
            let bytes = try encoding.encode(file.name); try RemotePath.validateName(bytes)
            guard targets.insert(bytes).inserted else { throw FTPError.localFile("同批目标重名：" + file.name) }
            _ = try endpoint.fileURL(path, name: file.name, encoding: encoding)
            files.append(file)
        }
        let token = FTPCancellationToken()
        preparationCancellation = token
        retainedPlan = nil; retainedEndpoint = nil; retainedRemoteRoot = nil; retainedEncoding = nil; retainedDestinationURL = nil
        items = []; context = Context(endpoint: endpoint, path: path, encoding: encoding, credentials: credentials)
        index = 0; cancelledAll = false; error = nil; taskStates = [:]; childIndices = [:]; state = .scanning
        Task {
            defer { files.forEach { $0.endAccess() }; preparationCancellation = nil }
            do {
                var prepared: [Item] = []
                for file in files {
                    let snapshot = try await file.snapshot(cancellation: token)
                    try token.checkCancellation()
                    prepared.append(Item(id: UUID(), url: file.url, name: file.name,
                        target: endpoint.display + path.display + (path.components.isEmpty ? "" : "/") + file.name,
                        snapshot: snapshot))
                }
                guard preparationCancellation === token, !cancelledAll else { throw CancellationError() }
                items = prepared; state = .preview
            } catch {
                if !(error is CancellationError) { self.error = credentials.redacting(error.localizedDescription) }
                files.forEach { $0.endAccess() }
                preparationCancellation = nil
                finishBatch()
            }
        }
    }

    /// The scanner/coordinator supplies selected roots; preparation remains read-only.
    func prepare(plan: TransferPlan, endpoint: FTPEndpoint, remoteRoot: RemotePath, encoding: FTPTextEncoding,
                 credentials: FTPCredentials, sources: [UUID: LocalSourceRoot] = [:],
                 destination: LocalDestinationRoot? = nil) throws {
        guard !isLocked else { throw FTPError.localFile("请先结束当前批次。") }
        guard Set(plan.nodes.map(\.id)).count == plan.nodes.count else { throw FTPError.localFile("计划节点 id 重复。") }
        let execution = try CollectionTransferExecution(plan: plan, endpoint: endpoint, remoteRoot: remoteRoot,
            credentials: credentials, client: client, executor: executor, sources: sources, destination: destination)
        let prepared = try plan.nodes.map { node -> Item in
            let job = try execution.job(for: node)
            let snapshot: SelectedLocalFile.Snapshot?
            if case .localFile(let value) = node.snapshot { snapshot = value } else { snapshot = nil }
            var item = Item(id: node.id, url: job.localURL, name: job.name,
                            target: job.localURL.path, snapshot: snapshot)
            if case .remote(let target, _) = node.target { item = Item(id: node.id, url: job.localURL,
                name: job.name, target: endpoint.display + target.display, snapshot: snapshot) }
            item.kind = node.kind; item.direction = plan.direction; item.parentID = node.parentID; item.sizeHint = node.size
            return item
        }
        retainedPlan = plan; retainedEndpoint = endpoint; retainedRemoteRoot = remoteRoot
        retainedEncoding = encoding; retainedDestinationURL = destination?.url
        collection = execution; conflictPolicy = .ask
        context = Context(endpoint: endpoint, path: remoteRoot, encoding: encoding, credentials: credentials, direction: plan.direction)
        items = prepared; index = 0; cancelledAll = false; error = nil; taskStates = [:]; childIndices = [:]
        for (i, item) in items.enumerated() {
            if let parent = item.parentID { childIndices[parent, default: []].append(i) }
        }
        state = .preview
    }

    @discardableResult
    func chooseConflictPolicy(_ policy: TransferConflictPolicy, planID: UUID) -> Bool {
        guard state == .preview, collection?.plan.id == planID else { return false }
        conflictPolicy = policy; return true
    }

    func startOrContinue() {
        guard !retryPending, retryHolds.isEmpty, !isExecuting, state == .preview || state == .paused, context != nil else { return }
        guard index < items.count else { finishBatch(); return }
        guard collection?.confirm(policy: conflictPolicy) ?? true else { error = "计划确认已失效。"; return }
        for item in items where taskStates[item.id] == nil {
            taskStates[item.id] = TransferTaskState(id: item.id, kind: item.kind == .directory ? .directory : .file)
        }
        state = .running
        Task { await run() }
    }

    private func run() async {
        if collection != nil { await runCollection(); return }
        while index < items.count, !cancelledAll, let context {
            let current = index
            guard items[current].state == .waiting else { state = .paused; return }
            let item = items[current]
            guard let snapshot = item.snapshot else { error = "普通文件缺少快照。"; state = .paused; return }
            let job = TransferJob(direction: .upload, endpoint: context.endpoint, path: context.path,
                                  encoding: context.encoding, credentials: context.credentials, localURL: item.url)
            active = job; items[current].started = job.started; items[current].state = .running; actualBytes = 0
            onStart?(snapshot.size)
            var file: SelectedLocalFile?
            do {
                try await files.run(job, preparing: {
                    let selected = try SelectedLocalFile(url: item.url); file = selected
                    guard try await selected.snapshot(cancellation: job.cancellation) == snapshot else {
                        throw FTPError.localFile("等待期间文件已变化，请明确重试以重新核对：" + item.name)
                    }
                    let existing = try await client.checkUploadTarget(endpoint: job.endpoint, path: job.path, name: item.name,
                                                                     encoding: job.encoding, credentials: job.credentials, cancellation: job.cancellation)
                    try job.cancellation.checkCancellation()
                    if let existing {
                        guard existing.kind == .regularFile else { throw FTPError.uploadTargetConflict }
                        items[current].state = .awaitingOverwrite; overwriteNodeID = item.id; overwriteID = UUID()
                        try await withCheckedThrowingContinuation { decision = $0 }
                        try job.cancellation.checkCancellation()
                        guard try await selected.snapshot(cancellation: job.cancellation) == snapshot else { throw FTPError.localFile("覆盖授权后文件发生变化，请重新核对。") }
                    }
                    job.uploadSource = try await selected.verifiedSource(matching: snapshot, cancellation: job.cancellation)
                    items[current].state = .running
                }, progress: { [weak self] bytes, total in
                        Task { @MainActor [weak self] in
                            guard let self, self.active === job, !job.cancellation.isCancelled,
                                  [.running, .awaitingCompletion].contains(self.items[current].state) else { return }
                            self.actualBytes = max(self.actualBytes, bytes)
                            if self.onProgress?(item.id, bytes, total) ?? true { self.items[current].bytes = self.actualBytes }
                            let next: ItemState = total >= 0 && bytes >= total ? .awaitingCompletion : .running
                            if self.items[current].state != next { self.items[current].state = next }
                        }
                })
                items[current].bytes = job.completedFileBytes; items[current].successfulBytes = job.completedFileBytes
                setTerminal(current, .succeeded)
            } catch {
                setTerminal(current, job.cancellation.isCancelled || error is CancellationError ? .cancelled : (error is TransferSkipped ? .skipped : .failed(job.credentials.redacting(error.localizedDescription))))
            }
            items[current].actualBytes = job.byteCounter.bytes; items[current].trafficOverflow = job.byteCounter.hasOverflow
            file?.endAccess(); active = nil; overwriteID = nil; decision = nil
            onFinish?(job, item.target, max(actualBytes, items[current].bytes))
            if cancelledAll { finishBatch(); return }
            if ![ItemState.succeeded, .skipped].contains(items[current].state) { state = .paused; return }
            index += 1
        }
        finishBatch()
    }

    private func runCollection() async {
        while index < items.count, !cancelledAll, let execution = collection, let context {
            let current = index, node = execution.plan.nodes[current]
            switch items[current].state {
            case .skipped, .blocked: index += 1; continue
            default: break
            }
            guard items[current].state == .waiting else { state = .paused; return }
            if let parent = node.parentID, items.first(where: { $0.id == parent })?.state != .succeeded {
                error = "父目录未成功，不能执行子项。"; state = .paused; return
            }
            let job: TransferJob
            do { job = try execution.job(for: node) }
            catch { self.error = context.credentials.redacting(error.localizedDescription); state = .paused; return }
            active = job; items[current].started = job.started; items[current].state = .running; actualBytes = 0; onStart?(node.size ?? -1)
            do {
                items[current].reusedDirectory = try await execution.execute(node, job: job, decide: {
                    try job.cancellation.checkCancellation()
                    items[current].state = .awaitingOverwrite; overwriteNodeID = node.id; overwriteID = UUID()
                    try await withCheckedThrowingContinuation { decision = $0 }
                    try job.cancellation.checkCancellation()
                    items[current].state = .running
                }, cleanupFailure: { warning in
                    self.error = context.credentials.redacting(warning.localizedDescription)
                }, progress: { [weak self] bytes, total in
                    Task { @MainActor [weak self] in
                        guard let self, self.active === job, !job.cancellation.isCancelled,
                              [.running, .awaitingCompletion].contains(self.items[current].state) else { return }
                        self.actualBytes = max(self.actualBytes, bytes)
                        if self.onProgress?(node.id, bytes, total) ?? true { self.items[current].bytes = self.actualBytes }
                        self.items[current].state = total >= 0 && bytes >= total ? .awaitingCompletion : .running
                    }
                })
                items[current].bytes = node.kind == .directory ? 0 : job.completedFileBytes
                items[current].successfulBytes = items[current].bytes
                setTerminal(current, .succeeded)
            } catch {
                let cancelled = job.cancellation.isCancelled || error is CancellationError
                let message = context.credentials.redacting(error.localizedDescription)
                let skipped = error is TransferSkipped
                job.finish(cancelled ? .cancelled : (skipped ? .skipped("用户明确跳过同名文件") : .failed(message)))
                setTerminal(current, cancelled ? .cancelled : (skipped ? .skipped : .failed(message)))
            }
            items[current].actualBytes = node.kind == .directory ? 0 : job.byteCounter.bytes
            items[current].trafficOverflow = job.byteCounter.hasOverflow
            active = nil; overwriteID = nil; decision = nil
            onFinish?(job, items[current].target, items[current].actualBytes)
            if cancelledAll { finishBatch(); return }
            if ![ItemState.succeeded, .skipped].contains(items[current].state) { state = .paused; return }
            index += 1
        }
        finishBatch()
    }

    func confirmOverwrite(_ id: UUID) {
        guard overwriteID == id, let continuation = decision else { return }
        decision = nil; overwriteID = nil; continuation.resume()
    }
    func cancelOverwrite(_ id: UUID) {
        guard overwriteID == id, decision != nil else { return }
        cancelCurrent()
    }
    func skipOverwrite(_ id: UUID) {
        guard overwriteID == id, let continuation = decision else { return }
        decision = nil; overwriteID = nil; continuation.resume(throwing: TransferSkipped.requested)
    }
    func cancelCurrent() {
        if preparationCancellation != nil { cancelAll(); return }
        guard let active else { return }
        active.cancellation.cancel()
        if let decision { self.decision = nil; overwriteID = nil; decision.resume(throwing: CancellationError()) }
    }
    @discardableResult
    private func setTerminal(_ i: Int, _ state: ItemState) -> Bool {
        guard items.indices.contains(i), items[i].state.terminalResult == nil, let result = state.terminalResult else { return false }
        if let task = taskStates[items[i].id], !task.finish(result) { return false }
        if i == index, let active, items[i].kind == .regularFile {
            items[i].actualBytes = active.byteCounter.bytes
            items[i].trafficOverflow = active.byteCounter.hasOverflow
        }
        items[i].state = state
        if taskStates[items[i].id] != nil {
            onResult?(items[i].id, result)
            if let collection, let context {
                let item = items[i]
                onHistoryRecord?(.task(id: item.id, direction: item.direction,
                    kind: item.kind == .directory ? .directory : .file, name: item.name,
                    endpoint: context.endpoint, target: item.target, credentials: context.credentials,
                    result: result, started: item.started ?? Date(), bytes: item.actualBytes, batchID: collection.plan.id))
            }
        }
        return true
    }

    private func blockDescendants(of parent: UUID, reason: TransferTaskResult.DependencyReason) {
        var pending = [parent]
        while let dependency = pending.popLast() {
            for i in childIndices[dependency] ?? [] where items[i].state == .waiting {
                if setTerminal(i, .blocked(parentID: dependency, reason: reason)), items[i].kind == .directory {
                    pending.append(items[i].id)
                }
            }
        }
    }
    private func resolveDirectory(_ i: Int) {
        guard items[i].kind == .directory else { return }
        let reason: TransferTaskResult.DependencyReason
        switch items[i].state {
        case .failed: reason = .failedAncestor
        case .skipped: reason = .skippedAncestor
        case .cancelled: reason = .cancelledAncestor
        case .blocked(_, let inherited): reason = inherited
        default: return
        }
        blockDescendants(of: items[i].id, reason: reason)
    }
    private func advanceResolved() {
        while index < items.count {
            switch items[index].state {
            case .skipped, .blocked: index += 1
            default: return
            }
        }
        finishBatch()
    }
    /// Explicitly skips an unstarted node while a confirmed queue is paused.
    func skipItem(_ id: UUID) {
        guard !retryPending, retryHolds.isEmpty, state == .paused, !isExecuting, collection != nil,
              let i = items.firstIndex(where: { $0.id == id }), i >= index, items[i].state == .waiting,
              taskStates[id] != nil else { return }
        setTerminal(i, .skipped); resolveDirectory(i); advanceResolved()
    }
    func skip() {
        guard !retryPending, retryHolds.isEmpty, state == .paused, !isExecuting, index < items.count else { return }
        if collection != nil {
            if items[index].state == .waiting { setTerminal(index, .skipped) }
            resolveDirectory(index)
            index += 1; advanceResolved()
        } else {
            index += 1
            if index >= items.count { finishBatch() }
        }
    }
    /// Freezes the old waiting subtree before taking a fixed-list retry closure.
    /// A nil selection means all failures, and is allowed only for an ended batch.
    func beginCollectionRetry(itemID: UUID? = nil) -> RetryRequest? {
        guard canBeginCollectionRetry(itemID: itemID),
              let plan = retainedPlan, let endpoint = retainedEndpoint,
              let remoteRoot = retainedRemoteRoot, let encoding = retainedEncoding else { return nil }
        let failures: [UUID]
        if let itemID {
            guard let item = items.first(where: { $0.id == itemID }), case .failed = item.state else { return nil }
            failures = [itemID]
        } else {
            guard state == .finished else { return nil }
            failures = items.compactMap { if case .failed = $0.state { return $0.id }; return nil }
        }
        guard !failures.isEmpty else { return nil }
        if state == .paused {
            for id in failures { blockDescendants(of: id, reason: .failedAncestor) }
        }
        let byID = Dictionary(uniqueKeysWithValues: plan.nodes.map { ($0.id, $0) })
        let states = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.state) })
        var included = Set(failures)
        // Include only failure-blocked paths rooted in the selected failure(s).
        for node in plan.nodes {
            guard case .blocked(_, .failedAncestor) = states[node.id] else { continue }
            var parent = node.parentID
            while let id = parent {
                if included.contains(id) { included.insert(node.id); break }
                parent = byID[id]?.parentID
            }
        }
        for id in Array(included) {
            var parent = byID[id]?.parentID
            while let ancestor = parent {
                guard let node = byID[ancestor], node.kind == .directory else { return nil }
                included.insert(ancestor); parent = node.parentID
            }
        }
        let nodes = plan.nodes.filter { included.contains($0.id) }
        let roots = plan.roots.filter { root in nodes.contains { $0.rootID == root.id } }
        let subset = TransferPlan(direction: plan.direction, roots: roots, nodes: nodes)
        guard subset.canStart else { return nil }
        let request = RetryRequest(plan: subset, endpoint: endpoint, remoteRoot: remoteRoot, encoding: encoding,
            destinationURL: retainedDestinationURL, fixedCredentials: state == .paused ? context?.credentials : nil)
        retryFailureIDs = Set(failures)
        retryPending = true; objectWillChange.send()
        return request
    }

    /// Confirmation resolves only the selected old failure cursor, never starts other branches.
    func acceptCollectionRetry() {
        guard retryPending, state == .paused, index < items.count,
              retryFailureIDs.contains(items[index].id) else { return }
        index += 1
        while index < items.count {
            switch items[index].state {
            case .blocked, .skipped: index += 1
            default: return
            }
        }
    }

    func endCollectionRetry() {
        guard retryPending else { return }
        retryPending = false; retryFailureIDs = []; objectWillChange.send()
        if retryHolds.isEmpty, cancelledAll || (state == .paused && index >= items.count) { finishBatch() }
    }

    /// Other paused branches cannot resume while a retry descendant owns the serial executor.
    func holdForRetry(_ id: UUID) { retryHolds.insert(id); objectWillChange.send() }
    func releaseRetryHold(_ id: UUID) {
        retryHolds.remove(id); objectWillChange.send()
        if cancelledAll, retryHolds.isEmpty, !retryPending, !isExecuting { finishBatch() }
    }

    func retry() {
        guard !retryPending, retryHolds.isEmpty, state == .paused, !isExecuting, index < items.count, let context else { return }
        guard collection == nil else { error = "集合失败项须生成新的重试预览。"; return }
        let original = items[index]
        let token = FTPCancellationToken()
        preparationCancellation = token; state = .scanning
        Task {
            var file: SelectedLocalFile?
            defer { file?.endAccess(); preparationCancellation = nil }
            do {
                let selected = try SelectedLocalFile(url: original.url); file = selected
                let snapshot = try await selected.snapshot(cancellation: token)
                try token.checkCancellation()
                let retry = Item(id: UUID(), url: original.url, name: original.name, target: original.target, snapshot: snapshot)
                items.insert(retry, at: index + 1); index += 1; error = nil
                preparationCancellation = nil; state = .paused
                startOrContinue()
            } catch {
                file?.endAccess(); preparationCancellation = nil
                if token.isCancelled { finishBatch() }
                else { self.error = context.credentials.redacting(error.localizedDescription); state = .paused }
            }
        }
    }
    func cancelAll() {
        guard isLocked else { return }
        cancelledAll = true; collection?.invalidate()
        for i in items.indices where items[i].state == .waiting {
            setTerminal(i, .cancelled)
            if let context, taskStates[items[i].id] != nil {
                let job = TransferJob(direction: context.direction, endpoint: context.endpoint, path: context.path,
                                      encoding: context.encoding, credentials: context.credentials, localURL: items[i].url)
                job.finish(.cancelled); onFinish?(job, items[i].target, 0)
            }
        }
        if let preparationCancellation {
            state = .cancelling; preparationCancellation.cancel(); return
        }
        if active != nil { state = .cancelling; cancelCurrent() }
        else if retryPending || !retryHolds.isEmpty { state = .cancelling }
        else { finishBatch() }
    }
    private func finishBatch() {
        collection?.release(); collection = nil; context = nil
        state = .finished; overwriteID = nil; decision = nil
        onEnd?()
    }
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
