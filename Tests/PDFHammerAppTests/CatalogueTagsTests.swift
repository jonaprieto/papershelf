import XCTest
@testable import PDFHammerCore
@testable import PDFHammer

/// `CatalogueTags` is the app layer's own bridge from an `Item` to the library's tags
/// (see the type-level comment on it in `Catalogue.swift`), so it is tested directly
/// against a real, throwaway `Library` rather than through any SwiftUI view.
@MainActor
final class CatalogueTagsTests: XCTestCase {

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalogue-tags-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("library.sqlite")
    }

    private func tearDownDatabase(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func makeItem(_ name: String) -> Item {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        let url = root.appendingPathComponent(name)
        return Item(root: root, source: url, destination: url, status: .renamed)
    }

    // MARK: - Availability

    func testAnUnavailableLibrarySaysSoAndDoesNothing() async {
        let tagIndex = CatalogueTags(library: nil)
        let item = makeItem("a.pdf")

        XCTAssertFalse(tagIndex.isAvailable)
        let added = await tagIndex.add("Reading", to: item)
        XCTAssertFalse(added, "nothing can be written without a library to write it to")
        XCTAssertEqual(tagIndex.tags(for: item), [])
    }

    // MARK: - A file just noticed

    /// A file a run has only just seen is not a document yet. Adding a tag to it must not
    /// be a dead end: it indexes the file on the spot, exactly what the next library sync
    /// would have done anyway (see the doc comment on `CatalogueTags.add`).
    func testAddingATagIndexesAFileNeverSeenBefore() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)
        let tagIndex = CatalogueTags(library: library)
        let item = makeItem("statement.pdf")

        XCTAssertEqual(tagIndex.tags(for: item), [], "not indexed yet, so it has nothing")

        let added = await tagIndex.add("Bank", to: item)
        XCTAssertTrue(added)
        XCTAssertEqual(tagIndex.tags(for: item), ["Bank"])

        let path = item.currentURL.resolvingSymlinksInPath().path
        let record = try await library.document(atPath: path)
        XCTAssertNotNil(record, "adding a tag must have created the document row")
        let stored = try await library.tags(forDocument: record!.id).map(\.name)
        XCTAssertEqual(stored, ["Bank"])
    }

    func testAddingATagTwiceDoesNotDuplicateIt() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)
        let tagIndex = CatalogueTags(library: library)
        let item = makeItem("a.pdf")

        _ = await tagIndex.add("Reading", to: item)
        _ = await tagIndex.add("Reading", to: item)
        XCTAssertEqual(tagIndex.tags(for: item), ["Reading"])
    }

    func testRemovingATagUpdatesTheCache() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)
        let tagIndex = CatalogueTags(library: library)
        let item = makeItem("a.pdf")

        _ = await tagIndex.add("Reading", to: item)
        await tagIndex.remove("Reading", from: item)
        XCTAssertEqual(tagIndex.tags(for: item), [])

        let path = item.currentURL.resolvingSymlinksInPath().path
        let record = try await library.document(atPath: path)
        let stored = try await library.tags(forDocument: record!.id).map(\.name)
        XCTAssertEqual(stored, [], "the removal must have reached the library, not just the cache")
    }

    // MARK: - Refreshing

    /// A document already known to the library, tagged by something other than this
    /// `CatalogueTags` (another window, a previous launch), must still show up once asked.
    func testRefreshPicksUpTagsTheLibraryAlreadyHad() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)
        let item = makeItem("preexisting.pdf")
        let path = item.currentURL.resolvingSymlinksInPath().path
        let record = try await library.indexDocument(path: path, contentHash: nil)
        try await library.addTag("Archived", toDocument: record.id)

        let tagIndex = CatalogueTags(library: library)
        XCTAssertEqual(tagIndex.tags(for: item), [], "not resolved to a document until refreshed")
        await tagIndex.refresh(items: [item])
        XCTAssertEqual(tagIndex.tags(for: item), ["Archived"])
    }

    func testEveryTagOffersWhatIsAlreadyInUseWithoutDuplicates() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)
        let tagIndex = CatalogueTags(library: library)

        _ = await tagIndex.add("Reading", to: makeItem("a.pdf"))
        _ = await tagIndex.add("Bank", to: makeItem("b.pdf"))
        _ = await tagIndex.add("reading", to: makeItem("c.pdf"))

        XCTAssertEqual(tagIndex.everyTag.count, 2, "\"reading\" and \"Reading\" are the same tag")
    }
}
