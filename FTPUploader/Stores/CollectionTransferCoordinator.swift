import Combine
import Foundation

/// Owns collection preparation, retry ancestry and subscriptions for every session queue.
@MainActor
final class CollectionTransferCoordinator {
    final class Preparation {
        let endpoint: FTPEndpoint
        let remoteRoot: RemotePath
        let encoding: FTPTextEncoding
        let credentials: FTPCredentials
        var roots: [LocalSourceRoot] = []
        var sources: [UUID: LocalSourceRoot] = [:]
        var destination: LocalDestinationRoot?
        var isRetry = false
        var retryOrigin: BatchTransferQueue?
        var retryHoldID: UUID?
        var heldQueues: [BatchTransferQueue] = []
        init(endpoint: FTPEndpoint, remoteRoot: RemotePath, encoding: FTPTextEncoding, credentials: FTPCredentials) {
            self.endpoint = endpoint; self.remoteRoot = remoteRoot; self.encoding = encoding; self.credentials = credentials
        }
        @MainActor
        func endRetryPreparation() {
            retryOrigin?.endCollectionRetry()
            if let id = retryHoldID { heldQueues.forEach { $0.releaseRetryHold(id) } }
        }
        func release() {
            roots.forEach { $0.endAccess() }; destination?.endAccess()
            roots = []; sources = [:]; destination = nil
        }
    }
    let scan = TransferScanSession()
    let batch: BatchTransferQueue
    private(set) var retryBatch: BatchTransferQueue {
        didSet { onRetryQueueChange?(retryBatch) }
    }
    private(set) var retries: [BatchTransferQueue] = []
    private(set) var preparation: Preparation?
    var queues: [BatchTransferQueue] { [batch] + retries }
    private let client: FTPServing
    private let executor: TransferExecutor
    private let scope: LocalSecurityScope
    private let history: TransferHistory
    private let metrics: TransferMetricsMonitor
    private var observations: [ObjectIdentifier: AnyCancellable] = [:]
    private var scanObservation: AnyCancellable?
    var onChange: (() -> Void)?
    var onRetryQueueChange: ((BatchTransferQueue) -> Void)?

