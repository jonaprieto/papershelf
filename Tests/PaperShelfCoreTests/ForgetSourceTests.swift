import XCTest
@testable import PaperShelfCore

/// What removing a source takes with it.
///
/// Removing one used to take it out of the list and nothing else: the library kept every
/// document it had brought, with its text, its tags, its place in a reading project and
/// its reading position, so a file in a folder nobody watches any more still answered a
/// search and still filled a project.
final class ForgetSourceTests: XCTestCase {

    private var library: Library!
    private var store: URL!

    override func setUp() async throws {
        store = FileManager.default.temporaryDirectory
            .appendingPathComponent("forget-source-\(UUID().uuidString).sqlite")
        library = try Library(url: store)
    }

    override func tearDown() async throws {
        library = nil
        try? FileManager.default.removeItem(at: store)
    }

    @discardableResult
    private func add(_ path: String, text: String = "") async throws -> String {
        let record = try await library.indexDocument(path: path, contentHash: path,
                                                     byteCount: 10, pageCount: 1,
                                                     title: nil, author: nil)
        if !text.isEmpty {
            try await library.setExtractedText(text, forDocument: record.id, format: .markdown)
        }
        return record.id
    }

    func testDocumentsUnderTheSourceAreForgotten() async throws {
        let inside = try await add("/papers/research/a.pdf")
        try await add("/elsewhere/b.pdf")

        let doomed = try await library.documentsOnly(under: "/papers/research")
        XCTAssertEqual(doomed, [inside])

        let removed = try await library.forget(documents: doomed)
        XCTAssertEqual(removed, 1)

        let gone = try await library.document(atPath: "/papers/research/a.pdf")
        XCTAssertNil(gone, "the document went with its source")
        let kept = try await library.document(atPath: "/elsewhere/b.pdf")
        XCTAssertNotNil(kept)
    }

    /// A sibling whose path merely starts with the same letters is not under it.
    func testOnlyWhatIsActuallyUnderTheSource() async throws {
        try await add("/papers/research/a.pdf")
        try await add("/papers/research-notes/b.pdf")

        let doomed = try await library.documentsOnly(under: "/papers/research")
        XCTAssertEqual(doomed.count, 1, "research-notes is a different folder")

        try await library.forget(documents: doomed)
        let kept = try await library.document(atPath: "/papers/research-notes/b.pdf")
        XCTAssertNotNil(kept)
    }

    /// A path is allowed to contain the characters `LIKE` treats as wildcards.
    func testAPathWithWildcardCharactersInIt() async throws {
        try await add("/papers/100%_done/a.pdf")
        try await add("/papers/1005_done/b.pdf")

        let doomed = try await library.documentsOnly(under: "/papers/100%_done")
        XCTAssertEqual(doomed.count, 1)

        try await library.forget(documents: doomed)
        let kept = try await library.document(atPath: "/papers/1005_done/b.pdf")
        XCTAssertNotNil(kept, "% and _ are characters in a path, not wildcards")
    }

    /// A book filed in two watched folders is one book. Removing one of them leaves it.
    func testADocumentKnownSomewhereElseStays() async throws {
        let id = try await add("/papers/research/a.pdf")
        try await library.recordLocation("/archive/a.pdf", forDocument: id)

        let doomed = try await library.documentsOnly(under: "/papers/research")
        XCTAssertTrue(doomed.isEmpty, "it still lives in the archive")
    }

    /// The delete has to take the search index with it, or a forgotten document goes on
    /// answering questions.
    func testForgottenTextStopsAnsweringSearches() async throws {
        try await add("/papers/research/a.pdf", text: "conflict-free replicated data types")
        let before = try await library.fullTextSearch("replicated", limit: 10)
        XCTAssertFalse(before.isEmpty)

        let doomed = try await library.documentsOnly(under: "/papers/research")
        try await library.forget(documents: doomed)

        let after = try await library.fullTextSearch("replicated", limit: 10)
        XCTAssertTrue(after.isEmpty, "the text went with the document")
    }

    func testForgettingNothingIsNotAnError() async throws {
        let removed = try await library.forget(documents: [])
        XCTAssertEqual(removed, 0)
        let none = try await library.documentsOnly(under: "/nowhere")
        XCTAssertTrue(none.isEmpty)
    }
}
