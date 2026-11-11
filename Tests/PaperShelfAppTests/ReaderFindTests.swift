import XCTest
import PDFKit
import AppKit
@testable import PaperShelf

@MainActor
final class ReaderFindTests: XCTestCase {

    func testReaderKeyboardClaimsCommandFBeforePDFKit() throws {
        let find = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                   modifierFlags: .command, timestamp: 0,
                                                   windowNumber: 0, context: nil,
                                                   characters: "f", charactersIgnoringModifiers: "f",
                                                   isARepeat: false, keyCode: 3))
        let other = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                    modifierFlags: .command, timestamp: 0,
                                                    windowNumber: 0, context: nil,
                                                    characters: "g", charactersIgnoringModifiers: "g",
                                                    isARepeat: false, keyCode: 5))
        XCTAssertTrue(ResultsPane.requestsPDFSearch(find))
        XCTAssertFalse(ResultsPane.requestsPDFSearch(other))
    }

    /// ⌘F brings Find out and puts it away again, and putting it away gives the rail back
    /// as it was: hidden when Find opened it, on Pages when that was showing.
    func testFindTogglesAndGivesTheRailBack() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName("reader-find-toggle"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("paper.pdf")
        try makeTextPDF(at: file, text: "Needle.")
        let view = PDFView()
        view.document = try XCTUnwrap(PDFDocument(url: file))
        let annotator = Annotator()
        annotator.attach(view, url: file)

        let prefs = Prefs.shared
        let saved = (prefs.contentsShown, prefs.contentsRailMode)
        defer { prefs.contentsShown = saved.0; prefs.contentsRailMode = saved.1 }

        prefs.contentsShown = false
        prefs.contentsRailMode = .outline
        toggleFind(annotator, prefs: prefs)
        XCTAssertTrue(annotator.showsFind)
        XCTAssertTrue(prefs.contentsShown)
        XCTAssertEqual(prefs.contentsRailMode, .find)
        toggleFind(annotator, prefs: prefs)
        XCTAssertFalse(annotator.showsFind)
        XCTAssertFalse(prefs.contentsShown, "Find opened the rail, so closing it hides the rail")
        XCTAssertEqual(prefs.contentsRailMode, .outline)

        prefs.contentsShown = true
        prefs.contentsRailMode = .thumbnails
        toggleFind(annotator, prefs: prefs)
        annotator.closeFind()
        prefs.closeFindRail()
        XCTAssertTrue(prefs.contentsShown)
        XCTAssertEqual(prefs.contentsRailMode, .thumbnails)
    }

    func testFindListsEveryOccurrenceAndMovesBetweenExactSelections() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName("reader-find"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("paper.pdf")
        try makeTextPDF(at: file, pages: [
            "Needle at the start. Another needle on this page.",
            "A final needle is on page two."
        ])

        let view = PDFView()
        view.document = try XCTUnwrap(PDFDocument(url: file))
        let annotator = Annotator()
        annotator.attach(view, url: file)
        annotator.openFind()
        annotator.findQuery = "needle"
        annotator.updateFindHits()

        XCTAssertEqual(annotator.findHits.map(\.page), [1, 1, 2])
        XCTAssertEqual(annotator.selectedFindHit, 0)
        XCTAssertNil(view.currentSelection)
        annotator.stepFind(by: 1, jumping: false)
        XCTAssertEqual(annotator.selectedFindHit, 1)
        XCTAssertNil(view.currentSelection)
        annotator.jumpToSelectedFindHit()
        XCTAssertEqual(view.currentSelection?.string?.lowercased(), "needle")
        annotator.stepFind(by: 1)
        XCTAssertEqual(annotator.selectedFindHit, 2)
        XCTAssertEqual(view.currentSelection?.string?.lowercased(), "needle")
        annotator.stepFind(by: -1, jumping: false)
        XCTAssertEqual(annotator.selectedFindHit, 1)
        annotator.stepFind(by: -1, jumping: false)
        XCTAssertEqual(annotator.selectedFindHit, 0)
        annotator.stepFind(by: -1, jumping: false)
        XCTAssertEqual(annotator.selectedFindHit, 2, "previous wraps to the final occurrence")
    }

    /// A note is not page text, so PDFKit alone never finds it. Its hit is listed with the
    /// page's own matches and turns to the mark it is written on.
    func testFindAlsoMatchesNotesAndTurnsToTheirMark() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName("reader-find-notes"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("paper.pdf")
        try makeTextPDF(at: file, pages: ["Alpha Beta on one.", "Gamma on two, with a quorum."])

        let document = try XCTUnwrap(PDFDocument(url: file))
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.document = document
        let annotator = Annotator()
        annotator.attach(view, url: file)
        defer { annotator.detach() }
        view.setCurrentSelection(try XCTUnwrap(document.findString("Beta", withOptions: []).first),
                                 animate: false)
        annotator.highlightSelection(colour: .systemYellow, note: "Recall the Quorum rule")
        view.clearSelection()
        let mark = try XCTUnwrap(annotator.marks.first)

        annotator.openFind()
        annotator.findQuery = "quorum"
        annotator.updateFindHits()

        XCTAssertEqual(annotator.findHits.map(\.page), [1, 2], "the note on page one comes first")
        XCTAssertEqual(annotator.findHits.map(\.id), [0, 1])
        XCTAssertEqual(annotator.findHits.first?.mark, mark.id)
        XCTAssertNil(annotator.findHits.last?.mark)
        annotator.jumpToSelectedFindHit()
        XCTAssertEqual(annotator.selectedMark, mark.id)
    }

    func testClosingFindLeavesNoSearchStateForTheNextDocument() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName("reader-find-close"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("paper.pdf")
        try makeTextPDF(at: file, text: "A searchable PDF.")

        let view = PDFView()
        view.document = try XCTUnwrap(PDFDocument(url: file))
        let annotator = Annotator()
        annotator.attach(view, url: file)
        annotator.openFind()
        annotator.findQuery = "searchable"
        annotator.updateFindHits()
        XCTAssertFalse(annotator.findHits.isEmpty)

        annotator.closeFind()
        XCTAssertFalse(annotator.showsFind)
        XCTAssertEqual(annotator.findQuery, "")
        XCTAssertTrue(annotator.findHits.isEmpty)
        XCTAssertNil(annotator.selectedFindHit)
    }
}
