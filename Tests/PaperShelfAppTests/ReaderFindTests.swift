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
