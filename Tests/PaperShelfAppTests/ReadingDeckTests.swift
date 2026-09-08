import XCTest
@testable import PaperShelf

/// The rules for what is open and which of it is showing, with no window anywhere. This is
/// the shape `Regions.next` and `SplitLayout` already use in this codebase, and the reason
/// they are the parts of the layout that have real tests.
@MainActor
final class ReadingDeckTests: XCTestCase {

    private func empty() -> Deck { Deck.one(pane: UUID()) }
    private func annotator() -> Annotator { Annotator() }

    private func open(_ deck: Deck, _ keys: [String], kept: Bool = true) -> Deck {
        keys.reduce(deck) { $0.opening($1, kept: kept, makeAnnotator: annotator) }
    }

    // MARK: opening

    func testOpeningADocumentMakesItTheActiveTab() {
        let deck = open(empty(), ["a.pdf"])
        XCTAssertEqual(deck.activeTab?.key, "a.pdf")
        XCTAssertEqual(deck.active?.tabs.count, 1)
    }

    func testTabsKeepTheOrderTheyWereOpenedIn() {
        let deck = open(empty(), ["a.pdf", "b.pdf", "c.pdf"])
        XCTAssertEqual(deck.active?.tabs.map(\.key), ["a.pdf", "b.pdf", "c.pdf"])
        XCTAssertEqual(deck.activeTab?.key, "c.pdf")
    }

    /// Opening a document the pane already holds is a request to look at it, not a request
    /// for a second copy of it. A palette that opened duplicates would fill the bar with the
    /// same paper.
    func testOpeningSomethingAlreadyOpenActivatesItRatherThanDuplicating() {
        var deck = open(empty(), ["a.pdf", "b.pdf"])
        deck = deck.opening("a.pdf", kept: true, makeAnnotator: annotator)
        XCTAssertEqual(deck.active?.tabs.count, 2)
        XCTAssertEqual(deck.activeTab?.key, "a.pdf")
    }

    /// And it keeps the annotator it already had rather than building a second one. Nothing
    /// in the window reads it yet, so reopening still re-reads the paper; this is what will
    /// stop it doing that the day the window does.
    func testReopeningKeepsTheAnnotatorItAlreadyHad() {
        var deck = open(empty(), ["a.pdf"])
        let first = deck.activeTab?.annotator
        deck = deck.opening("a.pdf", kept: true, makeAnnotator: annotator)
        XCTAssertTrue(deck.activeTab?.annotator === first)
    }

    /// Whichever route `opening` takes, kept or preview, new or already open, it ends with
    /// the document it was asked for on screen. An open that shows something else is an
    /// open that did not happen as far as the reader is concerned.
    func testOpeningAlwaysShowsTheDocumentItOpened() {
        var deck = empty()
        for (key, kept) in [("a.pdf", true), ("b.pdf", false), ("c.pdf", false),
                            ("a.pdf", false), ("d.pdf", true), ("a.pdf", true)] {
            deck = deck.opening(key, kept: kept, makeAnnotator: annotator)
            XCTAssertEqual(deck.activeTab?.key, key, "after opening \(key), kept: \(kept)")
        }
    }

    // MARK: the preview tab

    /// The reviewer moves its selection down a folder of two hundred files. Each one shows,
    /// none of them accumulates.
    func testThePreviewTabIsReplacedRatherThanAddedTo() {
        var deck = empty()
        for key in ["a.pdf", "b.pdf", "c.pdf"] {
            deck = deck.opening(key, kept: false, makeAnnotator: annotator)
        }
        XCTAssertEqual(deck.active?.tabs.map(\.key), ["c.pdf"])
        XCTAssertEqual(deck.activeTab?.isPreview, true)
    }

    func testAPreviewTabSitsAheadOfTheKeptOnes() {
        var deck = open(empty(), ["a.pdf", "b.pdf"])
        deck = deck.opening("c.pdf", kept: false, makeAnnotator: annotator)
        XCTAssertEqual(deck.active?.tabs.map(\.key), ["c.pdf", "a.pdf", "b.pdf"])
    }

    /// One in the deck, not one per pane. Counting only the active pane's tabs stays green
    /// while a second pane holds a preview of its own, which is exactly the state the split
    /// will be able to reach.
    func testThereIsNeverMoreThanOnePreviewTab() {
        let second = UUID()
        var deck = empty()
        deck.panes.append(Deck.Pane(id: second))
        deck = deck.opening("a.pdf", kept: false, makeAnnotator: annotator)
        deck.activePane = second
        deck = deck.opening("b.pdf", kept: false, makeAnnotator: annotator)
        XCTAssertEqual(deck.panes.flatMap(\.tabs).filter(\.isPreview).count, 1)
    }

