import XCTest

final class DirectorySortingTests: XCTestCase {
    private func entry(_ name: String, directory: Bool = false, size: Int64? = nil) -> RemoteEntry {
        RemoteEntry(name: name, rawName: Data(name.utf8), isDirectory: directory, size: size)
    }

    func testLiteralFilteringPreservesEntriesAndRawIdentity() {
        let entries = [
            RemoteEntry(name: "中文 Report %.PDF#", rawName: Data([0xff, 0x01]), kind: .regularFile, size: 42),
            entry("中文资料", directory: true),
            RemoteEntry(name: "未知*?[a]", rawName: Data([0xfe]), kind: .unknown, size: nil),
            entry("Café.txt"), entry("Cafe\u{301}.TXT"), entry("Cafe.txt")
        ]
        XCTAssertEqual(DirectoryFiltering.filtered(entries, query: ""), entries)
        for query in ["report", ".pdf", " ", "%", "#"] {
            XCTAssertEqual(DirectoryFiltering.filtered(entries, query: query), [entries[0]])
        }
        XCTAssertEqual(DirectoryFiltering.filtered(entries, query: "中文"), Array(entries.prefix(2)))
        for query in ["*", "?", "[a]", "未知"] {
            XCTAssertEqual(DirectoryFiltering.filtered(entries, query: query), [entries[2]])
        }
        for query in ["CAFÉ", "cafe\u{301}"] {
            XCTAssertEqual(DirectoryFiltering.filtered(entries, query: query), [entries[3], entries[4]])
        }
        XCTAssertEqual(DirectoryFiltering.filtered(entries, query: "cafe."), [entries[5]])
        for query in [".*", "中文/", "Report%", "missing"] {
            XCTAssertTrue(DirectoryFiltering.filtered(entries, query: query).isEmpty)
        }
        XCTAssertEqual(entries[0].rawName, Data([0xff, 0x01]))
        XCTAssertEqual(entries[2].kind, .unknown)
    }

    func testVisibleProjectionIntersectsSelectionAndDoesNotRestoreHiddenIDs() {
        let entries = [entry("match folder", directory: true), entry("match file", size: 10),
                       entry("hidden", size: 2),
                       RemoteEntry(name: "match unknown", rawName: Data([0xff]), kind: .unknown, size: nil)]
        let original = entries
        let ids: Set<Data> = [entries[0].id, entries[1].id, entries[2].id, Data([0xfe])]
        for column in DirectorySortColumn.allCases {
            for ascending in [true, false] {
                let projection = DirectoryFiltering.project(entries, query: "match", sort: column,
                                                            ascending: ascending, selectedIDs: ids)
                let expected = DirectorySorting.sorted([entries[0], entries[1], entries[3]],
                                                       by: column, ascending: ascending)
                XCTAssertEqual(projection.entries, expected)
                XCTAssertEqual(projection.selectedIDs, [entries[0].id, entries[1].id])
                XCTAssertEqual(projection.selectedEntries, expected.filter { $0.kind != .unknown })
                XCTAssertEqual(projection.downloadRoute, .collection(projection.selectedEntries))
                XCTAssertNil(projection.folderToOpen)
                let cleared = DirectoryFiltering.project(entries, query: "", sort: column,
                                                         ascending: ascending, selectedIDs: projection.selectedIDs)
                XCTAssertEqual(cleared.selectedIDs, projection.selectedIDs)
                XCTAssertFalse(cleared.selectedIDs.contains(entries[2].id))
            }
        }
        XCTAssertEqual(entries, original)
        for kind in [RemoteEntry.Kind.symbolicLink, .other, .unknown] {
            let unsupported = RemoteEntry(name: "match", rawName: Data([UInt8(kind.rawValue)]), kind: kind, size: nil)
            let projection = DirectoryFiltering.project([unsupported], query: "match", sort: .name,
                                                        ascending: true, selectedIDs: [unsupported.id])
            XCTAssertEqual(projection.selectedEntries, [unsupported])
            XCTAssertNil(projection.downloadRoute)
            XCTAssertNil(projection.folderToOpen)
        }
        let folder = DirectoryFiltering.project(entries, query: "folder", sort: .name,
                                               ascending: true, selectedIDs: ids)
        XCTAssertEqual(folder.folderToOpen, entries[0])
        let file = DirectoryFiltering.project(entries, query: "file", sort: .name,
                                             ascending: true, selectedIDs: ids)
        XCTAssertEqual(file.downloadRoute, .singleFile(entries[1]))
        let invalid = DirectoryFiltering.project(entries, query: "", sort: .name,
                                                ascending: true, selectedIDs: [Data([0xfe])])
        XCTAssertTrue(invalid.selectedEntries.isEmpty)
        XCTAssertNil(invalid.downloadRoute)
    }

