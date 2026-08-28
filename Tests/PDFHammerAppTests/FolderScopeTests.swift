import XCTest
@testable import PDFHammer
@testable import PDFHammerCore

/// Scoping the catalogue to a folder used to resolve symlinks for the folder and again for
/// every file, on every pass, which is a filesystem call per file per frame. What replaced
/// it still has to answer the same question correctly, symlinks included.
final class FolderScopeTests: XCTestCase {

    private func item(_ path: String) -> Item {
        let url = URL(fileURLWithPath: path)
        return Item(root: URL(fileURLWithPath: "/tmp"), source: url, destination: url,
                    status: .renamed)
    }

    func testAFileUnderTheFolderIsInScope() {
        let scope = ResultsPane.FolderScope(URL(fileURLWithPath: "/tmp/shelf"))
        XCTAssertTrue(scope.contains(item("/tmp/shelf/a.pdf")))
        XCTAssertTrue(scope.contains(item("/tmp/shelf/papers/b.pdf")))
    }

    func testAFileBesideTheFolderIsNot() {
        let scope = ResultsPane.FolderScope(URL(fileURLWithPath: "/tmp/shelf"))
        XCTAssertFalse(scope.contains(item("/tmp/other/a.pdf")))
    }

    /// The prefix has to stop at a path separator, or "/tmp/shelf-old" counts as being
    /// inside "/tmp/shelf".
    func testAFolderWhoseNameStartsTheSameIsNot() {
        let scope = ResultsPane.FolderScope(URL(fileURLWithPath: "/tmp/shelf"))
        XCTAssertFalse(scope.contains(item("/tmp/shelf-old/a.pdf")))
    }

    /// The case the old symlink resolution existed for: a folder reached through a link,
    /// with the files named by their real path. It still has to be answered, without
    /// asking the filesystem about files under a folder that is not linked at all.
    func testAFolderReachedThroughASymlinkStillMatchesItsFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-scope-\(UUID().uuidString)", isDirectory: true)
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let scope = ResultsPane.FolderScope(link)
        XCTAssertTrue(scope.symlinked, "the fixture is meant to be reached through a link")
        XCTAssertTrue(scope.contains(item(real.appendingPathComponent("a.pdf").path)),
                      "a file named by its real path is still inside the linked folder")
        XCTAssertTrue(scope.contains(item(link.appendingPathComponent("a.pdf").path)))
    }
}
