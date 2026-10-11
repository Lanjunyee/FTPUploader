import XCTest

final class TransferActivityLayoutTests: XCTestCase {
    private func activity(_ phase: TransferActivity.Phase = .pending) -> TransferActivity {
        .init(source: phase == .pending ? .pending : .upload, direction: .upload, phase: phase,
              name: "中文文件.txt", target: "ftp://example.test/资料/中文文件.txt", total: 20)
    }
    func testAccentForegroundKeepsAtLeastFourPointFiveContrastAcrossRGBSamples() {
        for red in stride(from: 0.0, through: 1.0, by: 0.1) {
            for green in stride(from: 0.0, through: 1.0, by: 0.1) {
                for blue in stride(from: 0.0, through: 1.0, by: 0.1) {
                    let background = WorkbenchAccentContrast.luminance(red: red, green: green, blue: blue)
                    let white = WorkbenchAccentContrast.usesWhiteText(red: red, green: green, blue: blue)
                    let contrast = white ? 1.05 / (background + 0.05) : (background + 0.05) / 0.05
                    XCTAssertGreaterThanOrEqual(contrast, 4.5)
                }
            }
        }
        XCTAssertFalse(WorkbenchAccentContrast.usesWhiteText(red: 0.934, green: 0.605, blue: 0.289))
        XCTAssertTrue(WorkbenchAccentContrast.usesWhiteText(red: 0.05, green: 0.1, blue: 0.2))
    }

    func testNoActivityMeansNoBarWhetherDisconnectedOrConnectedIdle() {
        XCTAssertEqual(TransferActivityLayout.regions(for: nil), [])
    }
    func testSummaryRetainsFirstRegionAcrossPendingActiveAndTerminalStates() {
        for phase in [TransferActivity.Phase.pending, .checking, .executing, .finalizing, .overwrite, .cancelling, .paused, .succeeded, .failed, .cancelled, .finished] {
            XCTAssertEqual(TransferActivityLayout.regions(for: activity(phase)).first, .summary)
        }
    }
    func testWarningsAppendWithoutMovingSummaryOrRemovingFullDetails() {
        var value = activity(.failed)
        value.warning = "未确认成功，请核对目标。"
        XCTAssertEqual(TransferActivityLayout.regions(for: value), [.summary, .warning])
        let target = TransferActivityLayout.targets(for: value)[0]
        XCTAssertTrue(TransferActivityLayout.details(for: value, target: target).contains(value.warning!))
    }
    func testMatchingTargetIsNotRepeatedAndDifferentTargetsHaveSeparateEntries() {
        var value = activity()
        value.previousTarget = value.target
        XCTAssertEqual(TransferActivityLayout.targets(for: value).count, 1)
        value.previousTarget = "ftp://example.test/原目录/中文文件.txt"
        let targets = TransferActivityLayout.targets(for: value)
        XCTAssertEqual(targets.map(\.title), ["待上传目标", "上次上传结果目标"])
        XCTAssertEqual(targets.map(\.text), [value.target!, value.previousTarget!])
        XCTAssertEqual(TransferActivityLayout.regions(for: value), [.summary, .warning])
        for target in targets {
            let detail = TransferActivityLayout.details(for: value, target: target)
            XCTAssertTrue(detail.contains(target.text))
            if target.title == "待上传目标" { XCTAssertTrue(detail.contains("大小：")) }
            else { XCTAssertFalse(detail.contains("名称："), "Old result must not borrow the new file's metadata") }
        }
    }
}
