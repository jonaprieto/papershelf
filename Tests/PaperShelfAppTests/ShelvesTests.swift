import XCTest
@testable import PaperShelfCore
@testable import PaperShelf

/// The four library lists are the sidebar's counts and the shelf's filter at once, which
/// is why they are one object: two copies of "which files are these" would disagree the
/// moment a file was tagged or a page was turned.
@MainActor
final class ShelvesTests: XCTestCase {

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelves-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("library.sqlite")
    }

    /// An item that has been renamed: its key is where it was found, its current URL is
    /// where it now is. Both have to answer, or a book renamed mid-read drops off the
    /// list of what is being read.
    private func renamedItem(from source: String, to destination: String) -> Item {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        return Item(root: root,
                    source: root.appendingPathComponent(source),
                    destination: root.appendingPathComponent(destination),
                    status: .renamed,
                    carriedOut: true)
    }

    func testEverythingIsInAllDocuments() {
        let shelves = Shelves.shared
        let item = renamedItem(from: "a.pdf", to: "a.pdf")
        XCTAssertTrue(shelves.contains(item, in: .all))
        XCTAssertEqual(shelves.count(.all, among: [item, item]), 2)
    }

    func testARenamedFileIsStillTheFileThatWasBeingRead() async throws {
        let url = try makeDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let library = try Library(url: url)

        let item = renamedItem(from: "old.pdf", to: "2009-new.pdf")
        let record = try await library.indexDocument(path: item.key, contentHash: "a",
                                                     byteCount: 1, pageCount: 100)
        try await library.recordLocation(item.currentURL.path, forDocument: record.id)
        try await library.rememberReadingPosition(documentID: record.id, page: 12,
                                                  pageCount: 100)

        let paths = try await library.pathsBeingRead()
        XCTAssertTrue(paths.contains(item.key))
        XCTAssertTrue(paths.contains(item.currentURL.path))
    }

    func testAFileWithNoTagsIsTheOnlyUnfiledOne() async throws {
        let url = try makeDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let library = try Library(url: url)

        let tagged = try await library.indexDocument(path: "/tmp/shelf/tagged.pdf",
                                                     contentHash: "a", byteCount: 1)
        _ = try await library.indexDocument(path: "/tmp/shelf/bare.pdf",
                                            contentHash: "b", byteCount: 1)
        try await library.addTag("methods", toDocument: tagged.id)

        let unfiled = try await library.pathsWithoutTags()
        XCTAssertEqual(unfiled, ["/tmp/shelf/bare.pdf"])
    }
}
