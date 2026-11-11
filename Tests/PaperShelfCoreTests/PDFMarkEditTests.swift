import XCTest
import AppKit
@testable import PaperShelfCore

final class PDFMarkEditTests: XCTestCase {
    private var folder: URL!
    private var pdf: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFMarkEditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        pdf = folder.appendingPathComponent("paper.pdf")
        try makeTextPDF(at: pdf, text: "Linear types track resources. A value of linear "
            + "type is used exactly once, which rules out both duplication and discard. "
            + "Affine types relax this to at most once.")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The whole life of a mark through the file: made, found again by the id it came
    /// back with, renoted, recoloured, and taken off, with every step read from disk.
    func testAMarkIsMadeChangedAndRemovedThroughTheFile() throws {
        let made = try addPDFMark(to: pdf, page: 1, text: "used   exactly\nonce",
                                  colour: .systemYellow, note: "the key rule", author: "Claude")
        var marks = pdfMarks(in: pdf)
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks.first?.id, made.id)
        XCTAssertEqual(marks.first?.note, "the key rule")
        XCTAssertEqual(marks.first?.kind, "highlight")
        XCTAssertEqual(marks.first?.author, "Claude", "the author is stored in the file")
        let madeAt = try XCTUnwrap(marks.first?.modified, "a mark made here records when")
        XCTAssertLessThan(abs(madeAt.timeIntervalSinceNow), 60)
        XCTAssertTrue(marks.first?.quoted.contains("exactly once") == true, marks.first?.quoted ?? "")

        let edited = try editPDFMark(in: pdf, id: made.id, note: "exactly once, not at most",
                                     colour: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        XCTAssertEqual(edited.id, made.id)
        marks = pdfMarks(in: pdf)
        XCTAssertEqual(marks.first?.note, "exactly once, not at most")
        XCTAssertEqual(marks.first?.colour, "#0000FF")

        try addPDFMark(to: pdf, page: 1, text: "Affine types", kind: .underline, colour: .systemRed)
        marks = pdfMarks(in: pdf)
        XCTAssertEqual(marks.count, 2)
        XCTAssertTrue(marks.contains { $0.id == made.id }, "another mark moved the first one's id")

        try removePDFMark(from: pdf, id: made.id)
        marks = pdfMarks(in: pdf)
        XCTAssertEqual(marks.map(\.kind), ["underline"])
        XCTAssertThrowsError(try removePDFMark(from: pdf, id: made.id))
    }

    func testTextThatIsMissingOrRepeatedIsRefused() throws {
        XCTAssertThrowsError(try addPDFMark(to: pdf, page: 1, text: "session types", colour: .yellow))
        XCTAssertThrowsError(try addPDFMark(to: pdf, page: 1, text: "types", colour: .yellow))
        XCTAssertThrowsError(try addPDFMark(to: pdf, page: 2, text: "Affine", colour: .yellow))
        XCTAssertTrue(pdfMarks(in: pdf).isEmpty)
    }

    func testAQuoteMatchesAcrossHyphensLigaturesAndCurlyQuotes() {
        let page = "the \u{FB01}rst lin-\near value\u{2019}s use"
        let found = matches(of: "first linear value's use", in: page)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual((page as NSString).substring(with: found[0]), "\u{FB01}rst lin-\near value\u{2019}s use")
    }
}
