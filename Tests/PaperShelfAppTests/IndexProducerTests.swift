import XCTest
@testable import PaperShelfCore
@testable import PaperShelf

/// What the bulk index pass stores, which is the text every search reads. It has to carry
/// page markers, or no result can say which page it found anything on, and it has to say
/// which producer wrote it, or text written before markers existed is never read again.
final class IndexProducerTests: XCTestCase {
    private func scratch(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName(name), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func item(named name: String, modified: Date?) -> Item {
        let url = URL(fileURLWithPath: "/tmp/\(scratchName("indexwork"))/\(name)")
        var item = Item(root: url.deletingLastPathComponent(), source: url,
                        destination: url, status: .renamed)
        item.modifiedDate = modified
        return item
    }

    func testABulkPassStoresPageMarkedMarkdown() async throws {
        let directory = try scratch("index-producer")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("paper.pdf")
        try makeTextPDF(at: file, text: "Session types for the pi calculus")

        let read = await Runner.readText([(id: "doc-1", url: file)], passwords: [])

        XCTAssertEqual(read.failures, 0)
        let stored = try XCTUnwrap(read.stored.first)
        XCTAssertEqual(stored.documentID, "doc-1")
        XCTAssertTrue(stored.markdown.contains("## Page 1"))
        XCTAssertTrue(stored.markdown.contains("Session types"))
        XCTAssertEqual(stored.format, .markdown)
    }

    /// A locked book must count as a failure and be stored nowhere, so the next pass tries
    /// it again. Storing a title heading for it would mark it read forever.
    func testALockedDocumentIsAFailureAndIsNotStored() async throws {
        let directory = try scratch("index-producer-locked")
        defer { try? FileManager.default.removeItem(at: directory) }
        let locked = directory.appendingPathComponent("locked.pdf")
        try makePDF(at: locked, password: "secret")

        let read = await Runner.readText([(id: "doc-2", url: locked)], passwords: [])

        XCTAssertEqual(read.failures, 1)
        XCTAssertTrue(read.stored.isEmpty)
    }

    /// `indexedMarkdown` answers an empty string, not nil, for a document that opened but
    /// has no text layer: a scan, and a permanent answer worth storing so the file is
    /// never read again. `readText`'s own pass-through -- not just `indexedMarkdown` on
    /// its own -- has to treat that as a stored entry rather than a failure.
    func testAScannedPageComesBackThroughReadTextAsAStoredEmptyEntry() async throws {
        let directory = try scratch("index-producer-scan")
        defer { try? FileManager.default.removeItem(at: directory) }
        let scan = directory.appendingPathComponent("scan.pdf")
        try makePDF(at: scan, password: nil)

        let read = await Runner.readText([(id: "doc-3", url: scan)], passwords: [])

        XCTAssertEqual(read.failures, 0)
        let stored = try XCTUnwrap(read.stored.first)
        XCTAssertEqual(stored.documentID, "doc-3")
        XCTAssertTrue(stored.markdown.isEmpty)
    }

    // MARK: - indexWork

    /// `indexWork`, the pure filter behind `Runner.indexText`: which documents a bulk
    /// index pass has to re-read. Plain `Item` and `TextIndexRow` values in, so none of
    /// this needs `Library.shared` or `Runner.results`.
    ///
    /// The mutation a reviewer confirmed the whole suite would otherwise miss: a literal
    /// `.markdown` in place of `row.format`. A row with no format is text stored before
    /// page markers existed, and is stale however recently it was written -- newer than
    /// the file's own modification date included.
    func testANilFormatRowNeedsReindexingEvenWhenNewerThanTheFile() throws {
        let url = URL(fileURLWithPath: "/tmp/\(scratchName("indexwork"))/paper.pdf")
        let destination = url.deletingLastPathComponent().appendingPathComponent("renamed.pdf")
        var moved = Item(root: url.deletingLastPathComponent(), source: url,
                         destination: destination, status: .moved)
        moved.modifiedDate = Date(timeIntervalSince1970: 1_000)
        moved.carriedOut = true

        let row = TextIndexRow(path: moved.key, documentID: "doc-nil-format",
                               extractedAt: Date(timeIntervalSince1970: 2_000), format: nil)

        let work = indexWork(snapshot: [moved], rows: [row])

        let entry = try XCTUnwrap(work.first)
        XCTAssertEqual(entry.id, "doc-nil-format")
        XCTAssertEqual(entry.url, moved.currentURL,
                       "the file is read where it is now, not where it started")
        XCTAssertNotEqual(moved.currentURL, moved.source,
                          "the fixture must actually separate the two for this to prove anything")
    }

    /// A document the library has never seen has no row to match, and is left alone
    /// rather than treated as needing indexing by default.
    func testADocumentWithNoMatchingRowIsSkipped() {
        let solo = item(named: "unknown.pdf", modified: Date(timeIntervalSince1970: 1_000))

        let work = indexWork(snapshot: [solo], rows: [])

        XCTAssertTrue(work.isEmpty)
    }

    /// A row already read after the file's last change, in the current format, needs
    /// nothing: not every row in the library becomes work.
    func testAnUpToDateDocumentIsNotReindexed() {
        let current = item(named: "current.pdf", modified: Date(timeIntervalSince1970: 1_000))
        let row = TextIndexRow(path: current.key, documentID: "doc-current",
                               extractedAt: Date(timeIntervalSince1970: 2_000), format: .markdown)

        let work = indexWork(snapshot: [current], rows: [row])

        XCTAssertTrue(work.isEmpty)
    }
}
