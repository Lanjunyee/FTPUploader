import Foundation

enum TransferTaskKind: String, Codable { case file, directory }
enum TransferConflictPolicy { case ask, skipExistingFiles, overwriteExistingFiles }
enum TransferSkipped: Error { case requested }

enum TransferTaskResult: Equatable {
    enum DependencyReason: String, Codable {
        case failedAncestor, skippedAncestor, cancelledAncestor
        var title: String {
            switch self {
            case .failedAncestor: return "父目录失败"
            case .skippedAncestor: return "父目录主动跳过"
            case .cancelledAncestor: return "父目录取消"
            }
        }
    }
    case succeeded
    case failed(String)
    case cancelled
    case skipped(String)
    case blocked(parentID: UUID, reason: DependencyReason)
}

/// Confirmed plan nodes own a write-once terminal result, independent of bounded history.
@MainActor
final class TransferTaskState: Identifiable {
    let id: UUID
    let kind: TransferTaskKind
    private(set) var result: TransferTaskResult?

    init(id: UUID = UUID(), kind: TransferTaskKind) {
        self.id = id; self.kind = kind
    }

    @discardableResult
    func finish(_ result: TransferTaskResult) -> Bool {
        guard self.result == nil else { return false }
        self.result = result
        return true
    }
}

/// Full memory-only results, independent of the history store's 100-record retention.
struct TransferSummary {
    struct Entry: Identifiable {
        let id: UUID
        let target: String
        let kind: TransferTaskKind
        let direction: TransferDirection
        let result: TransferTaskResult?
        let size: Int64?
        let successfulBytes: Int64
        let actualBytes: Int64
        var trafficOverflow = false
    }
    let entries: [Entry]
    let isFinished: Bool
    var fileCount: Int { entries.filter { $0.kind == .file }.count }
    var directoryCount: Int { entries.count - fileCount }
    var completedFiles: Int { entries.filter { $0.kind == .file && $0.result != nil }.count }
    var completedDirectories: Int { entries.filter { $0.kind == .directory && $0.result != nil }.count }
    var succeeded: Int { entries.filter { $0.result == .succeeded }.count }
    var failed: Int { entries.filter { if case .failed = $0.result { return true }; return false }.count }
    var cancelled: Int { entries.filter { $0.result == .cancelled }.count }
    var skipped: Int { entries.filter { if case .skipped = $0.result { return true }; return false }.count }
    var blocked: Int { entries.filter { if case .blocked = $0.result { return true }; return false }.count }
    var totalSize: Int64? { Self.sum(entries.filter { $0.kind == .file }.map(\.size)) }
    var successfulBytes: Int64? {
        Self.sum(entries.filter { $0.kind == .file && $0.result == .succeeded }.map { Optional($0.successfulBytes) })
    }
    /// Original-plan credit uses size hints, not retry traffic or active/uncommitted bytes.
    var plannedSuccessfulBytes: Int64? {
        Self.sum(entries.filter { $0.kind == .file && $0.result == .succeeded }.map(\.size))
    }
    var actualBytes: Int64? {
        guard !entries.contains(where: \.trafficOverflow) else { return nil }
        return Self.sum(entries.map { Optional($0.actualBytes) })
    }
    var allSuccessful: Bool { isFinished && !entries.isEmpty && succeeded == entries.count }
    /// A success fraction, never a claim that terminal failures/skips are 100% success.
    var successFraction: Double {
        guard !entries.isEmpty else { return 0 }
        let fraction = Double(succeeded) / Double(entries.count)
        return allSuccessful ? 1 : min(fraction, Double(1).nextDown)
    }
    var byteSuccessFraction: Double? {
        guard let total = totalSize, total > 0, let credit = plannedSuccessfulBytes else { return nil }
        return allSuccessful ? 1 : min(Double(credit) / Double(total), Double(1).nextDown)
    }
    static func sum(_ values: [Int64?]) -> Int64? {
        var sum: Int64 = 0
        for value in values {
            guard let value, value >= 0 else { return nil }
            let (next, overflow) = sum.addingReportingOverflow(value)
            guard !overflow else { return nil }; sum = next
        }
        return sum
    }
}

struct TransferSessionSummary {
    let original: TransferSummary
    let retries: [TransferSummary]
    var allResults: [TransferSummary.Entry] { original.entries + retries.flatMap(\.entries) }
    var actualBytes: Int64? { TransferSummary.sum(([original] + retries).map(\.actualBytes)) }
    // New attempts do not rewrite the original plan's completion credit or outcomes.
    var successfulBytes: Int64? { original.successfulBytes }
    var allSuccessful: Bool { original.allSuccessful }
}

enum TransferBatchPhase: Equatable {
    case scanning, preview, running, paused, cancelling, finished
    var isLocked: Bool { self != .finished }
}

/// Cancellation is an intermediate phase: the coordinator must await backend/continuation
/// cleanup before calling backendStopped. Preview cancellation has no task results.
@MainActor
final class TransferBatchState {
    private(set) var phase: TransferBatchPhase = .scanning

    @discardableResult
    func scanned() -> Bool { transition(from: [.scanning], to: .preview) }
    @discardableResult
    func start() -> Bool { transition(from: [.preview], to: .running) }
    @discardableResult
    func pause() -> Bool { transition(from: [.running], to: .paused) }
    @discardableResult
    func resume() -> Bool { transition(from: [.paused], to: .running) }
    @discardableResult
    func cancel() -> Bool { transition(from: [.scanning, .preview, .running, .paused], to: .cancelling) }
    @discardableResult
    func backendStopped() -> Bool { transition(from: [.cancelling], to: .finished) }
    @discardableResult
    func complete() -> Bool { transition(from: [.running, .paused], to: .finished) }

    private func transition(from allowed: [TransferBatchPhase], to next: TransferBatchPhase) -> Bool {
        guard allowed.contains(phase) else { return false }
        phase = next
        return true
    }
}
