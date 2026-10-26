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

/// `AppDelegate.current` is how the menu, the palette and Open Website say a library window
/// was asked for, and how ⌘K reaches the reader windows. It was a cast of `NSApp.delegate`,
/// which under `@NSApplicationDelegateAdaptor` is SwiftUI's own forwarding object, so the
/// cast was nil in the running app and every one of those did nothing.
@MainActor
final class AppDelegateCurrentTests: XCTestCase {
    func testTheDelegateTheAdaptorMakesIsTheCurrentOne() {
        let delegate = AppDelegate()
        XCTAssertTrue(AppDelegate.current === delegate,
                      "the running delegate cannot be reached, so ⌘K never reaches a reader")
    }
}
