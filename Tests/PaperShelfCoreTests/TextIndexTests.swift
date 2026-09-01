import XCTest
@testable import PaperShelfCore

final class TextIndexTests: XCTestCase {
    private func scratch(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName(name), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testTextIsReadFromTheWholeDocumentUpToTheCap() throws {
        let directory = try scratch("text-index")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("paper.pdf")
        try makeTextPDF(at: file, text: "Stochastic epidemic models")

        let read = try XCTUnwrap(indexedMarkdown(of: file, passwords: []))
        XCTAssertTrue(read.text.contains("Stochastic epidemic"))
        XCTAssertEqual(read.format, .markdown)

        // Every page the reader saw is announced, so a later search can say which one a
        // match came from.
        XCTAssertTrue(read.text.contains("## Page 1"))

        // The cap is a character count, not a page count, and hitting it is recorded
        // rather than left for a caller to guess at.
        let clipped = try XCTUnwrap(indexedMarkdown(of: file, passwords: [], limit: 6))
        XCTAssertEqual(clipped.text.count, 6)
        XCTAssertEqual(clipped.format, .clipped)
    }

    /// Two different answers that must not be confused: a file that cannot be opened is
    /// worth trying again when the disk comes back, a scan with no text layer is not.
    func testUnreadableIsNilAndATextlessDocumentIsEmpty() throws {
        let directory = try scratch("text-index-empty")
        defer { try? FileManager.default.removeItem(at: directory) }
        let blank = directory.appendingPathComponent("blank.pdf")
        try makePDF(at: blank, password: nil)

        let read = try XCTUnwrap(indexedMarkdown(of: blank, passwords: []))
        XCTAssertEqual(read.text, "", "a scan has no text, and that is a permanent answer")
        XCTAssertEqual(read.format, .markdown)
        XCTAssertNil(indexedMarkdown(of: directory.appendingPathComponent("gone.pdf"),
                                     passwords: []))
    }

    /// A blank first page must not shift the number reported for the page after it: a
    /// searcher told a match is on "page 2" needs that to mean the PDF's own second page,
    /// not the second marker this function happened to emit.
    func testAPageMarkerIsThePDFsOwnPageNumberNotACountOfMarkersEmitted() throws {
        let directory = try scratch("text-index-mixed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mixed.pdf")
        try makeMixedPDF(at: file, pageTexts: [nil, "Stochastic epidemic models"])

        // The first page must carry no extractable text at all, or this test proves nothing.
        let document = try XCTUnwrap(loadPDF(file))
        XCTAssertTrue((document.page(at: 0)?.string ?? "").isEmpty)

        let read = try XCTUnwrap(indexedMarkdown(of: file, passwords: []))
        XCTAssertTrue(read.text.contains("## Page 2"))
        XCTAssertFalse(read.text.contains("## Page 1"))
    }

    func testALockedDocumentNoPasswordOpensIsNotIndexed() throws {
        let directory = try scratch("text-index-locked")
        defer { try? FileManager.default.removeItem(at: directory) }
        let locked = directory.appendingPathComponent("locked.pdf")
        try makePDF(at: locked, password: "secret")

        XCTAssertNil(indexedMarkdown(of: locked, passwords: []), "no password, no text")
        XCTAssertNotNil(indexedMarkdown(of: locked, passwords: ["secret"]))
    }

    func testWhatHasToBeReadAgain() {
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)

        XCTAssertTrue(needsIndexing(extractedAt: nil, fileModified: late), "never read")
        XCTAssertTrue(needsIndexing(extractedAt: early, fileModified: late),
                      "the file changed after its text was read")
        XCTAssertFalse(needsIndexing(extractedAt: late, fileModified: early))
        XCTAssertFalse(needsIndexing(extractedAt: late, fileModified: nil),
                       "a missing date is not a reason to read every file again")
    }

    /// Text stored before page markers existed carries no format, and no file date will
    /// ever make it stale on its own, so the format is what asks for it to be read again.
    func testTextWithoutAFormatIsAlwaysStale() {
        let late = Date(timeIntervalSince1970: 2_000)
        let early = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(needsIndexing(extractedAt: late, fileModified: early, format: nil))
        XCTAssertFalse(needsIndexing(extractedAt: late, fileModified: early, format: .markdown))
        XCTAssertFalse(needsIndexing(extractedAt: late, fileModified: early, format: .clipped),
                       "clipped is as read as it is going to get, not unread")
    }
}
