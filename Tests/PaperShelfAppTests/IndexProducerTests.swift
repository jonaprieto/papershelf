import XCTest
import PaperShelfCore
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
}