    func testPromotingThePreviewTabMakesItStay() {
        var deck = empty()
        deck = deck.opening("a.pdf", kept: false, makeAnnotator: annotator)
        deck = deck.promotingPreview()
        deck = deck.opening("b.pdf", kept: false, makeAnnotator: annotator)
        XCTAssertEqual(deck.active?.tabs.map(\.key), ["b.pdf", "a.pdf"])
        XCTAssertEqual(deck.active?.tabs.filter(\.isPreview).count, 1)
    }

    /// Opening something already open as a kept tab settles it, which is what Enter on a
    /// row the preview is already showing has to mean.
    func testOpeningThePreviewsOwnDocumentAsKeptPromotesIt() {
        var deck = empty()
        deck = deck.opening("a.pdf", kept: false, makeAnnotator: annotator)
        deck = deck.opening("a.pdf", kept: true, makeAnnotator: annotator)
        XCTAssertEqual(deck.active?.tabs.count, 1)
        XCTAssertEqual(deck.activeTab?.isPreview, false)
    }

    /// The selection landing on a paper that is already open takes its own old tab with
    /// it. The preview tab is where the selection is, so one left standing beside the
    /// paper the selection has moved to names, in italics, a paper nobody is looking at.
    func testPreviewingAPaperAlreadyOpenTakesTheStaleTabWithIt() {
        var deck = open(empty(), ["kept.pdf"])
        deck = deck.opening("prev.pdf", kept: false, makeAnnotator: annotator)
        XCTAssertEqual(deck.active?.tabs.map(\.key), ["prev.pdf", "kept.pdf"])

        deck = deck.opening("kept.pdf", kept: false, makeAnnotator: annotator)
        XCTAssertEqual(deck.active?.tabs.map(\.key), ["kept.pdf"])
        XCTAssertEqual(deck.activeTab?.key, "kept.pdf")
        XCTAssertEqual(deck.activeTab?.isPreview, false, "somebody asked for this one")
    }

    /// The same invariant with two panes, which is where it used to break. The selection
    /// replaces the deck's preview wherever it sits, so what is showing has to follow it
    /// into that pane. Left behind, the deck shows the other pane's paper instead.
    func testOpeningShowsWhatItOpenedWhenThePreviewIsInAnotherPane() {
        let second = UUID()
        var deck = empty()
        deck.panes.append(Deck.Pane(id: second))
        deck = deck.opening("first.pdf", kept: false, makeAnnotator: annotator)
        deck.activePane = second
        deck = deck.opening("kept-in-b.pdf", kept: true, makeAnnotator: annotator)
        deck = deck.opening("second.pdf", kept: false, makeAnnotator: annotator)
        XCTAssertEqual(deck.activeTab?.key, "second.pdf")
    }

    /// And when the pane that was active holds nothing, being left behind shows nothing at
    /// all, which reads as the open having been ignored.
    func testOpeningShowsWhatItOpenedWhenTheActivePaneIsEmpty() {
        let second = UUID()
        var deck = empty()
        deck.panes.append(Deck.Pane(id: second))
        deck = deck.opening("first.pdf", kept: false, makeAnnotator: annotator)
        deck.activePane = second
        deck = deck.opening("second.pdf", kept: false, makeAnnotator: annotator)
        XCTAssertEqual(deck.activeTab?.key, "second.pdf")
    }

    /// The pane the tab lands in is the pane that has to be asked whether the document is
    /// already open. The selection replaces the deck's preview wherever it sits, so a
    /// document kept in that pane comes back as a second tab on the same paper when the
    /// question is put to the active pane instead. Two panes are needed to reach it.
    func testOpeningDoesNotAddASecondTabForWhatThatPaneAlreadyHolds() {
        let second = UUID()
        var deck = empty()
        deck.panes.append(Deck.Pane(id: second))
        deck = deck.opening("x.pdf", kept: true, makeAnnotator: annotator)
        deck = deck.opening("p.pdf", kept: false, makeAnnotator: annotator)
        deck.activePane = second
        deck = deck.opening("x.pdf", kept: false, makeAnnotator: annotator)
        XCTAssertEqual(deck.panes[0].tabs.map(\.key), ["x.pdf"],
                       "and the preview it left behind goes with it")
        XCTAssertEqual(deck.activeTab?.key, "x.pdf")
        XCTAssertEqual(deck.activePane, deck.panes[0].id, "showing it means being where it is")
    }

