import Foundation
import Combine

/// Generation-isolated scan publication. No credentials or resumable data are persisted.
@MainActor
final class TransferScanSession: ObservableObject {
    @Published private(set) var phase: TransferBatchPhase = .finished
    @Published private(set) var plan: TransferPlan?
    @Published private(set) var error: String?
    @Published private(set) var discoveredNodes = 0
    private(set) var generation = UUID()
    private var cancellation: FTPCancellationToken?
    private var progressMailbox: TransferProgressMailbox?
    var isLocked: Bool { phase.isLocked }
    var cancellationID: UUID? { cancellation?.id ?? (phase == .preview ? generation : nil) }
    /// Called before unlocking a cancelled/failed scan or a discarded preview.
    var onDiscard: (() -> Void)?

    @discardableResult
    func start(operation: @escaping (FTPCancellationToken) async throws -> TransferPlan,
               redact: @escaping (String) -> String = { _ in "来源扫描失败，请检查所选项目。" }) -> Bool {
        guard phase == .finished, cancellation == nil else { return false }
        let id = UUID(), token = FTPCancellationToken()
        generation = id; cancellation = token; plan = nil; error = nil; discoveredNodes = 0; phase = .scanning
        let mailbox = TransferProgressMailbox(generation: token.id) { [weak self] sample in
            self?.discovered(Int(clamping: sample.bytes), cancellationID: token.id)
        }
        progressMailbox = mailbox
        Task {
            defer {
                mailbox.stop()
                if progressMailbox === mailbox { progressMailbox = nil }
            }
            do {
                let result = try await operation(token)
                try token.checkCancellation()
                guard generation == id, cancellation === token else { return }
                discoveredNodes = min(TransferPlan.maximumNodes, max(discoveredNodes, result.nodes.count))
                plan = result; phase = .preview
            } catch {
                guard cancellation === token else { return }
                if !(error is CancellationError) && !token.isCancelled { self.error = redact(error.localizedDescription) }
                plan = nil; onDiscard?(); phase = .finished
            }
            if cancellation === token { cancellation = nil }
        }
        return true
    }

    func discoveryHandler(cancellationID: UUID) -> (Int) -> Void {
        guard phase == .scanning, cancellation?.id == cancellationID, let mailbox = progressMailbox else { return { _ in } }
        return { [weak mailbox] count in
            mailbox?.submit(bytes: Int64(clamping: max(0, count)), total: -1, generation: cancellationID)
        }
    }

    func discovered(_ count: Int, cancellationID: UUID) {
        guard phase == .scanning, cancellation?.id == cancellationID else { return }
        discoveredNodes = min(TransferPlan.maximumNodes, max(discoveredNodes, count))
    }

    func cancel(id: UUID? = nil) {
        if let id, id != cancellationID { return }
        guard phase == .scanning || phase == .preview else { return }
        progressMailbox?.stop()
        generation = UUID(); plan = nil
        if let cancellation { phase = .cancelling; cancellation.cancel() }
        else { onDiscard?(); phase = .finished }
    }

    /// The caller first transfers root ownership into a prepared queue, keeping it locked.
    @discardableResult
    func consume(planID: UUID) -> Bool {
        guard phase == .preview, plan?.id == planID, cancellation == nil else { return false }
        plan = nil; generation = UUID(); phase = .finished
        return true
    }
}
