import XCTest
@testable import PDFHammerCore
@testable import PDFHammer

/// The Explorer draws whatever `buildExplorerTree` returns, so the shape it produces is
/// what decides whether a folder can be opened in the catalogue at all.
final class ExplorerTreeTests: XCTestCase {

    private func item(_ root: URL, _ relative: String) -> Item {
        let url = root.appendingPathComponent(relative)
        return Item(root: root, source: url, destination: url, status: .renamed)
    }

    /// Every folder along the way keeps the real path on disk, not the results tree's
    /// synthetic node id, because "Open in Catalogue" hands that path to the catalogue.
    func testFoldersCarryTheirRealPath() throws {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        let tree = buildExplorerTree([item(root, "papers/2020/a.pdf")])

        let top = try XCTUnwrap(tree.first)
        XCTAssertEqual(top.url.path, "/tmp/shelf")
        let papers = try XCTUnwrap(top.children?.first)
        XCTAssertEqual(papers.url.path, "/tmp/shelf/papers")
        let year = try XCTUnwrap(papers.children?.first)
        XCTAssertEqual(year.url.path, "/tmp/shelf/papers/2020")
        let file = try XCTUnwrap(year.children?.first)
        XCTAssertEqual(file.name, "a.pdf")
        XCTAssertEqual(file.itemKey, item(root, "papers/2020/a.pdf").key)
        XCTAssertNil(file.children, "a file is a leaf, not an empty folder")
    }

    /// Folders first, then alphabetical, the way Finder lists one. A file sorted above a
    /// folder is the bug this catches.
    func testFoldersSortAboveFilesAndBothSortByName() throws {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        let tree = buildExplorerTree([
            item(root, "zeta.pdf"),
            item(root, "alpha.pdf"),
            item(root, "notes/b.pdf"),
        ])

        let names = try XCTUnwrap(tree.first?.children).map(\.name)
        XCTAssertEqual(names, ["notes", "alpha.pdf", "zeta.pdf"])
    }

    /// Two files in one folder share a single node rather than each growing their own.
    func testFilesInTheSameFolderShareIt() throws {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        let tree = buildExplorerTree([
            item(root, "papers/a.pdf"),
            item(root, "papers/b.pdf"),
        ])

        let papers = try XCTUnwrap(tree.first?.children)
        XCTAssertEqual(papers.count, 1)
        XCTAssertEqual(papers.first?.children?.count, 2)
    }

    // MARK: - Folding

    /// "Unfold everything" needs the folders and only the folders: a set carrying file ids
    /// would claim open folders that do not exist.
    func testFolderIDsAreEveryFolderAndNoFile() throws {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        let tree = buildExplorerTree([
            item(root, "papers/2020/a.pdf"),
            item(root, "loose.pdf"),
        ])

        XCTAssertEqual(explorerFolderIDs(tree), [
            "/tmp/shelf", "/tmp/shelf/papers", "/tmp/shelf/papers/2020",
        ])
    }

    // MARK: - Filtering

    func testAnEmptyFilterChangesNothing() throws {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        let tree = buildExplorerTree([item(root, "papers/a.pdf")])

        XCTAssertEqual(filterExplorerTree(tree, matching: "   ").count, tree.count)
    }

    /// A matching file keeps the folders needed to reach it, and nothing else.
    func testAMatchingFileKeepsItsAncestorsAndDropsItsSiblings() throws {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        let tree = buildExplorerTree([
            item(root, "papers/graphs.pdf"),
            item(root, "papers/other.pdf"),
            item(root, "music/song.pdf"),
        ])

        let filtered = filterExplorerTree(tree, matching: "graphs")
        let papers = try XCTUnwrap(filtered.first?.children)
        XCTAssertEqual(papers.count, 1, "the music folder has nothing matching in it")
        XCTAssertEqual(papers.first?.name, "papers")
        XCTAssertEqual(papers.first?.children?.map(\.name), ["graphs.pdf"])
    }

    /// A folder whose own name matches keeps everything under it, the way typing a folder
    /// name into an editor's explorer shows its contents rather than an empty branch.
    func testAMatchingFolderKeepsEverythingUnderIt() throws {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        let tree = buildExplorerTree([
            item(root, "papers/a.pdf"),
            item(root, "papers/b.pdf"),
        ])

        let filtered = filterExplorerTree(tree, matching: "papers")
        let papers = try XCTUnwrap(filtered.first?.children?.first)
        XCTAssertEqual(papers.children?.count, 2)
    }

    func testFilteringIgnoresCaseAndDiacritics() throws {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        let tree = buildExplorerTree([item(root, "Álgebra.pdf")])

        XCTAssertEqual(filterExplorerTree(tree, matching: "algebra").count, 1)
    }

    func testNothingMatchingLeavesNothing() throws {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        let tree = buildExplorerTree([item(root, "papers/a.pdf")])

        XCTAssertTrue(filterExplorerTree(tree, matching: "zzz").isEmpty)
    }
}