    // MARK: closing

    func testClosingTheActiveTabActivatesTheOneAfterIt() {
        var deck = open(empty(), ["a.pdf", "b.pdf", "c.pdf"])
        deck = deck.activating(deck.active!.tabs[1].id)
        deck = deck.closing(deck.activeTab!.id)
        XCTAssertEqual(deck.activeTab?.key, "c.pdf")
    }

    /// Closing the last tab has nothing to its right, so it falls back to the left rather
    /// than leaving the pane with nothing showing while it still holds documents.
    func testClosingTheLastTabActivatesTheOneBeforeIt() {
        var deck = open(empty(), ["a.pdf", "b.pdf"])
        deck = deck.closing(deck.activeTab!.id)
        XCTAssertEqual(deck.activeTab?.key, "a.pdf")
    }

    func testClosingATabThatIsNotActiveLeavesTheActiveOneAlone() {
        var deck = open(empty(), ["a.pdf", "b.pdf"])
        deck = deck.closing(deck.active!.tabs[0].id)
        XCTAssertEqual(deck.activeTab?.key, "b.pdf")
    }

    func testClosingTheOnlyTabLeavesAnEmptyPane() {
        var deck = open(empty(), ["a.pdf"])
        deck = deck.closing(deck.activeTab!.id)
        XCTAssertEqual(deck.active?.tabs.count, 0)
        XCTAssertNil(deck.activeTab)
        XCTAssertEqual(deck.panes.count, 1, "the pane stays, it is only empty")
    }

    func testClosingAKeyThatIsNotOpenChangesNothing() {
        let deck = open(empty(), ["a.pdf"])
        XCTAssertEqual(deck.closing(UUID()), deck)
    }

    // MARK: stepping

    func testSteppingWrapsAtBothEnds() {
        var deck = open(empty(), ["a.pdf", "b.pdf", "c.pdf"])
        deck = deck.stepping(by: 1)
        XCTAssertEqual(deck.activeTab?.key, "a.pdf")
        deck = deck.stepping(by: -1)
        XCTAssertEqual(deck.activeTab?.key, "c.pdf")
    }

    func testSteppingAnEmptyPaneDoesNothing() {
        let deck = empty()
        XCTAssertEqual(deck.stepping(by: 1), deck)
    }

    // MARK: what is remembered between launches

    func testTheStoredShapeIsTheOrderAndWhatWasShowing() {
        var deck = open(empty(), ["a.pdf", "b.pdf", "c.pdf"])
        deck = deck.activating(deck.active!.tabs[1].id)
        let stored = StoredDeck(deck)
        XCTAssertEqual(stored.panes, [["a.pdf", "b.pdf", "c.pdf"]])
        XCTAssertEqual(stored.active, [1])
        XCTAssertEqual(stored.activePane, 0)
    }

    /// The preview tab is the reviewer's selection, not something anybody opened, so it is
    /// not worth carrying across a launch.
    func testThePreviewTabIsNotStored() {
        var deck = open(empty(), ["a.pdf"])
        deck = deck.opening("b.pdf", kept: false, makeAnnotator: annotator)
        XCTAssertEqual(StoredDeck(deck).panes, [["a.pdf"]])
    }

    /// The stored index counts what was stored, and the preview tab is not part of that.
    /// Counting it would point the next launch at the paper beside the one you were
    /// reading, or off the end of the bar entirely.
    func testTheStoredIndexCountsOnlyTheTabsThatWereStored() {
        var deck = open(empty(), ["a.pdf", "b.pdf"])
        deck = deck.opening("c.pdf", kept: false, makeAnnotator: annotator)
        deck = deck.activating(deck.active!.tabs[2].id)
        let stored = StoredDeck(deck)
        XCTAssertEqual(stored.panes, [["a.pdf", "b.pdf"]])
        XCTAssertEqual(stored.active, [1])
        let back = Deck.restoring(stored, reachable: { _ in true },
                                  makeAnnotator: { _ in self.annotator() })
        XCTAssertEqual(back.activeTab?.key, "b.pdf")
    }

    func testAStoredDeckComesBackInOrder() {
        var deck = open(empty(), ["a.pdf", "b.pdf", "c.pdf"])
        deck = deck.activating(deck.active!.tabs[1].id)
        let back = Deck.restoring(StoredDeck(deck), reachable: { _ in true },
                                  makeAnnotator: { _ in self.annotator() })
        XCTAssertEqual(back.active?.tabs.map(\.key), ["a.pdf", "b.pdf", "c.pdf"])
        XCTAssertEqual(back.activeTab?.key, "b.pdf")
    }

