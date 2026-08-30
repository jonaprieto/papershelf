import XCTest
@testable import PDFHammer
@testable import PDFHammerCore

/// The search box is in the toolbar in every mode, so every mode has to answer to it.
/// These are the two views that used to take the query and then draw everything anyway.
final class SearchScopeTests: XCTestCase {
    private func item(_ name: String) -> Item {
        let root = URL(fileURLWithPath: "/shelf")
        let url = root.appendingPathComponent(name)
        return Item(root: root, source: url, destination: url, status: .renamed)
    }

    private func entry(_ key: String) -> BibEntry {
        BibEntry(itemKey: key, key: "k\(key)", title: key, file: key)
    }

    func testTheBibliographyShowsWhatTheSearchLeft() {
        let entries = [entry("/shelf/a.pdf"), entry("/shelf/b.pdf")]

        XCTAssertEqual(entriesVisible(entries, in: nil).count, 2, "no query, no filter")
        XCTAssertEqual(entriesVisible(entries, in: ["/shelf/b.pdf"]).map(\.itemKey),
                       ["/shelf/b.pdf"])
        XCTAssertTrue(entriesVisible(entries, in: []).isEmpty)
    }

    func testADuplicateGroupSurvivesIfAnyCopyMatched() {
        let pair = DuplicateGroup(id: "1", kind: .identical,
                                  items: [item("a.pdf"), item("copies/a.pdf")])
        let other = DuplicateGroup(id: "2", kind: .likely,
                                   items: [item("b.pdf"), item("copies/b.pdf")])

        XCTAssertEqual(groupsVisible([pair, other], in: nil).count, 2)
        // One copy matched; the group is still a group, both copies shown.
        let shown = groupsVisible([pair, other], in: ["/shelf/copies/a.pdf"])
        XCTAssertEqual(shown.map(\.id), ["1"])
        XCTAssertEqual(shown.first?.items.count, 2)
        XCTAssertTrue(groupsVisible([pair, other], in: ["/shelf/nothing.pdf"]).isEmpty)
    }
}
