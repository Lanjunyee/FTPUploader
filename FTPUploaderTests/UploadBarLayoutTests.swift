import XCTest

final class UploadBarLayoutTests: XCTestCase {
    func testNotConnectedUsesNoRows() {
        XCTAssertEqual(UploadBarLayout.rowCount(isConnected: false,
                                                hasSelectedFile: false,
                                                isIdle: true,
                                                hasSelectionError: false), 0)
        XCTAssertEqual(UploadBarLayout.rowCount(isConnected: false,
                                                hasSelectedFile: true,
                                                isIdle: false,
                                                hasSelectionError: false), 0)
    }

    func testConnectedWithoutFileUsesOneRow() {
        XCTAssertEqual(UploadBarLayout.rowCount(isConnected: true,
                                                hasSelectedFile: false,
                                                isIdle: true,
                                                hasSelectionError: false), 1)
    }

    func testFileChosenAndIdleUsesTwoRows() {
        XCTAssertEqual(UploadBarLayout.rowCount(isConnected: true,
                                                hasSelectedFile: true,
                                                isIdle: true,
                                                hasSelectionError: false), 2)
    }

    func testTransferringAndFinishedStatesUseThreeRows() {
        for isIdle in [false] {
            XCTAssertEqual(UploadBarLayout.rowCount(isConnected: true,
                                                    hasSelectedFile: true,
                                                    isIdle: isIdle,
                                                    hasSelectionError: false), 3)
        }
        // A finished transfer is still a non-idle state, so it keeps the status row.
        XCTAssertEqual(UploadBarLayout.rowCount(isConnected: true,
                                                hasSelectedFile: true,
                                                isIdle: false,
                                                hasSelectionError: false), 3)
    }

    func testSelectionErrorAddsStatusRowWithoutTargetRow() {
        XCTAssertEqual(UploadBarLayout.rowCount(isConnected: true,
                                                hasSelectedFile: false,
                                                isIdle: true,
                                                hasSelectionError: true), 2)
    }

    func testFinishedWithMatchingTargetUsesTwoRows() {
        let rows = UploadBarLayout.rows(isConnected: true, hasSelectedFile: true,
                                        isIdle: false, hasSelectionError: false,
                                        isFinished: true, targetMatchesResult: true)
        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(rows.showsTarget)
        XCTAssertTrue(rows.showsStatus)
    }

    func testFinishedWithDifferentTargetUsesThreeRows() {
        let rows = UploadBarLayout.rows(isConnected: true, hasSelectedFile: true,
                                        isIdle: false, hasSelectionError: false,
                                        isFinished: true, targetMatchesResult: false)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.showsTarget)
        XCTAssertTrue(rows.showsStatus)
    }

    func testTransferringWithMatchingTargetKeepsThreeRows() {
        let rows = UploadBarLayout.rows(isConnected: true, hasSelectedFile: true,
                                        isIdle: false, hasSelectionError: false,
                                        isFinished: false, targetMatchesResult: true)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.showsTarget)
        XCTAssertTrue(rows.showsStatus)
    }
}
