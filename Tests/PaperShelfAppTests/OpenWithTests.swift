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
}
