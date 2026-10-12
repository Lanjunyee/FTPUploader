import Foundation

/// Opt-in measurement boundary. Only fixed event names and numeric totals are retained;
/// credentials, paths, key bytes and digests cannot enter the counter API.
final class TransferDiagnostics: @unchecked Sendable {
    enum Event: String, CaseIterable, Codable {
        case listings, connections, authentications, hashPasses, hashBytes, notifications
        case planRootKeys, planNodeMembershipChecks, planIndexNodes
        case planNodeLookups, planRootLookups, planDirectoryLookups
        case summarySnapshots, summaryNodes, queueIndexNodes, queueItemLookups, dependencyLookups
    }
    private let lock = NSLock()
    private var totals: [Event: Int64] = [:]

    func record(_ event: Event, count: Int64 = 1) {
        guard count >= 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let sum = (totals[event] ?? 0).addingReportingOverflow(count)
        totals[event] = sum.overflow ? Int64.max : sum.partialValue
    }

    var snapshot: [String: Int64] {
        lock.lock(); defer { lock.unlock() }
        return Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0.rawValue, totals[$0] ?? 0) })
    }
}

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
    let historyAdmission = TransferHistoryAdmission()
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
            dependencyDescription(lookup: { id in items.first { $0.id == id } })
        }
        func dependencyDescription(lookup: (UUID) -> Item?) -> String? {
            let dependency: UUID?
            if case .blocked(let id, _) = state { dependency = id } else { dependency = parentID }
            guard let dependency else { return nil }
            guard let parent = lookup(dependency) else { return "父目录依赖：" + dependency.uuidString }
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
    private var displayRevision: UInt64 = 0
    private var itemPositions: [UUID: Int] = [:]
    @Published private(set) var items: [Item] = [] { didSet { displayRevision &+= 1 } }
    @Published private(set) var state: State = .finished { didSet {
        displayRevision &+= 1
        if state == .paused { connection?.pause() }
    } }
    @Published private(set) var error: String?
    @Published private(set) var overwriteID: UUID? {
        didSet { if overwriteID == nil { overwriteNodeID = nil } }
    }
    @Published private(set) var overwriteNodeID: UUID?
    var overwriteTarget: String? { overwriteNodeID.flatMap { item(id: $0)?.target } }
    @Published private(set) var conflictPolicy = TransferConflictPolicy.ask
    private let client: FTPServing
    private let diagnostics: TransferDiagnostics?
    private var files: FileTransferRunner
    private var connection: TransferConnectionOwner?
    private let connectionScheduler: TransferConnectionOwner.Scheduler
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
    private var taskStates: [UUID: TransferTaskState] = [:] { didSet { displayRevision &+= 1 } }
    private struct SummaryKey: Equatable {
        let revision: UInt64
        let finished: Bool
        let activeID: UUID?
        let activeBytes: Int64
        let activeOverflow: Bool
    }
    private var summaryKey: SummaryKey?
    private var summarySnapshot: TransferSummary?
    private var childIndices: [UUID: [Int]] = [:]
    var taskResults: [UUID: TransferTaskResult] {
        taskStates.reduce(into: [:]) { values, pair in
            if let result = pair.value.result { values[pair.key] = result }
        }
    }
    var summary: TransferSummary? {
        guard !taskStates.isEmpty else { return nil }
        let counterBytes = active?.byteCounter.bytes ?? 0, counterOverflow = active?.byteCounter.hasOverflow ?? false
        let key = SummaryKey(revision: displayRevision, finished: state == .finished && !isLocked,
            activeID: active?.id, activeBytes: counterBytes, activeOverflow: counterOverflow)
        if summaryKey == key { return summarySnapshot }
        let activeItemID = active != nil && items.indices.contains(index) ? items[index].id : nil
        let projected = items.lazy.compactMap { [self] item -> TransferSummary.Entry? in
            guard taskStates[item.id] != nil else { return nil }
            return .init(id: item.id, target: item.target, kind: item.kind == .directory ? .directory : .file,
                  direction: item.direction, result: item.state.terminalResult, size: item.snapshot?.size ?? item.sizeHint,
                  successfulBytes: item.successfulBytes,
                  actualBytes: item.id == activeItemID ? max(item.actualBytes, counterBytes) : item.actualBytes,
                  trafficOverflow: item.trafficOverflow || (item.id == activeItemID && counterOverflow))
        }
        let snapshot = TransferSummary(projecting: projected, isFinished: key.finished, diagnostics: diagnostics)
        summaryKey = key; summarySnapshot = snapshot
        return snapshot
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

    init(client: FTPServing, executor: TransferExecutor, diagnostics: TransferDiagnostics? = nil,
         connectionScheduler: @escaping TransferConnectionOwner.Scheduler = TransferConnectionOwner.scheduleIdle) {
        self.client = client; self.executor = executor; self.diagnostics = diagnostics; self.connectionScheduler = connectionScheduler
        files = FileTransferRunner(client: client, executor: executor)
    }

    private func replaceItems(_ replacement: [Item]) {
        summaryKey = nil; summarySnapshot = nil
        itemPositions = Dictionary(replacement.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        diagnostics?.record(.queueIndexNodes, count: Int64(replacement.count))
        items = replacement
    }
    private func insertItem(_ item: Item, at position: Int) {
        items.insert(item, at: position)
        for index in position..<items.count { itemPositions[items[index].id] = index }
        diagnostics?.record(.queueIndexNodes, count: Int64(items.count - position))
    }
    func item(id: UUID) -> Item? {
        diagnostics?.record(.queueItemLookups)
        guard let position = itemPositions[id], items.indices.contains(position) else { return nil }
        return items[position]
    }
    func dependencyDescription(for item: Item) -> String? {
        diagnostics?.record(.dependencyLookups)
        return item.dependencyDescription(lookup: { self.item(id: $0) })
    }
    var displayPhaseTitle: String {
        switch state {
        case .scanning: return "正在核对来源"
        case .preview: return "待核对"
        case .running:
            if items.indices.contains(index) {
                if items[index].state == .awaitingOverwrite { return "等待本次覆盖确认" }
                if items[index].state == .awaitingCompletion { return "等待服务器最终确认及下载提交" }
            }
            return "串行执行"
        case .paused: return "已暂停，等待明确处理"
        case .cancelling: return "正在取消，等待资源释放"
        case .finished: return isLocked ? "等待重试资源释放" : "已结束"
        }
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
        connection?.close()
        let owner = TransferConnectionOwner(base: client, endpoint: endpoint, credentials: credentials, executor: executor, schedule: connectionScheduler)
        connection = owner; self.files = FileTransferRunner(client: owner, executor: executor)
        replaceItems([]); context = Context(endpoint: endpoint, path: path, encoding: encoding, credentials: credentials)
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
                replaceItems(prepared); state = .preview
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
        let owner = TransferConnectionOwner(base: client, endpoint: endpoint, credentials: credentials, executor: executor, schedule: connectionScheduler)
        let execution = try CollectionTransferExecution(plan: plan, endpoint: endpoint, remoteRoot: remoteRoot,
            credentials: credentials, client: owner, executor: executor, sources: sources, destination: destination)
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
        connection?.close(); connection = owner
        collection = execution; conflictPolicy = .ask
        context = Context(endpoint: endpoint, path: remoteRoot, encoding: encoding, credentials: credentials, direction: plan.direction)
        replaceItems(prepared); index = 0; cancelledAll = false; error = nil; taskStates = [:]; childIndices = [:]
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
        connection?.resume()
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
            let progressGeneration = job.id, expectedBytes = snapshot.size
            let progressBox = makeProgressMailbox(job: job, index: current, itemID: item.id)
            defer { progressBox.stop() }
            do {
                try await files.run(job, preparing: {
                    let selected = try SelectedLocalFile(url: item.url); file = selected
                    guard try await selected.snapshot(cancellation: job.cancellation) == snapshot else {
                        throw FTPError.localFile("等待期间文件已变化，请明确重试以重新核对：" + item.name)
                    }
                    let existing = try await ((connection as FTPServing?) ?? client).checkUploadTarget(endpoint: job.endpoint, path: job.path, name: item.name,
                                                                     encoding: job.encoding, credentials: job.credentials, cancellation: job.cancellation)
                    try job.cancellation.checkCancellation()
                    if let existing {
                        guard existing.kind == .regularFile else { throw FTPError.uploadTargetConflict }
                        items[current].state = .awaitingOverwrite; overwriteNodeID = item.id; overwriteID = UUID()
                        connection?.pause()
                        try await withCheckedThrowingContinuation { decision = $0 }
                        try job.cancellation.checkCancellation()
                        guard try await selected.snapshot(cancellation: job.cancellation) == snapshot else { throw FTPError.localFile("覆盖授权后文件发生变化，请重新核对。") }
                    }
                    job.uploadSource = try await selected.verifiedSource(matching: snapshot, cancellation: job.cancellation)
                    items[current].state = .running
                }, progress: { bytes, _ in
                    progressBox.submit(bytes: bytes, total: expectedBytes, generation: progressGeneration)
                    if bytes >= expectedBytes { progressBox.signalContentSent() }
                })
                items[current].bytes = job.completedFileBytes; items[current].successfulBytes = job.completedFileBytes
                setTerminal(current, .succeeded)
            } catch {
                if !(error is TransferSkipped) { connection?.stopAfterFailure() }
                setTerminal(current, job.cancellation.isCancelled || error is CancellationError ? .cancelled : (error is TransferSkipped ? .skipped : .failed(job.credentials.redacting(error.localizedDescription))))
            }
            actualBytes = job.byteCounter.bytes
            items[current].actualBytes = actualBytes; items[current].trafficOverflow = job.byteCounter.hasOverflow
            file?.endAccess(); active = nil; overwriteID = nil; decision = nil
            onFinish?(job, item.target, max(actualBytes, items[current].bytes))
            if cancelledAll { finishBatch(); return }
            if ![ItemState.succeeded, .skipped].contains(items[current].state) { state = .paused; return }
            index += 1
        }
        finishBatch()
    }

    private func makeProgressMailbox(job: TransferJob, index: Int, itemID: UUID) -> TransferProgressMailbox {
        TransferProgressMailbox(generation: job.id, contentSent: { [weak self, weak job] in
            guard let self, let job, self.active === job, job.outcome == nil, !job.cancellation.isCancelled,
                  self.items.indices.contains(index), [.running, .awaitingCompletion].contains(self.items[index].state) else { return }
            self.items[index].state = .awaitingCompletion
        }, deliver: { [weak self, weak job] sample in
            guard let self, let job, self.active === job, job.outcome == nil, !job.cancellation.isCancelled,
                  self.items.indices.contains(index), [.running, .awaitingCompletion].contains(self.items[index].state) else { return }
            self.actualBytes = max(self.actualBytes, sample.bytes)
            if self.onProgress?(itemID, sample.bytes, sample.total) ?? true { self.items[index].bytes = self.actualBytes }
        })
    }

    private func runCollection() async {
        while index < items.count, !cancelledAll, let execution = collection, let context {
            let current = index, node = execution.plan.nodes[current]
            switch items[current].state {
            case .skipped, .blocked: index += 1; continue
            default: break
            }
            guard items[current].state == .waiting else { state = .paused; return }
            if let parent = node.parentID, execution.plan.index.positionByID[parent].map { items[$0].state } != .succeeded {
                error = "父目录未成功，不能执行子项。"; state = .paused; return
            }
            let job: TransferJob
            do { job = try execution.job(for: node) }
            catch { self.error = context.credentials.redacting(error.localizedDescription); state = .paused; return }
            active = job; items[current].started = job.started; items[current].state = .running; actualBytes = 0; onStart?(node.size ?? -1)
            let progressGeneration = job.id, expectedBytes = node.size ?? -1, isUpload = job.direction == .upload
            let progressBox = makeProgressMailbox(job: job, index: current, itemID: node.id)
            defer { progressBox.stop() }
            do {
                items[current].reusedDirectory = try await execution.execute(node, job: job, decide: {
                    try job.cancellation.checkCancellation()
                    items[current].state = .awaitingOverwrite; overwriteNodeID = node.id; overwriteID = UUID()
                    connection?.pause()
                    try await withCheckedThrowingContinuation { decision = $0 }
                    try job.cancellation.checkCancellation()
                    items[current].state = .running
                }, cleanupFailure: { warning in
                    self.error = context.credentials.redacting(warning.localizedDescription)
                }, progress: { bytes, total in
                    progressBox.submit(bytes: bytes, total: isUpload ? expectedBytes : total, generation: progressGeneration)
                    let complete = isUpload ? expectedBytes >= 0 && bytes >= expectedBytes
                        : (total > 0 || (total == 0 && expectedBytes == 0)) && bytes >= total
                    if complete { progressBox.signalContentSent() }
                })
                items[current].bytes = node.kind == .directory ? 0 : job.completedFileBytes
                items[current].successfulBytes = items[current].bytes
                setTerminal(current, .succeeded)
            } catch {
                if !(error is TransferSkipped) { connection?.stopAfterFailure() }
                let cancelled = job.cancellation.isCancelled || error is CancellationError
                let message = context.credentials.redacting(error.localizedDescription)
                let skipped = error is TransferSkipped
                job.finish(cancelled ? .cancelled : (skipped ? .skipped("用户明确跳过同名文件") : .failed(message)))
                setTerminal(current, cancelled ? .cancelled : (skipped ? .skipped : .failed(message)))
            }
            actualBytes = node.kind == .directory ? 0 : job.byteCounter.bytes
            items[current].actualBytes = actualBytes
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
        connection?.resume()
        decision = nil; overwriteID = nil; continuation.resume()
    }
    func cancelOverwrite(_ id: UUID) {
        guard overwriteID == id, decision != nil else { return }
        cancelCurrent()
    }
    func skipOverwrite(_ id: UUID) {
        guard overwriteID == id, let continuation = decision else { return }
        connection?.resume()
        decision = nil; overwriteID = nil; continuation.resume(throwing: TransferSkipped.requested)
    }
    func cancelCurrent() {
        if preparationCancellation != nil { cancelAll(); return }
        guard let active else { return }
        active.cancellation.cancel(); connection?.stopAfterFailure()
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
        if let task = taskStates[items[i].id] {
            onResult?(items[i].id, result)
            if let collection, let context {
                let item = items[i]
                onHistoryRecord?(.task(id: item.id, direction: item.direction,
                    kind: item.kind == .directory ? .directory : .file, name: item.name,
                    endpoint: context.endpoint, target: item.target, credentials: context.credentials,
                    result: result, started: item.started ?? Date(), bytes: item.actualBytes, batchID: collection.plan.id,
                    admission: task.historyAdmission, trafficOverflow: item.trafficOverflow))
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
        let states = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.state) })
        var included = Set(failures)
        // Include only failure-blocked paths rooted in the selected failure(s).
        for node in plan.nodes {
            guard case .blocked(_, .failedAncestor) = states[node.id] else { continue }
            var parent = node.parentID
            while let id = parent {
                if included.contains(id) { included.insert(node.id); break }
                parent = plan.index.node(id: id)?.parentID
            }
        }
        for id in Array(included) {
            var parent = plan.index.node(id: id)?.parentID
            while let ancestor = parent {
                guard let node = plan.index.node(id: ancestor), node.kind == .directory else { return nil }
                included.insert(ancestor); parent = node.parentID
            }
        }
        let nodes = plan.nodes.filter { included.contains($0.id) }
        let rootIDs = Set(nodes.map(\.rootID))
        let roots = plan.roots.filter { rootIDs.contains($0.id) }
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
                insertItem(retry, at: index + 1); index += 1; error = nil
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
        connection?.close(); connection = nil
        files = FileTransferRunner(client: client, executor: executor)
        collection?.release(); collection = nil; context = nil
        state = .finished; overwriteID = nil; decision = nil
        onEnd?()
    }
}

/// Uses a monotonic clock. A sample outside the window is retained only to interpolate its boundary.
/// One cancellable display delivery per fixed attempt. Backend byte counters remain
/// separate and must sample every callback; control/terminal events never wait here.
final class TransferProgressMailbox: @unchecked Sendable {
    struct Sample: Equatable, Sendable { let generation: UUID; let bytes: Int64; let total: Int64 }
    typealias Scheduler = (Double, @escaping () -> Void) -> DispatchWorkItem
    private let lock = NSLock()
    private let generation: UUID
    private let clock: () -> Double
    private let schedule: Scheduler
    private let deliver: @MainActor (Sample) -> Void
    private let contentSent: (@MainActor () -> Void)?
    private var contentSentQueued = false
    private var active = true, pending = false, dirty = false
    private var latest: Sample?
    private var lastEmission = -Double.infinity
    private var observedTime = -Double.infinity
    private var ticket: UInt64 = 0
    private var scheduled: DispatchWorkItem?
    var pendingNotificationCount: Int { lock.lock(); defer { lock.unlock() }; return pending ? 1 : 0 }

    init(generation: UUID, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping Scheduler = { delay, work in
             let item = DispatchWorkItem(block: work)
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
             return item
         }, contentSent: (@MainActor () -> Void)? = nil, deliver: @escaping @MainActor (Sample) -> Void) {
        self.generation = generation; self.clock = clock; self.schedule = schedule; self.deliver = deliver
        self.contentSent = contentSent
    }
    func submit(bytes: Int64, total: Int64, generation: UUID) {
        lock.lock()
        guard active, generation == self.generation, bytes >= 0,
              bytes >= (latest?.bytes ?? 0) else { lock.unlock(); return }
        let now = clock()
        guard now.isFinite else { lock.unlock(); return }
        observedTime = max(observedTime, now)
        let sample = Sample(generation: generation, bytes: bytes, total: total < 0 ? -1 : max(bytes, total))
        guard sample != latest else { lock.unlock(); return }
        latest = sample; dirty = true
        guard !pending else { lock.unlock(); return }
        pending = true; ticket &+= 1
        let nextTicket = ticket, delay = max(0, lastEmission + 1 - observedTime)
        lock.unlock()
        enqueue(ticket: nextTicket, delay: delay)
    }
    private func enqueue(ticket: UInt64, delay: Double) {
        let item = schedule(delay) { [weak self] in
            Task { @MainActor [weak self] in self?.flush(ticket: ticket) }
        }
        lock.lock()
        if active, pending, self.ticket == ticket { scheduled = item; lock.unlock() }
        else { lock.unlock(); item.cancel() }
    }
    @MainActor private func flush(ticket: UInt64) {
        lock.lock()
        guard active, pending, self.ticket == ticket, let sample = latest else { lock.unlock(); return }
        let now = clock()
        guard now.isFinite else { pending = false; dirty = false; scheduled = nil; lock.unlock(); return }
        observedTime = max(observedTime, now)
        let delay = max(0, lastEmission + 1 - observedTime)
        scheduled = nil
        if delay > 0 {
            self.ticket &+= 1
            let nextTicket = self.ticket
            lock.unlock(); enqueue(ticket: nextTicket, delay: delay); return
        }
        dirty = false; lastEmission = observedTime
        lock.unlock()
        deliver(sample)
        // Submissions during delivery may update the latest sample, but cannot enqueue
        // another callback until this delivery returns and the next display slot is due.
        lock.lock()
        guard active, self.ticket == ticket else { lock.unlock(); return }
        pending = false
        if dirty {
            pending = true; self.ticket &+= 1
            let nextTicket = self.ticket, delay = max(0, lastEmission + 1 - observedTime)
            lock.unlock(); enqueue(ticket: nextTicket, delay: delay)
        } else { lock.unlock() }
    }
    /// A once-only phase hint uses an independent immediate control event, not the display slot.
    func signalContentSent() {
        lock.lock()
        guard active, !contentSentQueued, contentSent != nil else { lock.unlock(); return }
        contentSentQueued = true; lock.unlock()
        Task { @MainActor [weak self] in self?.publishContentSent() }
    }
    @MainActor private func publishContentSent() {
        lock.lock(); let allowed = active && contentSentQueued; lock.unlock()
        if allowed { contentSent?() }
    }
    @discardableResult func stop() -> Sample? {
        lock.lock()
        let finalSample = latest
        active = false; pending = false; dirty = false; latest = nil; ticket &+= 1
        let item = scheduled; scheduled = nil
        lock.unlock(); item?.cancel()
        return finalSample
    }
    deinit { scheduled?.cancel() }
}

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
    func update(bytes: Int64, total: Int64, force: Bool = false) -> Bool {
        metrics.sample(bytes: bytes, total: total, at: clock())
        return emit(force: force)
    }
    func finish(bytes: Int64, total: Int64) {
        _ = update(bytes: bytes, total: total, force: true)
        stop()
    }
    @discardableResult
    func emit(force: Bool = false) -> Bool {
        let now = clock()
        // Mailbox deliveries are already rate-limited; align the timer with that slot
        // rather than suppressing every delivery when the timer has a different phase.
        guard force || now - lastEmission >= 1 else { return false }
        lastEmission = now; estimate = metrics.estimate(at: now); return true
    }
    var bytes: Int64 { metrics.bytes }
    func stop() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }
}
