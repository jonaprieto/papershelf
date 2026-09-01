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

    func testReaderCommandsIncludeDocumentNavigation() {
        XCTAssertTrue(ResultsPane.decisionsInTheReader.contains(.nextFile))
        XCTAssertTrue(ResultsPane.decisionsInTheReader.contains(.previousFile))
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
