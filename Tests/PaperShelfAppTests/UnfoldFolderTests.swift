import XCTest
@testable import PaperShelfCore
@testable import PaperShelf

/// Asking the sidebar for a folder narrows the list to it. The list's folder rows keep
/// their own folded state, so narrowing on its own left the folder shut: one row naming
/// the top of the tree and the number of files it was hiding.
@MainActor
final class UnfoldFolderTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/library")

    private func item(_ relative: String) -> Item {
        let file = root.appendingPathComponent(relative)
        return Item(root: root, source: file, destination: file, status: .renamed)
    }

    private var results: [Item] {
        [item("jonathan/2025-predial/one.pdf"),
         item("jonathan/2025-predial/two.pdf"),
         item("jonathan/2024-wise/statement.pdf"),
         item("elsewhere/paper.pdf")]
    }

    private func rows(opening folder: String?) -> [String] {
        let results = results
        let derived = Runner.derive(results)
        var expanded: Set<String> = []
        if let folder {
            expanded = foldersOpening(root.appendingPathComponent(folder), in: results,
                                      ancestors: { derived.ancestorsByKey[$0] ?? [] })
        }
        let scope = folder.map { ResultsPane.FolderScope(root.appendingPathComponent($0)) }
        let visible = Set(results.filter { scope?.contains($0) ?? true }.map(\.key))
        return flattenTree(derived.tree, expanded: expanded, visible: visible).map(\.node.name)
    }

    func testAFolderAskedForFromTheSidebarIsShownOpen() {
        XCTAssertEqual(rows(opening: "jonathan/2025-predial"),
                       ["library", "jonathan", "2025-predial", "one.pdf", "two.pdf"])
    }

    /// Nothing outside the folder is opened with it: `2024-wise` is a sibling, and it is
    /// out of scope, so it has no row at all.
    func testOnlyWhatTheFolderReachesIsOpened() {
        XCTAssertEqual(rows(opening: "jonathan"),
                       ["library", "jonathan", "2025-predial", "one.pdf", "two.pdf",
                        "2024-wise", "statement.pdf"])
        XCTAssertFalse(rows(opening: "jonathan").contains("elsewhere"))
    }

    /// And the check has teeth: without the unfolding, the same scope draws the folder
    /// shut, which is the bug.
    func testWithoutUnfoldingTheFolderIsDrawnShut() {
        XCTAssertEqual(rows(opening: nil).filter { $0.hasSuffix(".pdf") }, [],
                       "a tree with nothing expanded should show no files")
    }
}
