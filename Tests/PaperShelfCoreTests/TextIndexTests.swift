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

        let text = try XCTUnwrap(documentText(of: file, passwords: []))
        XCTAssertTrue(text.contains("Stochastic epidemic"))

        // The cap is a character count, not a page count.
        let clipped = try XCTUnwrap(documentText(of: file, passwords: [], limit: 6))
        XCTAssertEqual(clipped.count, 6)
    }

    /// Two different answers that must not be confused: a file that cannot be opened is
    /// worth trying again when the disk comes back, a scan with no text layer is not.
    func testUnreadableIsNilAndATextlessDocumentIsEmpty() throws {
        let directory = try scratch("text-index-empty")
        defer { try? FileManager.default.removeItem(at: directory) }
        let blank = directory.appendingPathComponent("blank.pdf")
        try makePDF(at: blank, password: nil)

        XCTAssertEqual(documentText(of: blank, passwords: [])?.trimmingCharacters(in: .whitespacesAndNewlines), "")
        XCTAssertNil(documentText(of: directory.appendingPathComponent("gone.pdf"), passwords: []))
    }

    func testALockedDocumentNoPasswordOpensIsNotIndexed() throws {
        let directory = try scratch("text-index-locked")
        defer { try? FileManager.default.removeItem(at: directory) }
        let locked = directory.appendingPathComponent("locked.pdf")
        try makePDF(at: locked, password: "secret")

        XCTAssertNil(documentText(of: locked, passwords: []), "no password, no text")
        XCTAssertNotNil(documentText(of: locked, passwords: ["secret"]))
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
}
