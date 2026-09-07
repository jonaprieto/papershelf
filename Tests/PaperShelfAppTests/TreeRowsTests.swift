import XCTest
@testable import PaperShelfCore
@testable import PaperShelf

/// The list's rows are a flatten of the whole tree, and a flatten is not cheap: at
/// fourteen thousand files under eight hundred folders, with everything open and a search
/// narrowing it, it measures 4.2ms at -O. That is a dropped frame on a 120Hz display, and
/// it ran on every pass of `ResultsPane`'s body -- which is every time any panel is
/// toggled, since one body reads every preference the window has.
///
/// `visibleKeys` and the shelf's own `shown` list were already held this way. The rows
/// were the one derived thing still recomputed each pass.
@MainActor
final class TreeRowsTests: XCTestCase {

    private func signature(query: String = "", results: Int = 1) -> VisibleFilter.Signature {
        VisibleFilter.Signature(results: results, matching: 0, tags: 0, query: query,
                                scope: nil, undecidedOnly: false, decisions: 0,
                                list: .all, lists: 0)
    }

    private func row(_ name: String) -> FlatNode {
        FlatNode(node: Node(id: name, name: name, itemKey: name, children: nil), depth: 0)
    }

    func testTheSameQuestionIsAnsweredOnce() {
        let rows = TreeRows()
        var flattens = 0
        let signature = signature()
        for _ in 0..<10 {
            _ = rows.rows(matching: signature, expanded: ["a"]) {
                flattens += 1
                return [row("one")]
            }
        }
        XCTAssertEqual(flattens, 1, "a body pass that changed nothing flattened the tree again")
    }

    /// Folding a folder changes the rows and nothing else: no file arrived, no search
    /// moved, so the visibility signature is identical. A cache keyed on that alone would
    /// go on drawing the folder open.
    func testOpeningAFolderRedrawsTheRows() {
        let rows = TreeRows()
        var flattens = 0
        let signature = signature()
        let first = rows.rows(matching: signature, expanded: []) {
            flattens += 1
            return [row("folder")]
        }
        let second = rows.rows(matching: signature, expanded: ["folder"]) {
            flattens += 1
            return [row("folder"), row("folder/paper.pdf")]
        }
        XCTAssertEqual(flattens, 2, "opening a folder did not reach the tree")
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 2)
    }

    /// And anything the search or the shelf could change still reaches it.
    func testANewAnswerFromTheSearchRedrawsTheRows() {
        let rows = TreeRows()
        var flattens = 0
        _ = rows.rows(matching: signature(query: ""), expanded: ["a"]) {
            flattens += 1
            return []
        }
        _ = rows.rows(matching: signature(query: "gomes"), expanded: ["a"]) {
            flattens += 1
            return []
        }
        _ = rows.rows(matching: signature(query: "gomes", results: 2), expanded: ["a"]) {
            flattens += 1
            return []
        }
        XCTAssertEqual(flattens, 3)
    }

    func testTheHeldRowsAreTheOnesHandedBack() {
        let rows = TreeRows()
        let signature = signature()
        let computed = rows.rows(matching: signature, expanded: []) { [row("one"), row("two")] }
        let held = rows.rows(matching: signature, expanded: []) { XCTFail("recomputed"); return [] }
        XCTAssertEqual(computed.map(\.id), held.map(\.id))
    }
}
