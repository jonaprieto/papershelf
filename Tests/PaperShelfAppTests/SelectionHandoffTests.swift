import XCTest
import PDFKit
import AppKit
import CoreText
import PaperShelfCore
@testable import PaperShelf

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

    func testHighlightEditsUpdateTheRailWithoutRescanningTheDocument() throws {
        let document = try makeDocument(["alpha"])
        let view = PDFView()
        view.document = document
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("annotator-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(document.write(to: url))

        let annotator = Annotator()
        annotator.attach(view, url: url)
        view.currentSelection = try XCTUnwrap(
            document.findString("alpha", withOptions: []).first)

        XCTAssertEqual(annotator.highlightSelection(colour: .yellow, note: "keep"), 1)
        XCTAssertEqual(annotator.marks.count, 1)
        let mark = try XCTUnwrap(annotator.marks.first)

        annotator.setNote("revisit", on: mark)
        XCTAssertEqual(annotator.marks.first?.note, "revisit")
        annotator.setColour(.green, on: mark)
        XCTAssertEqual(annotator.marks.first?.colour, .green)
        XCTAssertEqual(annotator.marks.first?.note, "revisit")

        annotator.remove(mark)
        XCTAssertTrue(annotator.marks.isEmpty)
        annotator.flush()
    }

    func testHighlightQuoteMatchesTheSelectedTextAcrossWrappedLines() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("annotator-wrap-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = String(repeating: "Sentences that wrap across lines. ", count: 30)
        try makeTextPDF(at: url, text: source)
        let document = try XCTUnwrap(PDFDocument(url: url))
        let view = PDFView()
        view.document = document
        let annotator = Annotator()
        annotator.attach(view, url: url)
        let expected = try XCTUnwrap(
            document.findString("Sentences that wrap across lines. Sentences that wrap", withOptions: [])
                .first?.string
        )
        view.currentSelection = try XCTUnwrap(
            document.findString("Sentences that wrap across lines. Sentences that wrap", withOptions: []).first)

        XCTAssertEqual(annotator.highlightSelection(colour: .yellow), 1)
        let mark = try XCTUnwrap(annotator.marks.first)
        let normalized = expected.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertEqual(mark.quoted, normalized)
        annotator.flush()
    }

    func testQuoteExtractionAcceptsPageSpaceQuadrilaterals() throws {
        let document = try makeDocument(["alpha beta gamma"])
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(document.findString("alpha beta", withOptions: []).first)
        let bounds = selection.bounds(for: page)
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        annotation.quadrilateralPoints = [
            NSValue(point: NSPoint(x: bounds.minX, y: bounds.maxY)),
            NSValue(point: NSPoint(x: bounds.maxX, y: bounds.maxY)),
            NSValue(point: NSPoint(x: bounds.minX, y: bounds.minY)),
            NSValue(point: NSPoint(x: bounds.maxX, y: bounds.minY)),
        ]
        page.addAnnotation(annotation)

        XCTAssertEqual(page.selection(for: bounds)?.string, "alpha beta")
        XCTAssertEqual(PaperShelfCore.quotedText(of: annotation, on: page), "alpha beta")
    }

    func testQuoteExtractionPreservesUnicodePunctuationAndLigatures() throws {
        let phrase = "Office fiancée, naïve: λ."
        let document = try makeDocument(["Office ﬁancée, naïve: λ."])
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(document.findString(phrase, withOptions: []).first)
        let annotation = PDFAnnotation(bounds: selection.bounds(for: page),
                                       forType: .highlight, withProperties: nil)
        let bounds = annotation.bounds
        annotation.quadrilateralPoints = [
            NSValue(point: NSPoint(x: bounds.minX, y: bounds.maxY)),
            NSValue(point: NSPoint(x: bounds.maxX, y: bounds.maxY)),
            NSValue(point: NSPoint(x: bounds.minX, y: bounds.minY)),
            NSValue(point: NSPoint(x: bounds.maxX, y: bounds.minY)),
        ]
        page.addAnnotation(annotation)

        XCTAssertEqual(PaperShelfCore.quotedText(of: annotation, on: page), phrase)
    }

    func testRemoveAllMarksLeavesLinksAlone() throws {
        let document = try makeDocument(["alpha"])
        let page = try XCTUnwrap(document.page(at: 0))
        let link = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 40, height: 20),
                                 forType: .link, withProperties: nil)
        page.addAnnotation(link)
        let view = PDFView()
        view.document = document
        let annotator = Annotator()
        annotator.attach(view, url: URL(fileURLWithPath: "/tmp/annotator-links.pdf"))
        view.currentSelection = try XCTUnwrap(
            document.findString("alpha", withOptions: []).first)
        XCTAssertEqual(annotator.highlightSelection(colour: .yellow), 1)

        annotator.removeAll()

        XCTAssertTrue(page.annotations.contains { $0.type == "Link" })
        XCTAssertFalse(page.annotations.contains { $0.type == "Highlight" })
    }
}
