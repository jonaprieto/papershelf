import XCTest
import PDFKit
import AppKit
import CoreText
@testable import PDFHammer

/// The floating bar hands a live selection to ChatGPT, and a selection is not a mark: the
/// page and the title have to be read off what is on screen rather than from anything
/// stored. That reading is what this covers.
@MainActor
final class SelectionHandoffTests: XCTestCase {

    /// A two-page PDF with a different, findable word on each page.
    private func makeDocument(_ words: [String]) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for word in words {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: word,
                                   attributes: [.font: NSFont.systemFont(ofSize: 14)]))
            context.textPosition = CGPoint(x: 20, y: 100)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    func testNothingOnScreenHandsOverNothing() {
        XCTAssertNil(Annotator().selectionForHandoff())
    }

    func testAnEmptySelectionHandsOverNothing() throws {
        let view = PDFView()
        view.document = try makeDocument(["alpha"])
        let annotator = Annotator()
        annotator.attach(view, url: URL(fileURLWithPath: "/tmp/A Book.pdf"))

        XCTAssertNil(annotator.selectionForHandoff(), "no selection is not a passage")
    }

    /// The page is the one the selection sits on, counted the way a reader counts pages
    /// rather than the way an array is indexed, and the title is the file's name without
    /// the extension.
    func testASelectionCarriesItsPageAndTheDocumentTitle() throws {
        let document = try makeDocument(["alpha", "bravo"])
        let view = PDFView()
        view.document = document
        let annotator = Annotator()
        annotator.attach(view, url: URL(fileURLWithPath: "/tmp/A Book.pdf"))
        view.currentSelection = try XCTUnwrap(
            document.findString("bravo", withOptions: []).first, "the fixture lost its text")

        let handoff = try XCTUnwrap(annotator.selectionForHandoff())
        XCTAssertEqual(handoff.quoted, "bravo")
        XCTAssertEqual(handoff.page, 2, "page numbers are one-based on the page")
        XCTAssertEqual(handoff.title, "A Book")
    }
}
