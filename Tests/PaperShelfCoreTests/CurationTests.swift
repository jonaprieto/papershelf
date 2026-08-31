import XCTest
@testable import PaperShelfCore

/// What a removal is about to cost, counted so the question can say it.
final class CurationTests: XCTestCase {

    private var library: Library!
    private var store: URL!

    override func setUp() async throws {
        store = FileManager.default.temporaryDirectory
            .appendingPathComponent("curation-\(UUID().uuidString).sqlite")
        library = try Library(url: store)
    }

    override func tearDown() async throws {
        library = nil
        try? FileManager.default.removeItem(at: store)
    }

    private func add(_ path: String) async throws -> String {
        try await library.indexDocument(path: path, contentHash: path, byteCount: 1,
                                        pageCount: 1, title: nil, author: nil).id
    }

    func testNothingFiledIsNothingToWarnAbout() async throws {
        let id = try await add("/papers/a.pdf")
        let curation = try await library.curation(of: [id])
        XCTAssertTrue(curation.isEmpty)
        XCTAssertEqual(curation.sentence, "")
    }

    func testFilingIsCounted() async throws {
        let filed = try await add("/papers/a.pdf")
        let tagged = try await add("/papers/b.pdf")
        let untouched = try await add("/papers/c.pdf")

        let project = try await library.createProject(name: "Thesis")
        try await library.addMember(filed, toProject: project.id)
        try await library.addTag("to-read", toDocument: tagged)
        try await library.rememberReadingPosition(documentID: filed, page: 12, pageCount: 40)

        let curation = try await library.curation(of: [filed, tagged, untouched])
        XCTAssertEqual(curation.inProjects, 1)
        XCTAssertEqual(curation.tagged, 1)
        XCTAssertEqual(curation.beingRead, 1)
        XCTAssertEqual(curation.sentence, "1 is in a reading project, 1 tagged and 1 part-read")
    }

    /// Only the documents asked about. A tag on a paper from another source is not a
    /// reason to warn about this one.
    func testOnlyTheDocumentsAskedAbout() async throws {
        let doomed = try await add("/papers/a.pdf")
        let other = try await add("/elsewhere/b.pdf")
        try await library.addTag("keep", toDocument: other)

        let curation = try await library.curation(of: [doomed])
        XCTAssertTrue(curation.isEmpty)
    }

    func testAskingAboutNothing() async throws {
        let curation = try await library.curation(of: [])
        XCTAssertTrue(curation.isEmpty)
    }
}
