import XCTest
import PDFKit
@testable import PaperShelf

/// Marking a passage writes into the file straight away, so ⌘Z has to write into it again
/// rather than cancel something pending. These check that what comes back is the document
/// as it was, not merely a list that looks right.
@MainActor
final class MarkUndoTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".pdf")
        try makeTextPDF(at: scratch, text: "Alpha Beta Gamma Delta")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// An annotator over a real one-page document, with "Beta" selected.
    private func reader() throws -> (Annotator, PDFView, PDFPage) {
        let document = try XCTUnwrap(PDFDocument(url: scratch))
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.document = document
        let annotator = Annotator()
        annotator.attach(view, url: scratch)
        let page = try XCTUnwrap(document.page(at: 0))
        let hit = try XCTUnwrap(document.findString("Beta", withOptions: []).first)
        view.setCurrentSelection(hit, animate: false)
        return (annotator, view, page)
    }

    private func highlights(on page: PDFPage) -> [PDFAnnotation] {
        page.annotations.filter { $0.type == "Highlight" }
    }

    func testUndoTakesAHighlightOffThePageAndOutOfTheFile() throws {
        let (annotator, _, page) = try reader()
        defer { annotator.detach() }

        XCTAssertFalse(annotator.canUndoMarkChange, "nothing done yet")
        XCTAssertEqual(annotator.highlightSelection(colour: .systemYellow), 1)
        XCTAssertEqual(annotator.marks.count, 1)
        XCTAssertEqual(highlights(on: page).count, 1)
        XCTAssertTrue(annotator.canUndoMarkChange)

        XCTAssertTrue(annotator.undoLastMarkChange())
        XCTAssertTrue(annotator.marks.isEmpty, "the rail still lists a mark that is gone")
        XCTAssertTrue(highlights(on: page).isEmpty, "the annotation is still in the document")
        XCTAssertFalse(annotator.canUndoMarkChange)
        XCTAssertFalse(annotator.undoLastMarkChange(), "undid something that was not there")
    }

    /// A deletion comes back as the same annotation on the same page, not as a copy: same
    /// bounds and same colour, which is what makes it the same thing in the file.
    func testUndoPutsADeletedMarkBack() throws {
        let (annotator, _, page) = try reader()
        defer { annotator.detach() }
        annotator.highlightSelection(colour: .systemYellow)
        let mark = try XCTUnwrap(annotator.marks.first)
        let bounds = mark.annotation.bounds

        annotator.remove(mark)
        XCTAssertTrue(highlights(on: page).isEmpty)

        XCTAssertTrue(annotator.undoLastMarkChange())
        XCTAssertEqual(annotator.marks.count, 1)
        let back = try XCTUnwrap(highlights(on: page).first)
        XCTAssertEqual(back.bounds, bounds)
        XCTAssertTrue(back === mark.annotation, "put back a copy rather than the annotation")
    }

    func testUndoRepaintsAndRenotes() throws {
        let (annotator, _, page) = try reader()
        defer { annotator.detach() }
        annotator.highlightSelection(colour: .systemYellow, note: "first")
        let mark = try XCTUnwrap(annotator.marks.first)

        annotator.setColour(.systemPink, on: mark)
        XCTAssertEqual(highlights(on: page).first?.color, NSColor.systemPink)
        XCTAssertTrue(annotator.undoLastMarkChange())
        XCTAssertEqual(highlights(on: page).first?.color, NSColor.systemYellow)

        annotator.setNote("second", on: try XCTUnwrap(annotator.marks.first))
        XCTAssertEqual(highlights(on: page).first?.contents, "second")
        XCTAssertTrue(annotator.undoLastMarkChange())
        XCTAssertEqual(highlights(on: page).first?.contents, "first")
    }

    /// One selection, one ⌘Z. Two separate highlights are two steps.
    func testEachActionIsOneStep() throws {
        let (annotator, view, _) = try reader()
        defer { annotator.detach() }
        let document = try XCTUnwrap(view.document)
        annotator.highlightSelection(colour: .systemYellow)
        view.setCurrentSelection(try XCTUnwrap(document.findString("Gamma", withOptions: []).first),
                                 animate: false)
        annotator.highlightSelection(colour: .systemTeal)
        XCTAssertEqual(annotator.marks.count, 2)

        annotator.undoLastMarkChange()
        XCTAssertEqual(annotator.marks.count, 1, "one undo took back two highlights")
        annotator.undoLastMarkChange()
        XCTAssertTrue(annotator.marks.isEmpty)
    }

    /// Clearing every mark keeps its confirmation instead, and takes the stack with it:
    /// the steps point at annotations no page holds any more.
    func testClearingEverythingIsNotUndoable() throws {
        let (annotator, _, _) = try reader()
        defer { annotator.detach() }
        annotator.highlightSelection(colour: .systemYellow)
        XCTAssertTrue(annotator.canUndoMarkChange)
        annotator.removeAll()
        XCTAssertFalse(annotator.canUndoMarkChange)
    }

    /// Opening another paper drops what was pending for the last one. An undo that reached
    /// into a document nobody is looking at would be editing a file behind your back.
    func testOpeningAnotherDocumentDropsTheStack() throws {
        let (annotator, view, _) = try reader()
        defer { annotator.detach() }
        annotator.highlightSelection(colour: .systemYellow)
        XCTAssertTrue(annotator.canUndoMarkChange)

        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".pdf")
        try makeTextPDF(at: other, text: "Another paper entirely")
        defer { try? FileManager.default.removeItem(at: other) }
        view.document = PDFDocument(url: other)
        annotator.attach(view, url: other)
        XCTAssertFalse(annotator.canUndoMarkChange)
    }
}
