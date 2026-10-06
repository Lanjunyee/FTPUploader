import XCTest

final class DirectorySortingTests: XCTestCase {
    private func entry(_ name: String, directory: Bool = false, size: Int64? = nil) -> RemoteEntry {
        RemoteEntry(name: name, rawName: Data(name.utf8), isDirectory: directory, size: size)
    }

    func testKindSortsDirectoriesFirstThenName() {
        let entries = [entry("b.txt", size: 1), entry("资料", directory: true), entry("a.txt", size: 2)]
        let sorted = DirectorySorting.sorted(entries, by: .kind, ascending: true)
        XCTAssertEqual(sorted.map(\.name), ["资料", "a.txt", "b.txt"])
    }

    func testNameSortIsOrderedAndReversible() {
        let entries = [entry("b.txt", size: 1), entry("a.txt", size: 2), entry("c.txt", size: 3)]
        XCTAssertEqual(DirectorySorting.sorted(entries, by: .name, ascending: true).map(\.name),
                       ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(DirectorySorting.sorted(entries, by: .name, ascending: false).map(\.name),
                       ["c.txt", "b.txt", "a.txt"])
    }

    func testUnknownSizeSortsAfterKnownSizeWhenAscending() {
        let entries = [entry("unknown.txt"), entry("big.txt", size: 4096), entry("small.txt", size: 12)]
        let sorted = DirectorySorting.sorted(entries, by: .size, ascending: true)
        XCTAssertEqual(sorted.map(\.name), ["small.txt", "big.txt", "unknown.txt"])
        XCTAssertNil(sorted.last?.size)
    }

    func testUnknownSizeSortsBeforeKnownSizeWhenDescending() {
        let entries = [entry("unknown.txt"), entry("big.txt", size: 4096), entry("small.txt", size: 12)]
        let sorted = DirectorySorting.sorted(entries, by: .size, ascending: false)
        XCTAssertEqual(sorted.map(\.name), ["unknown.txt", "big.txt", "small.txt"])
    }

    func testEqualSizesFallBackToName() {
        let entries = [entry("b.txt", size: 12), entry("a.txt", size: 12)]
        XCTAssertEqual(DirectorySorting.sorted(entries, by: .size, ascending: true).map(\.name),
                       ["a.txt", "b.txt"])
    }

    func testSortingDoesNotDropOrDuplicateEntries() {
        let entries = [entry("b.txt", size: 1), entry("资料", directory: true), entry("a.txt", size: 2)]
        for column in DirectorySortColumn.allCases {
            for ascending in [true, false] {
                let sorted = DirectorySorting.sorted(entries, by: column, ascending: ascending)
                XCTAssertEqual(sorted.count, entries.count)
                XCTAssertEqual(Set(sorted.map(\.rawName)), Set(entries.map(\.rawName)))
            }
        }
    }
}
