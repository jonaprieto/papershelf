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

    /// A tab is 180 points wide and a key is a whole path, so the bar asks the library what
    /// the file is called. It has to say something for a document the library does not know:
    /// a restored tab can name a file outside everything the window has scanned, and a bar
    /// of blank tabs is worse than a bar of filenames.
    func testATabIsNamedAfterTheFileEvenWhenTheLibraryDoesNotKnowIt() {
        XCTAssertEqual(ResultsPane.tabTitle("/papers/2017-gomes.pdf", named: "gomes-2017.pdf"),
                       "gomes-2017.pdf")
        XCTAssertEqual(ResultsPane.tabTitle("/papers/2017-gomes.pdf", named: nil),
                       "2017-gomes.pdf")
    }

    /// What is open survives a launch, and a preference that does not decode leaves the
    /// window alone rather than emptying it. Nothing this app writes is malformed; a
    /// truncated write, an older build's format or a hand-edited preference all are.
    @MainActor
    func testTheOpenDocumentsAreWrittenDownAndReadBack() throws {
        let deck = Deck.one(pane: UUID())
            .opening("/papers/a.pdf", kept: true, makeAnnotator: { Annotator() })
            .opening("/papers/b.pdf", kept: true, makeAnnotator: { Annotator() })
        let written = ResultsPane.storedText(StoredDeck(deck))
        let read = try XCTUnwrap(ResultsPane.storedDeck(written))
        XCTAssertEqual(read.panes, [["/papers/a.pdf", "/papers/b.pdf"]])
        XCTAssertEqual(read.active, [1])

        XCTAssertNil(ResultsPane.storedDeck(""))
        XCTAssertNil(ResultsPane.storedDeck("{\"panes\":[[\"/papers/a.pdf\"]]"))
        XCTAssertNil(ResultsPane.storedDeck("/papers/a.pdf"))
    }

    /// The paper you come back to is the paper you were reading, not the first one on the
    /// bar.
    ///
    /// The reviewer's selection is a tab too, and it is never written down, so a write made
    /// while it is the one showing cannot say which paper is being read: the stored index
    /// falls back to the first tab. Reading the third of three papers and then letting the
    /// selection move stored an index of 0, and the next launch opened the first paper. The
    /// deck here changes exactly the way it does in a window, and only what the write site
    /// hands back is kept.
    @MainActor
    func testARelaunchOpensThePaperThatWasBeingRead() throws {
        var deck = Deck.one(pane: UUID())
        for key in ["/lib/a.pdf", "/lib/b.pdf", "/lib/c.pdf"] {
            deck = deck.opening(key, kept: true, makeAnnotator: { Annotator() })
        }
        var written = try XCTUnwrap(ResultsPane.tabsToStore(deck), "reading c.pdf")

        deck = deck.opening("/lib/d.pdf", kept: false, makeAnnotator: { Annotator() })
        if let moved = ResultsPane.tabsToStore(deck) { written = moved }

        let stored = try XCTUnwrap(ResultsPane.storedDeck(written))
        XCTAssertEqual(stored.active, [2])
        let back = Deck.restoring(stored, reachable: { _ in true },
                                  makeAnnotator: { _ in Annotator() })
        XCTAssertEqual(back.activeTab?.key, "/lib/c.pdf")
    }

    /// A document open takes the middle of the window whichever view it was opened from,
    /// and the two views that are about a collection rather than about files keep their own
    /// second pane when nothing is open. Getting this wrong is invisible until somebody
    /// opens a paper out of the bibliography and the page never appears.
    func testAnOpenDocumentPutsThePageInEveryView() {
        for mode in ViewMode.allCases {
            XCTAssertTrue(ResultsPane.showsPage(readerOpen: true, reading: false, viewMode: mode),
                          "\(mode) with a document open")
            XCTAssertTrue(ResultsPane.showsPage(readerOpen: false, reading: true, viewMode: mode),
                          "\(mode) in reading mode")
        }
        XCTAssertTrue(ResultsPane.showsPage(readerOpen: false, reading: false, viewMode: .list))
        XCTAssertTrue(ResultsPane.showsPage(readerOpen: false, reading: false, viewMode: .catalogue))
        XCTAssertFalse(ResultsPane.showsPage(readerOpen: false, reading: false,
                                             viewMode: .bibliography))
        XCTAssertFalse(ResultsPane.showsPage(readerOpen: false, reading: false,
                                             viewMode: .duplicates))
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
