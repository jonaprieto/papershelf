import XCTest
@testable import PaperShelf

final class OpenWithTests: XCTestCase {
    func testEachApplicationNameAppearsOnceAndTheRunningCopyWins() {
        let installed = URL(fileURLWithPath: "/Applications/PaperShelf.app")
        let dist = URL(fileURLWithPath: "/src/dist/PaperShelf.app")
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        let apps = FileContextMenu.distinctByName([installed, preview, dist, installed],
                                                  preferring: dist)
        XCTAssertEqual(apps, [dist, preview])
    }

    /// Reopening a paper moves it to the top rather than listing it twice.
    @MainActor
    func testOpenRecentPutsTheLatestFirstAndNamesEachPaperOnce() {
        let recents = RecentPDFs()
        let folder = FileManager.default.temporaryDirectory
        let first = folder.appendingPathComponent("recent-a-\(UUID().uuidString).pdf")
        let second = folder.appendingPathComponent("recent-b-\(UUID().uuidString).pdf")
        recents.note(first)
        recents.note(second)
        recents.note(first)
        XCTAssertEqual(Array(recents.urls.prefix(2)), [first, second])
        XCTAssertEqual(recents.urls.filter { $0 == first }.count, 1)
    }
}