    func testSelectionRoutingPreservesDisplayOrderAndOnlyUniqueFolderOpens() {
        let folder = entry("资料", directory: true), file = entry("a.txt", size: 2), other = entry("b.txt", size: 1)
        let ids: Set<Data> = [folder.id, file.id]
        for ascending in [true, false] {
            let display = DirectorySorting.sorted([folder, file, other], by: .name, ascending: ascending)
            let selected = RemoteDirectorySelection.selected(in: display, ids: ids)
            XCTAssertEqual(selected, display.filter { ids.contains($0.id) })
            XCTAssertEqual(RemoteDirectorySelection.downloadRoute(selected), .collection(selected))
            XCTAssertNil(RemoteDirectorySelection.uniqueFolder(selected))
        }
        XCTAssertEqual(RemoteDirectorySelection.uniqueFolder([folder]), folder)
        XCTAssertNil(RemoteDirectorySelection.uniqueFolder([file]))
        XCTAssertNil(RemoteDirectorySelection.uniqueFolder([]))
        XCTAssertEqual(RemoteDirectorySelection.downloadRoute([file]), .singleFile(file))
        XCTAssertEqual(RemoteDirectorySelection.downloadRoute([folder]), .collection([folder]))
        XCTAssertEqual(RemoteDirectorySelection.selected(in: [folder, file], ids: [Data("stale".utf8)]), [])
    }

    func testFilterLifetimeUsesEffectiveIdentityAndRawPathNotRefreshGeneration() throws {
        let identity = FTPIdentity(host: "example.test", port: 21, username: "alice", mode: .account)
        let root = DirectoryContext(identity: identity, path: .root)
        XCTAssertFalse(DirectoryFilterLifetime.shouldReset(from: root, to: root), "Same-directory refresh or failed navigation keeps context")
        let path = try RemotePath.root.appending(name: "资料", bytes: Data([0xff]))
        let changed = DirectoryContext(identity: identity, path: path)
        XCTAssertTrue(DirectoryFilterLifetime.shouldReset(from: root, to: changed))
        let differentRawPath = try RemotePath.root.appending(name: "资料", bytes: Data([0xfe]))
        XCTAssertTrue(DirectoryFilterLifetime.shouldReset(from: changed, to: DirectoryContext(identity: identity, path: differentRawPath)))
        let other = FTPIdentity(host: "example.test", port: 21, username: "bob", mode: .account)
        XCTAssertTrue(DirectoryFilterLifetime.shouldReset(from: root, to: DirectoryContext(identity: other, path: .root)))
        XCTAssertTrue(DirectoryFilterLifetime.shouldReset(from: root, to: nil))
        XCTAssertTrue(DirectoryFilterLifetime.shouldReset(from: nil, to: root))
    }

    func testPickerTicketRejectsChangedRevisionSelectionOrderAndHiddenEntries() {
        let entries = [entry("visible", size: 1), entry("hidden", directory: true)]
        let ticket = DirectorySelectionTicket(revision: 5, entries: entries)
        XCTAssertTrue(ticket.isCurrent(revision: 5, entries: entries))
        XCTAssertFalse(ticket.isCurrent(revision: 6, entries: entries))
        XCTAssertFalse(ticket.isCurrent(revision: 5, entries: Array(entries.reversed())))
        XCTAssertFalse(ticket.isCurrent(revision: 5, entries: [entries[0]]))
        XCTAssertFalse(ticket.isCurrent(revision: 5, entries: []))
        let selection: Set<Data> = Set(entries.map(\.id))
        let projected = DirectoryFiltering.project(entries, query: "visible", sort: .name, ascending: true, selectedIDs: selection)
        XCTAssertFalse(ticket.isCurrent(revision: 6, entries: projected.selectedEntries))
        XCTAssertEqual(entries[1].name, "hidden", "UI projection never rewrites the original snapshot")
    }

