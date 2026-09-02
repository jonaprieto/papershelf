import XCTest
@testable import PaperShelfCore

final class BookmarksTests: XCTestCase {
    func testBookmarksAreStablePerDocumentPageAndCanBeRenamedAndRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmarks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("library.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = try Library(url: url)
        let document = try await library.indexDocument(path: "/shelf/paper.pdf", contentHash: "hash")
        let first = try await library.addBookmark(documentID: document.id, page: 4)
        let duplicate = try await library.addBookmark(documentID: document.id, page: 4,
                                                       label: "A different label")
        let earlier = try await library.addBookmark(documentID: document.id, page: 2,
                                                    label: "Important")

        XCTAssertEqual(first.id, duplicate.id)
        XCTAssertEqual(first.label, "Page 4")
        let ordered = try await library.bookmarks(forDocument: document.id)
        XCTAssertEqual(ordered.map(\.id), [earlier.id, first.id])

        let renamed = try await library.renameBookmark(first.id, label: "Return here")
        XCTAssertEqual(renamed.label, "Return here")
        try await library.removeBookmark(earlier.id)
        let remaining = try await library.bookmarks(forDocument: document.id)
        XCTAssertEqual(remaining.map(\.label), ["Return here"])
    }

}