    /// A file that has been renamed, moved or trashed since the last launch is dropped
    /// without comment, the way an unreachable source already is.
    func testATabWhoseFileIsGoneIsDropped() {
        let deck = open(empty(), ["a.pdf", "gone.pdf", "c.pdf"])
        let back = Deck.restoring(StoredDeck(deck), reachable: { $0 != "gone.pdf" },
                                  makeAnnotator: { _ in self.annotator() })
        XCTAssertEqual(back.active?.tabs.map(\.key), ["a.pdf", "c.pdf"])
    }

    /// And if the one that was showing is the one that went, something else shows rather
    /// than the window opening onto nothing.
    func testTheActiveTabGoingLeavesSomethingElseShowing() {
        var deck = open(empty(), ["a.pdf", "gone.pdf"])
        deck = deck.activating(deck.active!.tabs[1].id)
        let back = Deck.restoring(StoredDeck(deck), reachable: { $0 != "gone.pdf" },
                                  makeAnnotator: { _ in self.annotator() })
        XCTAssertEqual(back.activeTab?.key, "a.pdf")
    }

    func testAnEmptyStoredDeckRestoresToAnEmptyPane() {
        let back = Deck.restoring(StoredDeck(empty()), reachable: { _ in true },
                                  makeAnnotator: { _ in self.annotator() })
        XCTAssertEqual(back.panes.count, 1)
        XCTAssertNil(back.activeTab)
    }

    /// Which pane was active is part of what was open, and one pane hides whether either
    /// side of the round trip remembers it: every index is 0 by construction there, so the
    /// writing side and the reading side cannot disagree.
    func testWhichPaneWasActiveComesBack() {
        let second = UUID()
        var deck = empty()
        deck.panes.append(Deck.Pane(id: second))
        deck = deck.opening("a.pdf", kept: true, makeAnnotator: annotator)
        deck.activePane = second
        deck = deck.opening("c.pdf", kept: true, makeAnnotator: annotator)

        let stored = StoredDeck(deck)
        XCTAssertEqual(stored.panes, [["a.pdf"], ["c.pdf"]])
        XCTAssertEqual(stored.activePane, 1)

        let back = Deck.restoring(stored, reachable: { _ in true },
                                  makeAnnotator: { _ in self.annotator() })
        XCTAssertEqual(back.panes.map { $0.tabs.map(\.key) }, [["a.pdf"], ["c.pdf"]])
        XCTAssertEqual(back.active?.tabs.map(\.key), ["c.pdf"], "the second pane was the one in use")
        XCTAssertEqual(back.activeTab?.key, "c.pdf")
    }

    /// Nothing this app writes has zero panes, but a truncated or hand-edited preferences
    /// string decodes to one, and a window with no pane has nowhere to put a document.
    /// Restoring it has to hand back a pane rather than reading off the end of the array.
    func testADeckStoredWithNoPanesComesBackWithOne() throws {
        let stored = try JSONDecoder().decode(
            StoredDeck.self, from: Data(#"{"panes":[],"active":[],"activePane":0}"#.utf8))
        let back = Deck.restoring(stored, reachable: { _ in true },
                                  makeAnnotator: { _ in self.annotator() })
        XCTAssertEqual(back.panes.count, 1)
        XCTAssertEqual(back.activePane, back.panes[0].id)
        XCTAssertNil(back.activeTab)
    }

    /// What goes to disk has to be pinned by its names on disk. Encoding and decoding
    /// through the same initialiser and comparing the two cancels any error in it, and
    /// leaves every field free to be renamed under a version that has to read it back.
    func testTheStoredNamesOnDiskAreTheOnesReadBack() throws {
        var deck = open(empty(), ["a.pdf", "b.pdf"])
        deck = deck.activating(deck.active!.tabs[0].id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let written = String(decoding: try encoder.encode(StoredDeck(deck)), as: UTF8.self)
        XCTAssertEqual(written, #"{"active":[0],"activePane":0,"panes":[["a.pdf","b.pdf"]]}"#)

        let stored = try JSONDecoder().decode(
            StoredDeck.self,
            from: Data(#"{"panes":[["a.pdf","b.pdf"]],"active":[1],"activePane":0}"#.utf8))
        let back = Deck.restoring(stored, reachable: { _ in true },
                                  makeAnnotator: { _ in self.annotator() })
        XCTAssertEqual(back.active?.tabs.map(\.key), ["a.pdf", "b.pdf"])
        XCTAssertEqual(back.activeTab?.key, "b.pdf")
    }
}
