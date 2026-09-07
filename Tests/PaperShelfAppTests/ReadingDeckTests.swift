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

    /// And it keeps the annotator it already had, so the marks, the outline and the find
    /// session survive being reopened.
    func testReopeningKeepsTheAnnotatorItAlreadyHad() {
        var deck = open(empty(), ["a.pdf"])
        let first = deck.activeTab?.annotator
        deck = deck.opening("a.pdf", kept: true, makeAnnotator: annotator)
        XCTAssertTrue(deck.activeTab?.annotator === first)
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

    func testStoredDecksSurviveJSON() throws {
        var deck = open(empty(), ["a.pdf", "b.pdf"])
        deck = deck.activating(deck.active!.tabs[0].id)
        let data = try JSONEncoder().encode(StoredDeck(deck))
        XCTAssertEqual(try JSONDecoder().decode(StoredDeck.self, from: data), StoredDeck(deck))
    }
}