    func testDirectoryFeedbackDistinguishesReadingFailureEmptyAndNoMatches() {
        XCTAssertEqual(DirectoryFeedback.resolve(loaded: 0, visible: 0, isReading: true, hasError: false), .reading)
        XCTAssertEqual(DirectoryFeedback.resolve(loaded: 0, visible: 0, isReading: false, hasError: true), .failed)
        XCTAssertEqual(DirectoryFeedback.resolve(loaded: 0, visible: 0, isReading: false, hasError: false), .empty)
        XCTAssertEqual(DirectoryFeedback.resolve(loaded: 10, visible: 0, isReading: false, hasError: false), .noMatches)
        XCTAssertEqual(DirectoryFeedback.resolve(loaded: 10, visible: 2, isReading: false, hasError: false), .ready)
        XCTAssertEqual(DirectoryFeedback.resolve(loaded: 10, visible: 0, isReading: true, hasError: true), .reading)
        XCTAssertEqual(DirectoryFeedback.resolve(loaded: 10, visible: 0, isReading: false, hasError: true), .failed)
    }

    func testProjectionCacheChangesOnlyForListingQueryOrSortAndHandlesTenThousandItems() {
        let loaded = (0..<10_000).map { entry(String(format: "项目%05d %.txt", $0), size: Int64($0)) }
        let original = loaded
        var cache = DirectoryProjectionCache()
        cache.update(loaded, query: "", sort: .name, ascending: true)
        XCTAssertEqual(cache.entries.count, 10_000)
        XCTAssertEqual(cache.projectionCount, 1)
        // Re-render/progress observations do not change the directory inputs.
        for _ in 0..<100 { cache.update(loaded, query: "", sort: .name, ascending: true) }
        XCTAssertEqual(cache.projectionCount, 1)
        cache.update(loaded, query: "项目000", sort: .name, ascending: true)
        XCTAssertEqual(cache.entries.count, 100)
        XCTAssertEqual(cache.projectionCount, 2)
        XCTAssertTrue(cache.isCurrent(loaded, query: "项目000", sort: .name, ascending: true))
        XCTAssertFalse(cache.isCurrent(loaded, query: "different", sort: .name, ascending: true))
        cache.update(loaded, query: "项目000", sort: .size, ascending: false)
        XCTAssertEqual(cache.entries.first?.size, 99)
        XCTAssertEqual(cache.projectionCount, 3)
        cache.update(Array(loaded.dropFirst()), query: "项目000", sort: .size, ascending: false)
        XCTAssertEqual(cache.entries.count, 99)
        XCTAssertEqual(cache.projectionCount, 4)
        XCTAssertEqual(loaded, original)
    }

    func testRevisionSelectionProjectionCachesRowsActionsAndRejectsHiddenSelections() {
        for count in [1_000, 10_000] {
            let loaded = (0..<count).map { entry(String(format: "item-%05d", $0), size: Int64($0)) }
            var cache = DirectoryProjectionCache()
            cache.update(loaded, query: "", sort: .name, ascending: true, generation: 1, location: "/directory")
            cache.select(Set(loaded.map(\.id)))
            let selections = cache.selectionProjectionCount
            XCTAssertEqual(cache.selectedEntries.count, count); XCTAssertEqual(cache.selectionTraversalCount, count)
            for index in 0..<10_000 {
                XCTAssertTrue(cache.isCurrent(loaded, query: "", sort: .name, ascending: true, generation: 1, location: "/directory"))
                XCTAssertEqual(cache.row(id: loaded[index % count].id)?.entry, loaded[index % count])
                XCTAssertNil(cache.selectedRow)
                XCTAssertEqual(cache.actions(isBusy: index.isMultiple(of: 2)).count, 1)
            }
            for _ in 0..<100 { cache.update(loaded, query: "", sort: .name, ascending: true, generation: 1, location: "/directory") }
            XCTAssertEqual(cache.projectionCount, 1); XCTAssertEqual(cache.rowProjectionCount, 1)
            XCTAssertEqual(cache.selectionProjectionCount, selections); XCTAssertEqual(cache.selectionTraversalCount, count)
            let picked: Set<Data> = [loaded[0].id, loaded[count - 1].id]
            cache.select(picked); XCTAssertEqual(cache.selectedEntries, [loaded[0], loaded[count - 1]])
            cache.update(loaded, query: loaded[0].name, sort: .name, ascending: true, generation: 1, location: "/directory")
            XCTAssertEqual(cache.selectedIDs, [loaded[0].id]); XCTAssertEqual(cache.selectedRow?.id, loaded[0].id)
            cache.update(loaded, query: "", sort: .name, ascending: true, generation: 1, location: "/directory")
            XCTAssertEqual(cache.selectedIDs, [loaded[0].id], "Clearing filter must not restore hidden selection")
            XCTAssertFalse(cache.isCurrent(loaded, query: "", sort: .name, ascending: true, generation: 2, location: "/directory"))
            XCTAssertEqual(cache.rows.count, count)
        }
    }
    func testTenThousandItemProjectionPerformance() {
        let loaded = (0..<10_000).map { entry("中文资料 \($0) %#.txt", size: Int64($0)) }
        measure {
            var cache = DirectoryProjectionCache()
            cache.update(loaded, query: "资料", sort: .name, ascending: true)
            XCTAssertEqual(cache.entries.count, loaded.count)
        }
    }