    init(client: FTPServing, executor: TransferExecutor, scope: LocalSecurityScope,
         history: TransferHistory, metrics: TransferMetricsMonitor) {
        self.client = client; self.executor = executor; self.scope = scope
        self.history = history; self.metrics = metrics
        batch = BatchTransferQueue(client: client, executor: executor)
        retryBatch = BatchTransferQueue(client: client, executor: executor)
        observe(batch); observe(retryBatch)
        scanObservation = scan.objectWillChange.sink { [weak self] _ in self?.onChange?() }
        scan.onDiscard = { [weak self] in
            guard let self else { return }
            let context = preparation
            context?.release(); preparation = nil
            context?.endRetryPreparation()
        }
    }
    private func observe(_ queue: BatchTransferQueue) {
        observations[ObjectIdentifier(queue)] = queue.objectWillChange.sink { [weak self] _ in self?.onChange?() }
        queue.onFinish = { [weak self, weak queue] job, target, bytes in
            guard let self, let queue else { return }
            if !queue.isCollection { history.record(job, target: target, bytes: bytes) }
            if !queue.isExecuting { metrics.stop() }
        }
        queue.onHistoryRecord = { [weak self] record in self?.history.record(record) }
        queue.onStart = { [weak self] total in self?.metrics.reset(total: total) }
        queue.onProgress = { [weak self] _, bytes, total in self?.metrics.update(bytes: bytes, total: total, force: true) ?? false }
    }
    func prepareUpload(_ urls: [URL], endpoint: FTPEndpoint, path: RemotePath,
                       encoding: FTPTextEncoding, credentials: FTPCredentials) -> Bool {
        let context = Preparation(endpoint: endpoint, remoteRoot: path, encoding: encoding, credentials: credentials)
        preparation = context
        return scan.start(operation: { [self] token in
            let connection = TransferConnectionOwner(base: client, endpoint: context.endpoint, credentials: context.credentials,
                executor: executor, readOnly: true)
            defer { connection.close() }
            for url in urls {
                try token.checkCancellation()
                context.roots.append(try LocalSourceRoot(url: url, scope: scope))
            }
            let plan = try await LocalTransferScanner().scan(roots: context.roots, destination: context.remoteRoot,
                encoding: context.encoding, cancellation: token, discovered: scan.discoveryHandler(cancellationID: token.id))
            try token.checkCancellation()
            context.sources = Dictionary(uniqueKeysWithValues: zip(plan.roots.map(\.id), context.roots))
            guard plan.canStart else { return plan }
            return try await TransferRetryPlanner().inspectTargets(plan, client: connection, endpoint: context.endpoint,
                credentials: context.credentials, destination: nil, cancellation: token)
        }, redact: { credentials.redacting($0) })
    }
    func prepareDownload(_ selections: [RemoteTransferScanner.Selection], to destination: URL,
                         endpoint: FTPEndpoint, path: RemotePath, encoding: FTPTextEncoding,
                         credentials: FTPCredentials) -> Bool {
        let context = Preparation(endpoint: endpoint, remoteRoot: path, encoding: encoding, credentials: credentials)
        preparation = context
        return scan.start(operation: { [self] token in
            let connection = TransferConnectionOwner(base: client, endpoint: context.endpoint, credentials: context.credentials,
                executor: executor, readOnly: true)
            defer { connection.close() }
            try token.checkCancellation()
            let root = try LocalDestinationRoot(url: destination, scope: scope)
            context.destination = root
            let plan = try await RemoteTransferScanner(client: connection).scan(endpoint: context.endpoint, selections: selections,
                destination: root, credentials: context.credentials, cancellation: token,
                discovered: scan.discoveryHandler(cancellationID: token.id))
            guard plan.canStart else { return plan }
            return try await TransferRetryPlanner().inspectTargets(plan, client: connection, endpoint: context.endpoint,
                credentials: context.credentials, destination: root, cancellation: token)
        }, redact: { credentials.redacting($0) })
    }
    func prepareRetry(origin: BatchTransferQueue, itemID: UUID?, endpoint: FTPEndpoint?,
                      currentCredentials: () -> FTPCredentials?) -> Bool {
        guard let request = origin.beginCollectionRetry(itemID: itemID) else { return false }
        let credentials: FTPCredentials
        if let fixed = request.fixedCredentials { credentials = fixed }
        else {
            guard endpoint == request.endpoint, let current = currentCredentials() else {
                origin.endCollectionRetry(); return false
            }
            credentials = current
        }
        let context = Preparation(endpoint: request.endpoint, remoteRoot: request.remoteRoot,
            encoding: request.encoding, credentials: credentials)
        context.isRetry = true; context.retryOrigin = origin
        let holdID = UUID(); context.retryHoldID = holdID
        context.heldQueues = queues.filter { $0 !== origin && $0.state == .paused }
        context.heldQueues.forEach { $0.holdForRetry(holdID) }
        preparation = context
        let started = scan.start(operation: { [self] token in
            let connection = TransferConnectionOwner(base: client, endpoint: context.endpoint, credentials: context.credentials,
                executor: executor, readOnly: true)
            defer { connection.close() }
            let plan = TransferRetryPlanner.remap(request.plan)
            if plan.direction == .upload {
                for root in plan.roots {
                    try token.checkCancellation()
                    guard case .local(let url) = root.source else { throw FTPError.invalidName }
                    let access = try LocalSourceRoot(url: url, scope: scope)
                    context.roots.append(access); context.sources[root.id] = access
                    guard access.identity.kind == root.kind else { throw FTPError.localFile("重试来源根类型变化。") }
                }
                let result = try await TransferRetryPlanner().upload(plan, sources: context.sources, cancellation: token)
                return try await TransferRetryPlanner().inspectTargets(result, client: connection, endpoint: context.endpoint,
                    credentials: context.credentials, destination: nil, cancellation: token)
            }
            guard let url = request.destinationURL else { throw FTPError.localFile("重试目的根丢失。") }
            let destination = try LocalDestinationRoot(url: url, scope: scope)
            context.destination = destination
            let lease = try destination.lease()
            defer { withExtendedLifetime(lease) {} }
            let result = try await TransferRetryPlanner().download(plan, client: connection, endpoint: context.endpoint,
                credentials: context.credentials, cancellation: token)
            let checked = try await TransferRetryPlanner().inspectTargets(result, client: connection, endpoint: context.endpoint,
                credentials: context.credentials, destination: destination, cancellation: token)
            try destination.validateIdentity()
            return checked
        }, redact: { credentials.redacting($0) })
        if !started {
            context.release(); preparation = nil; context.endRetryPreparation()
        }
        return started
    }
    func confirm(_ planID: UUID, policy: TransferConflictPolicy) throws -> Bool {
        guard scan.phase == .preview, let plan = scan.plan, plan.id == planID,
              plan.canStart, let context = preparation else { return false }
        let queue = context.isRetry ? BatchTransferQueue(client: client, executor: executor) : batch
        guard !queue.isLocked, !context.isRetry || context.retryOrigin?.retryPending == true else { return false }
        do {
            try queue.prepare(plan: plan, endpoint: context.endpoint, remoteRoot: context.remoteRoot,
                encoding: context.encoding, credentials: context.credentials, sources: context.sources, destination: context.destination)
        } catch { throw FTPError.localFile(context.credentials.redacting(error.localizedDescription)) }
        guard queue.chooseConflictPolicy(policy, planID: planID), scan.consume(planID: planID) else { return false }
        preparation = nil // Queue now owns roots and fixed authentication.
        if context.isRetry {
            let origin = context.retryOrigin!, holdID = context.retryHoldID!, held = context.heldQueues
            origin.acceptCollectionRetry()
            retryBatch = queue; retries.append(queue)
            observe(queue)
            queue.onEnd = { [weak self, weak queue] in
                origin.endCollectionRetry()
                held.forEach { $0.releaseRetryHold(holdID) }
                if origin !== self?.batch, origin.state == .paused, self?.retryBatch === queue {
                    self?.retryBatch = origin
                }
            }
        } else {
            retries = []
            observations = observations.filter { $0.key == ObjectIdentifier(batch) }
            retryBatch = BatchTransferQueue(client: client, executor: executor)
            observe(retryBatch)
        }
        queue.startOrContinue()
        return true
    }
}
