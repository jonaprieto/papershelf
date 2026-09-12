import XCTest
@testable import PaperShelf

/// The sidebar's rows are a flatten of the whole tree, and the tree it flattens is itself
/// narrowed by the filter. Both ran on every pass of the sidebar's body, and a body pass
/// is what toggling any panel causes. At eleven hundred papers that measured about two
/// milliseconds for the flatten and four for the narrowing, several times per keystroke,
/// which is what made opening the sidebar and typing in it feel slow.
@MainActor
final class ExplorerRowsTests: XCTestCase {

    private func node(_ name: String, children: [ExplorerNode]? = nil) -> ExplorerNode {
        ExplorerNode(id: name, name: name, url: URL(fileURLWithPath: "/\(name)"),
                     itemKey: children == nil ? name : nil,
                     documentCount: 1, children: children)
    }

    func testTheSameQuestionIsAnsweredOnce() {
        let rows = ExplorerRows()
        var flattens = 0
        for _ in 0..<10 {
            _ = rows.rows(for: "3#", expanded: ["a"]) {
                flattens += 1
                return [FlatExplorerRow(node: node("one"), depth: 0)]
            }
        }
        XCTAssertEqual(flattens, 1, "a body pass that changed nothing flattened the tree again")
    }

    /// Folding a folder changes the rows and nothing else: no file arrived and no query
    /// moved, so a cache keyed on the token alone would go on drawing the folder open.
    func testOpeningAFolderRedrawsTheRows() {
        let rows = ExplorerRows()
        var flattens = 0
        let first = rows.rows(for: "3#", expanded: []) {
            flattens += 1
            return [FlatExplorerRow(node: node("folder", children: []), depth: 0)]
        }
        let second = rows.rows(for: "3#", expanded: ["folder"]) {
            flattens += 1
            return [FlatExplorerRow(node: node("folder", children: []), depth: 0),
                    FlatExplorerRow(node: node("paper.pdf"), depth: 1)]
        }
        XCTAssertEqual(flattens, 2, "opening a folder did not reach the tree")
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 2)
    }

    /// And a new scan, or a keystroke in the filter, still reaches it: both are in the
    /// token the sidebar hands down.
    func testNewResultsOrANewQueryRedrawTheRows() {
        let rows = ExplorerRows()
        var flattens = 0
        for token in ["3#", "4#", "4#topic", "4#topic"] {
            _ = rows.rows(for: token, expanded: []) {
                flattens += 1
                return []
            }
        }
        XCTAssertEqual(flattens, 3)
    }
}
