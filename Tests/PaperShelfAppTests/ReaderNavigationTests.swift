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
}
