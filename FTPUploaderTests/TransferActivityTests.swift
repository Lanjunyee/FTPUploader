import XCTest

final class TransferActivityTests: XCTestCase {
    private func value(_ source: TransferActivity.Source, _ phase: TransferActivity.Phase,
                       ended: Date = .distantPast) -> TransferActivity {
        .init(source: source, direction: .download, phase: phase, name: "文件", target: "/固定目标", ended: ended)
    }
    func testActiveRetryOutranksOriginalPausePendingAndResults() {
        let result = value(.upload, .succeeded, ended: Date())
        let pending = value(.pending, .pending)
        let original = value(.queue(ObjectIdentifier(NSObject())), .paused)
        let retry = value(.download, .executing)
        XCTAssertEqual(TransferActivity.select([result, pending, original, retry])?.source, .download)
        XCTAssertEqual(TransferActivity.select([result, pending, original])?.phase, .paused)
        XCTAssertEqual(TransferActivity.select([result, pending])?.phase, .pending)
        XCTAssertEqual(TransferActivity.select([result])?.phase, .succeeded)
        XCTAssertNil(TransferActivity.select([]))
    }
    func testAllBusyAndCancellingStagesOutrankPendingOrResults() {
        for phase in [TransferActivity.Phase.scanning, .checking, .executing, .finalizing, .overwrite, .cancelling] {
            XCTAssertEqual(TransferActivity.select([value(.pending, .pending), value(.scan, phase)])?.phase, phase)
        }
        XCTAssertEqual(TransferActivity.select([value(.pending, .pending), value(.scan, .preview)])?.phase, .preview)
    }
    func testMostRecentResultAndNewerSamePriorityContextWin() {
        let early = value(.upload, .failed, ended: Date(timeIntervalSince1970: 1))
        let late = value(.download, .succeeded, ended: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(TransferActivity.select([late, early])?.source, .download)
        XCTAssertEqual(TransferActivity.select([value(.upload, .executing), value(.download, .cancelling)])?.source, .download)
    }
    func testUnknownZeroAndFinalizingContentDoNotClaimSuccess() {
        var activity = value(.download, .finalizing)
        activity.bytes = 100
        XCTAssertNil(activity.contentFraction)
        activity.total = 0
        XCTAssertNil(activity.contentFraction)
        activity.total = 100
        XCTAssertLessThan(try XCTUnwrap(activity.contentFraction), 1)
        XCTAssertEqual(activity.phase.title, "等待最终确认／提交")
        XCTAssertEqual(value(.download, .succeeded).title, "下载 · 成功")
    }
    func testQueueAnnouncementKeyExcludesByteMetricsButIncludesPhaseAndSource() {
        let first = NSObject(), second = NSObject()
        var activity = value(.queue(ObjectIdentifier(first)), .executing)
        let initial = TransferActivityAnnouncement.key(for: activity)
        activity.bytes = 100
        activity.estimate = .init(bytes: 100, total: 200, speed: 50, remaining: 2)
        XCTAssertEqual(TransferActivityAnnouncement.key(for: activity), initial)
        let finalizing = value(.queue(ObjectIdentifier(first)), .finalizing)
        XCTAssertNotEqual(TransferActivityAnnouncement.key(for: finalizing), initial)
        XCTAssertNotEqual(TransferActivityAnnouncement.key(for: value(.queue(ObjectIdentifier(second)), .executing)), initial)
        XCTAssertNil(TransferActivityAnnouncement.key(for: value(.upload, .executing)), "Single-file owner already announces")
        XCTAssertNil(TransferActivityAnnouncement.key(for: value(.scan, .scanning)), "Scan owner already announces")
    }

    func testCriticalPhasesHaveDirectWarningsAndCleanupDoesNotRewriteSuccess() {
        for direction in [TransferDirection.upload, .download] {
            for phase in [TransferActivity.Phase.finalizing, .overwrite, .cancelling, .failed, .cancelled] {
                XCTAssertNotNil(TransferActivity.warning(phase: phase, direction: direction))
            }
        }
        let failure = TransferActivity.warning(phase: .failed, direction: .upload, error: "552 rejected")
        XCTAssertTrue(failure?.contains("部分或完整文件") == true)
        XCTAssertTrue(failure?.contains("552 rejected") == true)
        XCTAssertNil(TransferActivity.warning(phase: .succeeded, direction: .download))
        let cleanup = TransferActivity.warning(phase: .succeeded, direction: .download, cleanup: "/保存目录/临时文件：拒绝访问")
        XCTAssertTrue(cleanup?.contains("清理失败") == true)
        XCTAssertTrue(cleanup?.contains("/保存目录/临时文件") == true)
    }

    func testDirectoryTaskDoesNotInventBytePercentage() {
        var activity = value(.download, .executing)
        activity.kind = .directory
        activity.bytes = 10
        activity.total = 10
        XCTAssertNil(activity.contentFraction)
        XCTAssertEqual(activity.directionTitle, "下载")
        XCTAssertEqual(activity.kind, .directory)
    }

    func testSuccessCreditAndRetryTrafficKeepSeparateSources() {
        let id = UUID()
        let original = TransferSummary(entries: [.init(id: id, target: "/original", kind: .file,
            direction: .upload, result: .failed("failure"), size: 10, successfulBytes: 0, actualBytes: 5)], isFinished: true)
        let retry = TransferSummary(entries: [.init(id: UUID(), target: "/retry", kind: .file,
            direction: .upload, result: .succeeded, size: 10, successfulBytes: 10, actualBytes: 10)], isFinished: true)
        let session = TransferSessionSummary(original: original, retries: [retry])
        var activity = value(.upload, .finished)
        activity.summary = original
        activity.sessionTraffic = session.actualBytes
        XCTAssertEqual(activity.summary?.successfulBytes, 0)
        XCTAssertEqual(activity.sessionTraffic, 15)
        XCTAssertEqual(activity.summary?.byteSuccessFraction, 0)
        XCTAssertEqual(session.successfulBytes, 0)
        XCTAssertFalse(session.allSuccessful)
        XCTAssertEqual(original.entries[0].id, id)
    }

    func testPendingAndPreviousTargetRemainSeparatelyBound() {
        var activity = value(.pending, .pending)
        activity.previousTarget = "/原结果"
        XCTAssertTrue(activity.targetDiffers)
        XCTAssertEqual(activity.target, "/固定目标")
        XCTAssertEqual(activity.previousTarget, "/原结果")
        activity.previousTarget = activity.target
        XCTAssertFalse(activity.targetDiffers)
    }
    func testResultProjectionUsesUnboundedSummaryNotCompletionAsSuccess() {
        let nodes: [TransferSummary.Entry] = (0..<150).map { index in
            .init(id: UUID(), target: "/\(index)", kind: .file, direction: .download,
                  result: index == 0 ? .failed("failure") : .succeeded, size: 1,
                  successfulBytes: index == 0 ? 0 : 1, actualBytes: 1)
        }
        var activity = value(.download, .finished)
        activity.summary = TransferSummary(entries: nodes, isFinished: true)
        XCTAssertEqual(activity.summary?.failed, 1)
        XCTAssertEqual(activity.summary?.succeeded, 149)
        XCTAssertEqual(activity.summary?.entries.count, 150)
        XCTAssertEqual(activity.summary?.allSuccessful, false)
        XCTAssertTrue(TransferActivityAnnouncement.text(for: activity).contains("不是全部成功"))
        XCTAssertTrue(TransferActivityAnnouncement.text(for: activity).contains("成功 149，失败 1"))
        XCTAssertLessThan(try XCTUnwrap(activity.summary?.byteSuccessFraction), 1)
    }
}
