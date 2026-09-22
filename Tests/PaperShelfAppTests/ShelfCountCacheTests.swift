import XCTest
@testable import PaperShelf
@testable import PaperShelfCore

/// The sidebar asks for all four counts on every pass of its body, so they are counted
/// once per collection and served from there. A count that outlived its collection would
/// be a number in the sidebar that no longer describes the shelf.
@MainActor
final class ShelfCountCacheTests: XCTestCase {
    private func item(_ name: String) -> Item {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        return Item(root: root, source: root.appendingPathComponent(name),
                    destination: root.appendingPathComponent(name),
                    status: .renamed, carriedOut: false)
    }

    func testACountFollowsTheCollectionRatherThanTheFirstOneCounted() {
        let shelves = Shelves.shared
        XCTAssertEqual(shelves.count(.all, among: [item("a.pdf"), item("b.pdf")], token: 1), 2)
        XCTAssertEqual(shelves.count(.all, among: [item("a.pdf")], token: 2), 1,
                       "A new collection is counted again rather than answered from the last one")
        XCTAssertEqual(shelves.count(.all, among: [item("a.pdf"), item("b.pdf")], token: 1), 2,
                       "And going back to the collection before it counts that one")
    }

    func testEveryListIsAnsweredFromTheSameWalk() {
        let shelves = Shelves.shared
        let items = [item("a.pdf"), item("b.pdf"), item("c.pdf")]
        XCTAssertEqual(shelves.count(.all, among: items, token: 3), 3)
        // Nothing has been read or tagged in this collection, so the other lists are empty
        // while All Documents is not: one walk, four answers, and they disagree correctly.
        XCTAssertEqual(shelves.count(.reading, among: items, token: 3), 0)
        XCTAssertEqual(shelves.count(.unfiled, among: items, token: 3), 0)
        XCTAssertEqual(shelves.count(.all, among: items, token: 3), 3)
    }
}
