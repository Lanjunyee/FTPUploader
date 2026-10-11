import XCTest

final class TransferTaskStateTests: XCTestCase {
    private func entry(_ result: TransferTaskResult?, size: Int64? = 3, successful: Int64 = 0,
                       actual: Int64 = 0, kind: TransferTaskKind = .file) -> TransferSummary.Entry {
        .init(id: UUID(), target: "/example", kind: kind, direction: .download,
              result: result, size: kind == .directory ? nil : size, successfulBytes: successful, actualBytes: actual)
    }

    func testSummarySeparatesAllTerminalKindsAndDoesNotCallPartialFinishedSuccess() {
        let summary = TransferSummary(entries: [entry(.succeeded, successful: 3, actual: 3),
            entry(.failed("failure"), actual: 2), entry(.cancelled, actual: 1), entry(.skipped("existing")),
            entry(.blocked(parentID: UUID(), reason: .failedAncestor), kind: .directory)], isFinished: true)
        XCTAssertEqual(summary.fileCount, 4); XCTAssertEqual(summary.directoryCount, 1)
        XCTAssertEqual(summary.completedFiles, 4); XCTAssertEqual(summary.completedDirectories, 1)
        XCTAssertEqual([summary.succeeded, summary.failed, summary.cancelled, summary.skipped, summary.blocked], [1, 1, 1, 1, 1])
        XCTAssertEqual(summary.totalSize, 12); XCTAssertEqual(summary.successfulBytes, 3)
        XCTAssertEqual(summary.actualBytes, 6); XCTAssertFalse(summary.allSuccessful)
        XCTAssertLessThan(summary.successFraction, 1); XCTAssertLessThan(summary.byteSuccessFraction ?? 1, 1)
    }

    func testSummaryUsesNodeProgressForEmptyDirectoriesZeroByteFilesAndUnknownSizes() {
        let directory = TransferSummary(entries: [entry(.succeeded, kind: .directory)], isFinished: true)
        XCTAssertEqual(directory.totalSize, 0); XCTAssertEqual(directory.successfulBytes, 0)
        XCTAssertNil(directory.byteSuccessFraction); XCTAssertEqual(directory.successFraction, 1)
        let zero = TransferSummary(entries: [entry(.succeeded, size: 0)], isFinished: true)
        XCTAssertNil(zero.byteSuccessFraction); XCTAssertTrue(zero.allSuccessful)
        let unknown = TransferSummary(entries: [entry(.succeeded, size: nil, successful: 4, actual: 4)], isFinished: true)
        XCTAssertNil(unknown.totalSize); XCTAssertNil(unknown.byteSuccessFraction)
        XCTAssertEqual(unknown.successfulBytes, 4); XCTAssertEqual(unknown.actualBytes, 4)
    }

    func testSummaryCannotReachAllSuccessBeforeFinalBackendStop() {
        let waiting = TransferSummary(entries: [entry(nil, actual: 3)], isFinished: false)
        XCTAssertEqual(waiting.actualBytes, 3); XCTAssertEqual(waiting.successfulBytes, 0)
        XCTAssertEqual(waiting.byteSuccessFraction, 0); XCTAssertFalse(waiting.allSuccessful)
        let finalizing = TransferSummary(entries: [entry(.succeeded, successful: 3, actual: 3)], isFinished: false)
        XCTAssertFalse(finalizing.allSuccessful); XCTAssertLessThan(finalizing.successFraction, 1)
        XCTAssertLessThan(finalizing.byteSuccessFraction ?? 1, 1)
    }

    func testRetryTrafficNeverChangesOriginalCreditOrFailure() {
        let original = TransferSummary(entries: [entry(.failed("failure"), actual: 2)], isFinished: true)
        let retry = TransferSummary(entries: [entry(.succeeded, successful: 3, actual: 3)], isFinished: true)
        let session = TransferSessionSummary(original: original, retries: [retry])
        XCTAssertEqual(session.allResults.count, 2); XCTAssertEqual(session.actualBytes, 5)
        XCTAssertEqual(session.successfulBytes, 0); XCTAssertFalse(session.allSuccessful)
        XCTAssertEqual(session.original.failed, 1); XCTAssertEqual(session.retries[0].succeeded, 1)
    }

