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
    let historyAdmission = TransferHistoryAdmission()

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
    let fileCount: Int
    let directoryCount: Int
    let completedFiles: Int
    let completedDirectories: Int
    let succeeded: Int
    let failed: Int
    let cancelled: Int
    let skipped: Int
    let blocked: Int
    let totalSize: Int64?
    let successfulBytes: Int64?
    /// Original-plan credit uses size hints, not retry traffic or active/uncommitted bytes.
    let plannedSuccessfulBytes: Int64?
    let actualBytes: Int64?

    init(entries: [Entry], isFinished: Bool, diagnostics: TransferDiagnostics? = nil) {
        self.init(projecting: entries, isFinished: isFinished, diagnostics: diagnostics)
    }
    /// A lazy queue projection can produce entries and aggregate them in the same traversal.
    init<S: Sequence>(projecting source: S, isFinished: Bool, diagnostics: TransferDiagnostics? = nil) where S.Element == Entry {
        var entries: [Entry] = []
        var files = 0, directories = 0, completedFiles = 0, completedDirectories = 0
        var succeeded = 0, failed = 0, cancelled = 0, skipped = 0, blocked = 0
        var total: Int64? = 0, successful: Int64? = 0, credit: Int64? = 0, actual: Int64? = 0
        for entry in source {
            entries.append(entry)
            if entry.kind == .file {
                files += 1
                if entry.result != nil { completedFiles += 1 }
                Self.add(entry.size, to: &total)
                if entry.result == .succeeded {
                    Self.add(entry.successfulBytes, to: &successful)
                    Self.add(entry.size, to: &credit)
                }
            } else {
                directories += 1
                if entry.result != nil { completedDirectories += 1 }
            }
            switch entry.result {
            case .succeeded: succeeded += 1
            case .failed: failed += 1
            case .cancelled: cancelled += 1
            case .skipped: skipped += 1
            case .blocked: blocked += 1
            case nil: break
            }
            if entry.trafficOverflow { actual = nil } else { Self.add(entry.actualBytes, to: &actual) }
        }
        self.entries = entries; self.isFinished = isFinished
        fileCount = files; directoryCount = directories
        self.completedFiles = completedFiles; self.completedDirectories = completedDirectories
        self.succeeded = succeeded; self.failed = failed; self.cancelled = cancelled; self.skipped = skipped; self.blocked = blocked
        totalSize = total; successfulBytes = successful; plannedSuccessfulBytes = credit; actualBytes = actual
        diagnostics?.record(.summarySnapshots)
        diagnostics?.record(.summaryNodes, count: Int64(entries.count))
    }
    private static func add(_ value: Int64?, to sum: inout Int64?) {
        guard let current = sum, let value, value >= 0 else { sum = nil; return }
        let next = current.addingReportingOverflow(value)
        sum = next.overflow ? nil : next.partialValue
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
    let actualBytes: Int64?
    init(original: TransferSummary, retries: [TransferSummary]) {
        self.original = original; self.retries = retries
        actualBytes = TransferSummary.sum(([original] + retries).map(\.actualBytes))
    }
    var allResults: [TransferSummary.Entry] { original.entries + retries.flatMap(\.entries) }
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
