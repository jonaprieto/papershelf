import XCTest
@testable import PaperShelf

/// The sidebar draws these rows straight into a lazy stack, so what this returns is
/// exactly what is on screen and in what order.
final class SidebarSourceRowsTests: XCTestCase {
    private func file(_ name: String, under folder: String) -> ExplorerNode {
        ExplorerNode(id: "/shelf/\(folder)/\(name)", name: name,
                     url: URL(fileURLWithPath: "/shelf/\(folder)/\(name)"),
                     itemKey: "/shelf/\(folder)/\(name)", documentCount: 1, children: nil)
    }

    private func source(_ name: String, children: [ExplorerNode]?) -> ExplorerNode {
        ExplorerNode(id: "/shelf/\(name)", name: name,
                     url: URL(fileURLWithPath: "/shelf/\(name)"), itemKey: nil,
                     documentCount: children?.count ?? 0, children: children)
    }

    func testAFoldedSourceIsOneRowHoweverMuchIsUnderIt() {
        let root = source("papers", children: [file("a.pdf", under: "papers"),
                                               file("b.pdf", under: "papers")])
        let rows = sidebarSourceRows(sources: [root.url], tree: [root], expanded: [])
        XCTAssertEqual(rows.count, 1)
        guard case let .source(url, count, unfoldable) = rows[0] else {
            return XCTFail("Expected the source row")
        }
        XCTAssertEqual(url, root.url)
        XCTAssertEqual(count, 2, "The row says how many papers are under it even when folded")
        XCTAssertTrue(unfoldable)
    }

    func testAnOpenSourceIsFollowedByWhatItHolds() {
        let root = source("papers", children: [file("a.pdf", under: "papers"),
                                               file("b.pdf", under: "papers")])
        let rows = sidebarSourceRows(sources: [root.url], tree: [root], expanded: [root.id])
        XCTAssertEqual(rows.map(\.id),
                       ["source:/shelf/papers", "/shelf/papers/a.pdf", "/shelf/papers/b.pdf"])
    }

    func testASourceWithNothingUnderItHasNoTriangle() {
        let root = source("empty", children: nil)
        let rows = sidebarSourceRows(sources: [root.url], tree: [root], expanded: [root.id])
        XCTAssertEqual(rows.count, 1)
        guard case let .source(_, _, unfoldable) = rows[0] else {
            return XCTFail("Expected the source row")
        }
        XCTAssertFalse(unfoldable)
    }

    func testSourcesKeepTheOrderTheyWereAddedIn() {
        let first = source("one", children: [file("a.pdf", under: "one")])
        let second = source("two", children: [file("b.pdf", under: "two")])
        let rows = sidebarSourceRows(sources: [second.url, first.url],
                                     tree: [first, second], expanded: [second.id])
        XCTAssertEqual(rows.map(\.id),
                       ["source:/shelf/two", "/shelf/two/b.pdf", "source:/shelf/one"])
    }

    /// A source the tree knows nothing about is still its own row: the scan may not have
    /// reached it, and a sidebar that drops it says the folder was never added.
    func testASourceMissingFromTheTreeIsStillARow() {
        let rows = sidebarSourceRows(sources: [URL(fileURLWithPath: "/shelf/gone")],
                                     tree: [], expanded: [])
        XCTAssertEqual(rows.map(\.id), ["source:/shelf/gone"])
    }
}
