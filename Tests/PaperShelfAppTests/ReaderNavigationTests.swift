import XCTest
@testable import PaperShelf

final class ReaderNavigationTests: XCTestCase {

    func testAHorizontalSwipeMovesToTheNextOrPreviousDocument() {
        XCTAssertEqual(FitWidthPDFView.documentStep(horizontal: -80, vertical: 0), 1)
        XCTAssertEqual(FitWidthPDFView.documentStep(horizontal: 80, vertical: 0), -1)
    }

    func testAShortOrMostlyVerticalGestureStaysInTheCurrentDocument() {
        XCTAssertNil(FitWidthPDFView.documentStep(horizontal: 79, vertical: 0))
        XCTAssertNil(FitWidthPDFView.documentStep(horizontal: 100, vertical: 90))
    }

    func testNativeSwipeDirectionMovesToTheExpectedDocument() {
        XCTAssertEqual(FitWidthPDFView.documentStep(forSwipeDeltaX: 1, deltaY: 0), 1)
        XCTAssertEqual(FitWidthPDFView.documentStep(forSwipeDeltaX: -1, deltaY: 0), -1)
        XCTAssertNil(FitWidthPDFView.documentStep(forSwipeDeltaX: 1, deltaY: 1))
    }

    func testLeftAndRightPageTurnsCanBeDisabled() {
        XCTAssertEqual(FitWidthPDFView.pageStep(for: 123, arrowsEnabled: true), -1)
        XCTAssertEqual(FitWidthPDFView.pageStep(for: 124, arrowsEnabled: true), 1)
        XCTAssertNil(FitWidthPDFView.pageStep(for: 123, arrowsEnabled: false))
        XCTAssertNil(FitWidthPDFView.pageStep(for: 125, arrowsEnabled: true))
    }

    func testReaderCommandsIncludeDocumentNavigation() {
        XCTAssertTrue(ResultsPane.decisionsInTheReader.contains(.nextFile))
        XCTAssertTrue(ResultsPane.decisionsInTheReader.contains(.previousFile))
        XCTAssertEqual(Command.findInDocument.scope, .reader)
        XCTAssertEqual(Command.findInDocument.defaultShortcut, Shortcut("f", .command))
    }

    func testSpaceOpensQuickLookOnlyForASelectedCatalogueOrListFile() {
        XCTAssertTrue(ResultsPane.shouldOpenQuickLook(keyCode: 49, viewMode: .catalogue,
                                                       reading: false, readerOpen: false,
                                                       hasSelection: true))
        XCTAssertTrue(ResultsPane.shouldOpenQuickLook(keyCode: 49, viewMode: .list,
                                                       reading: false, readerOpen: false,
                                                       hasSelection: true))
        XCTAssertFalse(ResultsPane.shouldOpenQuickLook(keyCode: 49, viewMode: .bibliography,
                                                        reading: false, readerOpen: false,
                                                        hasSelection: true))
        XCTAssertFalse(ResultsPane.shouldOpenQuickLook(keyCode: 49, viewMode: .catalogue,
                                                        reading: false, readerOpen: false,
                                                        hasSelection: false))
        XCTAssertFalse(ResultsPane.shouldOpenQuickLook(keyCode: 49, viewMode: .catalogue,
                                                        reading: true, readerOpen: false,
                                                        hasSelection: true))
        XCTAssertFalse(ResultsPane.shouldOpenQuickLook(keyCode: 49, viewMode: .catalogue,
                                                        reading: false, readerOpen: true,
                                                        hasSelection: true))
    }
}