    func testSharedActionsAndReadOnlyInformationFollowResolvedSelection() {
        let file = entry("完整 中文%.txt", size: 20), folder = entry("资料", directory: true)
        for busy in [true, false] {
            let folderActions = RemoteDirectorySelection.actions(for: [folder], isBusy: busy)
            XCTAssertEqual(folderActions.map(\.id), [.openFolder, .download, .information])
            XCTAssertEqual(folderActions.map(\.enabled), [!busy, !busy, true])
            XCTAssertEqual(RemoteDirectorySelection.actions(for: [file], isBusy: busy).map(\.id), [.download, .information])
            XCTAssertEqual(RemoteDirectorySelection.actions(for: [folder, file], isBusy: busy).map(\.id), [.download])
            XCTAssertTrue(RemoteDirectorySelection.actions(for: [], isBusy: busy).isEmpty)
        }
        let unknown = RemoteEntry(name: "fake.pdf", rawName: Data([0xff]), kind: .unknown, size: nil)
        XCTAssertEqual(RemoteDirectorySelection.actions(for: [unknown], isBusy: false).map(\.id), [.information])
        XCTAssertEqual(unknown.information(in: "ftp://example.test/中文%#"),
                       "名称：fake.pdf\n类型：未知类型\n大小：不适用\n所在目录：ftp://example.test/中文%#")
        XCTAssertTrue(entry("unknown").information(in: "/").contains("未知大小"))
        XCTAssertTrue(file.information(in: "/完整路径").contains("完整 中文%.txt"))
        XCTAssertTrue(file.information(in: "/完整路径").contains("/完整路径"))
    }

    func testTypePresentationDoesNotInferFromExtension() {
        let titles = [RemoteEntry.Kind.regularFile: "文件", .directory: "文件夹", .symbolicLink: "符号链接", .other: "特殊项目", .unknown: "未知类型"]
        for (kind, title) in titles {
            let item = RemoteEntry(name: "looks-like.pdf", rawName: Data("looks-like.pdf".utf8), kind: kind, size: 20)
            XCTAssertEqual(item.kindTitle, title)
            XCTAssertFalse(item.kindSymbol.isEmpty)
            if kind != .regularFile && kind != .directory {
                XCTAssertNotEqual(item.kindSymbol, "doc")
                XCTAssertNil(RemoteDirectorySelection.downloadRoute([item]))
                XCTAssertNil(item.size)
            }
        }
    }

    func testUnsupportedTypesAndDuplicateSelectionsCannotDownload() {
        let file = entry("file")
        for kind in [RemoteEntry.Kind.symbolicLink, .other, .unknown] {
            let unsupported = RemoteEntry(name: "unsupported", rawName: Data("unsupported".utf8), kind: kind, size: nil)
            XCTAssertNil(RemoteDirectorySelection.downloadRoute([unsupported]))
            XCTAssertNil(RemoteDirectorySelection.downloadRoute([file, unsupported]))
        }
        XCTAssertNil(RemoteDirectorySelection.downloadRoute([]))
        XCTAssertNil(RemoteDirectorySelection.downloadRoute([file, file]))
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