    func testSummarySumsFailClosedOnOverflowAndKeepFullResultsBeyondHistoryLimit() {
        let overflow = TransferSummary(entries: [entry(.succeeded, size: Int64.max, successful: Int64.max, actual: Int64.max),
            entry(.succeeded, size: 1, successful: 1, actual: 1)], isFinished: true)
        XCTAssertNil(overflow.totalSize); XCTAssertNil(overflow.actualBytes); XCTAssertNil(overflow.successfulBytes)
        let many = TransferSummary(entries: (0..<150).map { _ in entry(.succeeded, kind: .directory) }, isFinished: true)
        XCTAssertEqual(many.entries.count, 150); XCTAssertEqual(many.completedDirectories, 150)
        XCTAssertTrue(many.allSuccessful)
    }

    func testPayloadCounterFreezesLateProgressAndAvoidsDoubleCountingReceiveAndProgress() {
        let counter = TransferByteCounter()
        counter.receive(3); counter.sample(3); counter.sample(2)
        XCTAssertEqual(counter.bytes, 3)
        counter.receive(2); counter.sample(5); counter.finish()
        counter.sample(999); counter.receive(999)
        XCTAssertEqual(counter.bytes, 5); XCTAssertFalse(counter.hasOverflow)
    }

    @MainActor
    func testEveryTerminalResultIsWriteOnceIncludingLateCancel() {
        let parent = UUID()
        let results: [TransferTaskResult] = [.succeeded, .failed("denied"), .cancelled,
            .skipped("existing"), .blocked(parentID: parent, reason: .failedAncestor),
            .blocked(parentID: parent, reason: .skippedAncestor)]
        for kind in [TransferTaskKind.file, .directory] {
            for result in results {
                let task = TransferTaskState(kind: kind)
                XCTAssertTrue(task.finish(result))
                for late in results {
                    XCTAssertFalse(task.finish(late))
                    XCTAssertEqual(task.result, result)
                }
            }
        }
    }
    @MainActor
    func testBatchPhasesAndCancellationKeepLockUntilBackendStops() {
        let batch = TransferBatchState()
        XCTAssertEqual(batch.phase, .scanning)
        XCTAssertFalse(batch.start())
        XCTAssertTrue(batch.scanned())
        XCTAssertFalse(batch.scanned())
        XCTAssertTrue(batch.start())
        XCTAssertFalse(batch.start())
        XCTAssertTrue(batch.pause())
        XCTAssertTrue(batch.resume())
        XCTAssertTrue(batch.cancel())
        XCTAssertTrue(batch.phase.isLocked)
        XCTAssertFalse(batch.resume())
        XCTAssertFalse(batch.complete())
        XCTAssertFalse(batch.cancel())
        XCTAssertTrue(batch.backendStopped())
        XCTAssertFalse(batch.phase.isLocked)
        XCTAssertFalse(batch.cancel())
        XCTAssertFalse(batch.backendStopped())
    }
    @MainActor
    func testCancelScanningOrPreviewAndLateCancelAfterSuccess() {
        for preview in [false, true] {
            let batch = TransferBatchState()
            if preview { XCTAssertTrue(batch.scanned()) }
            XCTAssertTrue(batch.cancel())
            XCTAssertFalse(batch.scanned())
            XCTAssertFalse(batch.start())
            XCTAssertTrue(batch.backendStopped())
        }
        let batch = TransferBatchState()
        XCTAssertTrue(batch.scanned())
        XCTAssertTrue(batch.start())
        XCTAssertTrue(batch.complete())
        XCTAssertFalse(batch.cancel())
        XCTAssertEqual(batch.phase, .finished)
    }
}
