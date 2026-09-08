# Reading Tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Several documents open at once in the library window, drawn as tabs, so switching between papers keeps each one's marks, outline and find session.

**Architecture:** A value type `Deck` carries the whole arrangement and every change to it is a pure function returning a new `Deck`, so the rules are testable with no window. `ReadingDeck` is the `@Observable` box a view holds. `ResultsPane`'s `reader: String?` is replaced by the deck's active tab, and the reviewer's selection becomes a preview tab that is replaced rather than accumulated.

**Tech Stack:** Swift 6 toolchain in Swift 5 language mode, SwiftUI, XCTest. No third-party dependencies; the README states there are none and adding one would make that false.

## Global Constraints

- No emoji and no em-dashes anywhere: source, comments, Markdown, commit messages. Use a comma, a colon, a semicolon, or two sentences instead.
- `swift build` must be clean with zero warnings.
- Commit messages are a Conventional Commits prefix and then a plain descriptive clause written for a person. No AI-attribution trailers of any kind.
- Every commit is signed (`-S`) and every commit builds and passes on its own.
- Comments explain consequences, not mechanics. Match the voice of the surrounding files.
- Do not enable `mcpFileOperations`. Do not write to the `com.jonaprieto.pdfhammer` preferences domain from a test. Do not write into `~/Library/Application Support/PaperShelf/`.
- Do not launch the GUI app without asking.
- A check that cannot fail is worse than no check. Every new assertion is confirmed by reverting the thing it covers and watching it go red.

## Scope

This plan is tabs in **one** pane. `Deck` holds `panes: [Pane]` because plan 3 adds a second, and reshaping a single-pane model later is the more expensive path, but nothing here creates or draws a second pane, and there is no orientation, no split and no cross-pane drag. Do not add them.

## File Structure

- **Create** `Sources/PaperShelf/ReadingDeck.swift`: the `Deck`, `Pane` and `Tab` value types, the pure functions that change them, and the `ReadingDeck` observable box. One responsibility: what is open and which of it is showing.
- **Create** `Sources/PaperShelf/TabBar.swift`: one pane's tab strip.
- **Create** `Tests/PaperShelfAppTests/ReadingDeckTests.swift`: the pure rules.
- **Create** `Tests/PaperShelfAppTests/TabBarLayoutTests.swift`: offscreen hosting, the overflow hazard.
- **Modify** `Sources/PaperShelf/Catalogue.swift`: `reader: String?` gives way to the deck.
- **Modify** `Sources/PaperShelf/Commands.swift`: four new commands.
- **Modify** `Sources/PaperShelf/Prefs.swift`: one key for the stored deck.

---

### Task 1: The deck and its rules

**Files:**
- Create: `Sources/PaperShelf/ReadingDeck.swift`
- Test: `Tests/PaperShelfAppTests/ReadingDeckTests.swift`

**Interfaces:**
- Consumes: `Annotator` (`Sources/PaperShelf/Annotations.swift`), which is `@MainActor @Observable`.
- Produces:
  ```swift
  struct Deck: Equatable {
      var panes: [Pane]
      var activePane: Pane.ID
      struct Pane: Identifiable, Equatable { let id: UUID; var tabs: [Tab]; var active: Tab.ID? }
      struct Tab: Identifiable, Equatable { let id: UUID; let key: String; var isPreview: Bool; let annotator: Annotator }
      static func one(pane: UUID) -> Deck
      var active: Pane? { get }
      var activeTab: Tab? { get }
      func opening(_ key: String, kept: Bool, makeAnnotator: () -> Annotator) -> Deck
      func activating(_ tab: Tab.ID) -> Deck
      func closing(_ tab: Tab.ID) -> Deck
      func promotingPreview() -> Deck
      func stepping(by delta: Int) -> Deck
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `Tests/PaperShelfAppTests/ReadingDeckTests.swift`:

```swift
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

    func testThereIsNeverMoreThanOnePreviewTab() {
        var deck = empty()
        for key in ["a.pdf", "b.pdf", "c.pdf"] {
            deck = deck.opening(key, kept: false, makeAnnotator: annotator)
        }
        XCTAssertEqual(deck.active?.tabs.filter(\.isPreview).count, 1)
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
}
```

- [ ] **Step 2: Run them and watch them fail**

```
swift test --filter ReadingDeckTests
```

Expected: `error: cannot find 'Deck' in scope`.

- [ ] **Step 3: Write the model**

Create `Sources/PaperShelf/ReadingDeck.swift`. Every mutation is a function returning a new `Deck`, so the rules can be checked without a window. `Tab` holds a reference and is still a value type, which is what makes that possible.

```swift
import SwiftUI
import Observation

/// What a window has open, and which of it is on screen.
///
/// A value type with pure functions rather than a class with methods, for the reason
/// `Regions.next` and every function in `SplitLayout` are written that way: these rules are
/// fiddly, they are the kind that go wrong quietly, and a value in, value out shape is one a
/// test can pin without a window. `ReadingDeck` below is the observable box a view holds.
struct Deck: Equatable {
    var panes: [Pane]
    /// Which pane the rails, the notes and the highlighter keys describe. One pane today;
    /// the split adds the second.
    var activePane: Pane.ID

    struct Pane: Identifiable, Equatable {
        let id: UUID
        var tabs: [Tab] = []
        /// Nil only while the pane holds nothing.
        var active: Tab.ID?
    }

    /// One open document. It owns its `Annotator`, so switching away and back keeps the
    /// marks, the outline, the bookmarks and the find session that were already there.
    ///
    /// It holds no `PDFDocument`. `PDFPreview` owns that through its `NSView`, which goes
    /// away with the tab's pane when the tab is not on screen, so a tab in the background
    /// costs what is listed here and nothing more.
    struct Tab: Identifiable {
        let id: UUID
        let key: String
        /// The reviewer's selection, drawn in italics and replaced as the selection moves.
        /// A kept tab is one somebody asked for.
        var isPreview: Bool
        let annotator: Annotator
    }

    static func one(pane: UUID) -> Deck {
        Deck(panes: [Pane(id: pane)], activePane: pane)
    }

    var active: Pane? { panes.first { $0.id == activePane } }

    var activeTab: Tab? {
        guard let pane = active, let id = pane.active else { return nil }
        return pane.tabs.first { $0.id == id }
    }

    /// Open a document, or look at the one already open for it.
    ///
    /// `kept: false` is the reviewer's selection moving. It replaces the preview tab rather
    /// than adding one, which is what keeps a walk through two hundred files from opening
    /// two hundred tabs.
    func opening(_ key: String, kept: Bool, makeAnnotator: () -> Annotator) -> Deck {
        var deck = self
        guard let index = deck.panes.firstIndex(where: { $0.id == activePane }) else { return deck }

        if let existing = deck.panes[index].tabs.firstIndex(where: { $0.key == key }) {
            if kept { deck.panes[index].tabs[existing].isPreview = false }
            deck.panes[index].active = deck.panes[index].tabs[existing].id
            return deck
        }

        let tab = Tab(id: UUID(), key: key, isPreview: !kept, annotator: makeAnnotator())
        if kept {
            deck.panes[index].tabs.append(tab)
        } else if let preview = deck.panes[index].tabs.firstIndex(where: \.isPreview) {
            deck.panes[index].tabs[preview] = tab
        } else {
            // Ahead of the kept tabs: it is the one that moves, so it stays where the eye
            // already is rather than walking along the bar as the selection changes.
            deck.panes[index].tabs.insert(tab, at: 0)
        }
        deck.panes[index].active = tab.id
        return deck
    }

    func activating(_ tab: Tab.ID) -> Deck {
        var deck = self
        guard let index = deck.panes.firstIndex(where: { $0.id == activePane }),
              deck.panes[index].tabs.contains(where: { $0.id == tab }) else { return deck }
        deck.panes[index].active = tab
        return deck
    }

    /// Close a tab, and say what is showing afterwards: the one to its right, or the one to
    /// its left when it was last. A pane that runs out of tabs stays, empty.
    func closing(_ tab: Tab.ID) -> Deck {
        var deck = self
        guard let index = deck.panes.firstIndex(where: { $0.id == activePane }),
              let at = deck.panes[index].tabs.firstIndex(where: { $0.id == tab })
        else { return deck }

        let wasActive = deck.panes[index].active == tab
        deck.panes[index].tabs.remove(at: at)
        guard wasActive else { return deck }
        let next = min(at, deck.panes[index].tabs.count - 1)
        deck.panes[index].active = next >= 0 ? deck.panes[index].tabs[next].id : nil
        return deck
    }

    /// Turn the preview tab into one that stays.
    func promotingPreview() -> Deck {
        var deck = self
        for pane in deck.panes.indices {
            for tab in deck.panes[pane].tabs.indices where deck.panes[pane].tabs[tab].isPreview {
                deck.panes[pane].tabs[tab].isPreview = false
            }
        }
        return deck
    }

    func stepping(by delta: Int) -> Deck {
        guard let pane = active, !pane.tabs.isEmpty,
              let at = pane.tabs.firstIndex(where: { $0.id == pane.active })
        else { return self }
        let count = pane.tabs.count
        let next = ((at + delta) % count + count) % count
        return activating(pane.tabs[next].id)
    }
}

extension Deck.Tab: Equatable {
    /// By what it is, not by the annotator it carries: `Annotator` is a reference and a
    /// class with no `Equatable` of its own, and two tabs are the same tab when they have
    /// the same identity, key and standing.
    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.key == b.key && a.isPreview == b.isPreview
    }
}
```

- [ ] **Step 4: Run the tests**

```
swift test --filter ReadingDeckTests
```

Expected: PASS, 15 tests.

- [ ] **Step 5: Confirm three of them have teeth**

Run each of these three mutations, one at a time, confirm the named test goes red, then put the code back:

1. In `opening`, change `} else if let preview = ...` to `} else if false, let preview = ...` so a preview tab is always inserted rather than replaced. `testThePreviewTabIsReplacedRatherThanAddedTo` and `testThereIsNeverMoreThanOnePreviewTab` must fail.
2. In `closing`, change `let next = min(at, ...)` to `let next = 0`. `testClosingTheActiveTabActivatesTheOneAfterIt` must fail.
3. In `opening`, delete the `if let existing = ...` block so a reopen always makes a new tab. `testOpeningSomethingAlreadyOpenActivatesItRatherThanDuplicating` and `testReopeningKeepsTheAnnotatorItAlreadyHad` must fail.

Report the failure output for each.

- [ ] **Step 6: Commit**

```bash
git add Sources/PaperShelf/ReadingDeck.swift Tests/PaperShelfAppTests/ReadingDeckTests.swift
git commit -S -m "feat: a window can hold more than one open document

The rules for what is open and which of it is showing, as a value type with
pure functions, which is the shape Regions and SplitLayout already use here.
Nothing draws it yet.

A tab owns its annotator, so switching away and back keeps the marks, the
outline and the find session that were already there. It holds no document:
PDFPreview owns that through its view, which goes away with the pane, so a
tab in the background costs its marks and nothing else.

The preview tab is what keeps the reviewer usable. Walking a selection down
a folder of two hundred files replaces one tab rather than opening two
hundred."
```

---

### Task 2: Holding the deck, and remembering it

**Files:**
- Modify: `Sources/PaperShelf/ReadingDeck.swift`
- Modify: `Sources/PaperShelf/Prefs.swift`
- Test: `Tests/PaperShelfAppTests/ReadingDeckTests.swift`

**Interfaces:**
- Consumes: `Deck` from Task 1, exactly as declared there.
- Produces:
  ```swift
  @MainActor @Observable final class ReadingDeck {
      var deck: Deck
      init(deck: Deck)
  }
  struct StoredDeck: Codable, Equatable {
      var panes: [[String]]     // ordered keys per pane
      var active: [Int]         // index of the active tab per pane, -1 for none
      var activePane: Int
      init(_ deck: Deck)
  }
  extension Deck {
      static func restoring(_ stored: StoredDeck, reachable: (String) -> Bool,
                            makeAnnotator: (String) -> Annotator) -> Deck
  }
  ```
  `Prefs` gains `var openTabs: String` backed by `Store.text("openTabs", "")`, holding `StoredDeck` as JSON.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PaperShelfAppTests/ReadingDeckTests.swift`, inside the class:

```swift
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
```

- [ ] **Step 2: Run them and watch them fail**

```
swift test --filter ReadingDeckTests
```

Expected: `error: cannot find 'StoredDeck' in scope`.

- [ ] **Step 3: Write it**

Append to `Sources/PaperShelf/ReadingDeck.swift`:

```swift
/// What is written down between launches: the order, and which one was showing.
///
/// Keys rather than tabs. An `Annotator` is built fresh on the way back in, and the page you
/// were on comes from `ReadingPositions` as it always has.
struct StoredDeck: Codable, Equatable {
    var panes: [[String]]
    /// The index of the active tab in each pane, or -1 where the pane holds nothing.
    var active: [Int]
    var activePane: Int

    init(_ deck: Deck) {
        // The preview tab is the reviewer's selection rather than something anybody opened,
        // so it is not carried across a launch.
        let kept = deck.panes.map { $0.tabs.filter { !$0.isPreview } }
        panes = kept.map { $0.map(\.key) }
        active = zip(deck.panes, kept).map { pane, tabs in
            tabs.firstIndex { $0.id == pane.active } ?? (tabs.isEmpty ? -1 : 0)
        }
        activePane = deck.panes.firstIndex { $0.id == deck.activePane } ?? 0
    }
}

extension Deck {
    /// Rebuild what was open, dropping whatever is no longer there.
    ///
    /// A file renamed, moved or trashed since the last launch goes without comment, the same
    /// bargain an unreachable source already makes. If the one that was showing is the one
    /// that went, the pane shows something else rather than opening onto nothing.
    static func restoring(_ stored: StoredDeck, reachable: (String) -> Bool,
                          makeAnnotator: (String) -> Annotator) -> Deck {
        var panes: [Pane] = []
        for (index, keys) in stored.panes.enumerated() {
            let wanted = stored.active.indices.contains(index) ? stored.active[index] : -1
            let wantedKey = keys.indices.contains(wanted) ? keys[wanted] : nil
            let tabs = keys.filter(reachable).map {
                Tab(id: UUID(), key: $0, isPreview: false, annotator: makeAnnotator($0))
            }
            let active = tabs.first { $0.key == wantedKey }?.id ?? tabs.first?.id
            panes.append(Pane(id: UUID(), tabs: tabs, active: active))
        }
        if panes.isEmpty { panes = [Pane(id: UUID())] }
        let at = panes.indices.contains(stored.activePane) ? stored.activePane : 0
        return Deck(panes: panes, activePane: panes[at].id)
    }
}

/// The deck a window holds, so SwiftUI can watch it.
///
/// A box around the value rather than a model with methods: every rule lives on `Deck`,
/// where a test can reach it, and this exists only to be observed.
@MainActor
@Observable
final class ReadingDeck {
    var deck: Deck
    init(deck: Deck) { self.deck = deck }
}
```

In `Sources/PaperShelf/Prefs.swift`, beside the other window settings, add:

```swift
    /// The documents that were open, as `StoredDeck` JSON. One string rather than a key per
    /// tab, because the order is part of the answer.
    var openTabs: String = Store.text("openTabs", "") {
        didSet { Store.put("openTabs", openTabs) }
    }
```

- [ ] **Step 4: Run the tests**

```
swift test --filter ReadingDeckTests
```

Expected: PASS, 22 tests.

- [ ] **Step 5: Confirm two of them have teeth**

1. In `StoredDeck.init`, drop the `filter { !$0.isPreview }` so the preview tab is stored. `testThePreviewTabIsNotStored` must fail.
2. In `restoring`, change `?? tabs.first?.id` to `?? nil`. `testTheActiveTabGoingLeavesSomethingElseShowing` must fail.

Report the failure output for each, then put the code back.

- [ ] **Step 6: Commit**

```bash
git add Sources/PaperShelf/ReadingDeck.swift Sources/PaperShelf/Prefs.swift Tests/PaperShelfAppTests/ReadingDeckTests.swift
git commit -S -m "feat: the documents you had open come back

Keys and their order, written as one JSON string rather than a key per tab,
because the order is part of the answer. Annotators are built fresh on the
way back in and the page you were on still comes from ReadingPositions.

A file renamed, moved or trashed since the last launch is dropped without
comment, the bargain an unreachable source already makes. If the one that
was showing is the one that went, the pane shows something else rather than
opening onto nothing."
```

---

### Task 3: The tab bar

**Files:**
- Create: `Sources/PaperShelf/TabBar.swift`
- Test: `Tests/PaperShelfAppTests/TabBarLayoutTests.swift`

**Interfaces:**
- Consumes: `Deck.Tab` from Task 1; `Space`, `Face`, `Metric` (`Sources/PaperShelf/Tokens.swift`).
- Produces:
  ```swift
  struct TabBar: View {
      init(tabs: [Deck.Tab], active: Deck.Tab.ID?, title: @escaping (Deck.Tab) -> String,
           activate: @escaping (Deck.Tab.ID) -> Void, close: @escaping (Deck.Tab.ID) -> Void)
      static let height: CGFloat = 28
  }
  ```

**The hazard this task exists to avoid.** The filter bar in this same app was an `HStack` of `.fixedSize()` children, and when it ran out of room it did not clip: it drew its children past its own frame and over the divider and the inspector beside it, while reporting a perfectly ordinary size. A tab bar is the same shape, and a pane can be 328 points wide. Tabs must truncate and the bar must scroll. Read `Tests/PaperShelfAppTests/FilterBarLayoutTests.swift` for how that was measured, and `Sources/PaperShelf/Catalogue.swift`'s `filterBar` for what the fix looked like.

- [ ] **Step 1: Write the failing test**

Create `Tests/PaperShelfAppTests/TabBarLayoutTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import PaperShelf

/// The filter bar in this app was an HStack of fixed-size children, and when it ran out of
/// room it drew them past its own frame and over the pane beside it while reporting an
/// ordinary size. A tab bar is the same shape and a pane can be 328 points wide, so this
/// measures what is painted rather than what is reported.
@MainActor
final class TabBarLayoutTests: XCTestCase {

    private func rightmostEdge(_ view: NSView, root: NSView) -> CGFloat {
        var edge = view.convert(view.bounds, to: root).maxX
        for sub in view.subviews { edge = max(edge, rightmostEdge(sub, root: root)) }
        return edge
    }

    private func overflow(of view: some View, width: CGFloat) -> CGFloat {
        let hosting = NSHostingView(rootView: view.frame(width: width, height: TabBar.height))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width,
                                                 height: TabBar.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        return rightmostEdge(hosting, root: hosting) - width
    }

    private func bar(_ count: Int) -> some View {
        let tabs = (0..<count).map {
            Deck.Tab(id: UUID(), key: "/library/paper-\($0).pdf",
                     isPreview: false, annotator: Annotator())
        }
        return TabBar(tabs: tabs, active: tabs.first?.id,
                      title: { _ in "2017-gomes-verifying-strong-eventual-consistency.pdf" },
                      activate: { _ in }, close: { _ in })
    }

    /// A 13 inch shelf's document region split in two is about 328 points, the window's own
    /// floor leaves 360, and a maximised reader gets the rest.
    private let widths: [CGFloat] = [260, 328, 360, 647, 1176]

    func testTheBarStaysInsideItsOwnWidthHoweverManyTabsThereAre() {
        for width in widths {
            for count in [1, 2, 5, 12] {
                XCTAssertLessThanOrEqual(overflow(of: bar(count), width: width), 0.5,
                                         "\(count) tabs at width \(width)")
            }
        }
    }

    func testOneTabWithAVeryLongNameStaysInside() {
        XCTAssertLessThanOrEqual(overflow(of: bar(1), width: 260), 0.5)
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

```
swift test --filter TabBarLayoutTests
```

Expected: `error: cannot find 'TabBar' in scope`.

- [ ] **Step 3: Write the bar**

Create `Sources/PaperShelf/TabBar.swift`. A horizontal `ScrollView` so the strip can run past the pane, and a `lineLimit(1)` with a maximum width per tab so one long filename cannot push the rest off. Do not use `.fixedSize()` on a tab.

```swift
import SwiftUI

/// One pane's open documents.
///
/// A scroll view rather than a row that grows: a pane can be 328 points wide and a person can
/// have a dozen papers open, and an HStack asked for less room than its children need does not
/// clip, it draws them over whatever is beside it. That is not a hypothetical here; the filter
/// bar in this same window did exactly that.
struct TabBar: View {
    let tabs: [Deck.Tab]
    let active: Deck.Tab.ID?
    /// What to call a tab. The deck holds keys, which are paths; the name a person reads is
    /// the library's business, not this view's.
    let title: (Deck.Tab) -> String
    let activate: (Deck.Tab.ID) -> Void
    let close: (Deck.Tab.ID) -> Void

    static let height: CGFloat = 28
    /// Wide enough for a recognisable stem, narrow enough that four tabs fit a narrow pane.
    private static let maximumTabWidth: CGFloat = 180

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(tabs) { tab in
                    tabView(tab)
                    Divider().frame(height: TabBar.height - 8)
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: TabBar.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .clipped()
    }

    private func tabView(_ tab: Deck.Tab) -> some View {
        let isActive = tab.id == active
        return HStack(spacing: Space.tight) {
            Text(title(tab))
                .font(Face.caption)
                .italic(tab.isPreview)
                .lineLimit(1)
                .truncationMode(.middle)
            Button { close(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(title(tab))")
        }
        .padding(.horizontal, Space.snug)
        .frame(maxWidth: TabBar.maximumTabWidth)
        .frame(height: TabBar.height)
        .background(isActive ? Color.primary.opacity(0.10) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { activate(tab.id) }
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
```

- [ ] **Step 4: Run the test**

```
swift test --filter TabBarLayoutTests
```

Expected: PASS, 2 tests.

- [ ] **Step 5: Confirm it has teeth**

Replace `.frame(maxWidth: TabBar.maximumTabWidth)` with `.fixedSize()` and remove the `ScrollView`, leaving a bare `HStack`. The test must fail with a real overflow number at the narrow widths. Put it back and confirm it passes. Report both outputs.

- [ ] **Step 6: Commit**

```bash
git add Sources/PaperShelf/TabBar.swift Tests/PaperShelfAppTests/TabBarLayoutTests.swift
git commit -S -m "feat: a strip of the documents a pane has open

Nothing shows it yet. A scroll view rather than a row that grows, and a
maximum width per tab: a pane can be 328 points wide and a person can have a
dozen papers open, and an HStack asked for less room than its children need
draws them over whatever is beside it rather than clipping. The filter bar in
this same window did exactly that, which is what the check here measures."
```

---

### Task 4: The window uses the deck

**Files:**
- Modify: `Sources/PaperShelf/Catalogue.swift`

**Interfaces:**
- Consumes: `Deck`, `ReadingDeck`, `StoredDeck` from Tasks 1 and 2; `TabBar` from Task 3.
- Produces: nothing new; this is wiring.

**Read first.** `ResultsPane` is about 3900 lines and its body reads dozens of preferences, so it re-evaluates whenever any of them changes. Two lookups in it were a measured performance problem earlier today and were fixed by going through `Runner.item(_:)`, which answers from `indexByKey` in constant time; do not reintroduce a walk over `runner.results`.

- [ ] **Step 1: Replace the reader key with a deck**

`@State private var reader: String?` at `Sources/PaperShelf/Catalogue.swift:164` becomes:

```swift
    /// What this window has open. Replaces a single `reader` key: the window can hold more
    /// than one document now, and which one is showing is the deck's business.
    @State private var deck = ReadingDeck(deck: Deck.one(pane: UUID()))
```

Then work outward from the compiler errors. The four places that matter:

- `readerItem` (`:178`) becomes `deck.deck.activeTab.flatMap { runner.item($0.key) }`.
- `showsPage` (`:173`) gains the deck: it is true when the deck has an active tab, or `reading`, or the view mode is list or catalogue.
- `openReader(_:)` (`:191`) opens a **kept** tab instead of navigating to a `Place`, and no longer touches history.
- `closeReader` closes the active tab.

- [ ] **Step 2: Take the reader out of place history**

`Place` (`Sources/PaperShelf/Catalogue.swift:105`) carries a `reader` field. Remove it, and remove it from every `Place(...)` construction and from `navigate(to:)`'s handling. History goes back to being about the shelf: view mode, shelf, folder, query. This is what removes the current oddity where going back closes the document you were reading.

- [ ] **Step 3: Make the reviewer's selection a preview tab**

Wherever the selection changes and the document region follows it, open the selected key with `kept: false`. `Enter` (the `.confirm` command path) and the new `openInNewTab` command call `promotingPreview()`.

- [ ] **Step 4: Draw the bar**

In `documentRegion(paneWidth:)` (`:2406`), put a `TabBar` above the existing content when the deck's active pane holds anything, passing `title:` as the item's `sourceName` looked up through `runner.item(_:)`, falling back to the key's last path component when the library does not know it.

- [ ] **Step 5: Restore and remember**

On appear, `deck.deck = Deck.restoring(...)` decoded from `prefs.openTabs`, with `reachable:` asking `FileManager.default.fileExists(atPath:)`. On any change to the deck, write `prefs.openTabs` back. Use a `.task(id:)` or `onChange` keyed on `StoredDeck(deck.deck)` so a mere activation does not rewrite the file on every keystroke.

- [ ] **Step 6: Build and run everything**

```
swift build 2>&1 | grep -E "warning:|error:" ; swift test
```

Expected: no warnings, no errors, the suite green.

- [ ] **Step 7: Commit**

```bash
git add Sources/PaperShelf/Catalogue.swift
git commit -S -m "feat: the window shows the documents it has open

The reader was one key, so the window could hold one paper. It holds a deck
now, and the strip above the page says what is in it.

Opening a document is no longer a place you navigate to. History is about the
shelf again, which is what it was always describing: the view, the list, the
folder, the search. Going back stopped closing the paper you were reading.

The reviewer's selection is a preview tab, replaced as the selection moves,
so walking a folder of two hundred files still opens nothing."
```

---

### Task 5: Commands and the palette

**Files:**
- Modify: `Sources/PaperShelf/Commands.swift`
- Modify: `Sources/PaperShelf/Catalogue.swift`

**Interfaces:**
- Consumes: everything from Tasks 1 to 4.
- Produces: four new `Command` cases.

- [ ] **Step 1: Add the commands**

In `Sources/PaperShelf/Commands.swift`, add to the `Reading` group with scope `.reader`:

| Case | Title | Default |
| --- | --- | --- |
| `openInNewTab` | Keep this document open | `⌘T` |
| `closeTab` | Close this tab | `⌘W` |
| `nextTab` | Next tab | `⌘⇧]` |
| `previousTab` | Previous tab | `⌘⇧[` |

`⌘[` and `⌘]` are already back and forward, which is why the tab keys take the macOS convention. `⌘W` closes the active tab and falls through to closing the window when the deck is empty, which is what Safari and Xcode do.

Every case must be added to `group`, `scope`, the title switch, and `defaultShortcut`, or the file will not compile: those switches are exhaustive on purpose.

- [ ] **Step 2: Prove the keys do not clash**

`Tests/PaperShelfAppTests/CommandsTests.swift` already walks every command and asserts `Keymap.conflict(for:assigning:)` finds nothing. Run it:

```
swift test --filter CommandsTests
```

Expected: PASS. If a new default clashes, the test names both commands; pick a different key rather than weakening the test.

- [ ] **Step 3: Wire them up**

Add the four cases to `ResultsPane.performable` (`Sources/PaperShelf/Catalogue.swift:1356`) so they appear in the palette and the shortcuts sheet, and to `perform(_:)` (`:1380`).

- [ ] **Step 4: Build and run everything**

```
swift build 2>&1 | grep -E "warning:|error:" ; swift test
```

Expected: no warnings, no errors, the suite green.

- [ ] **Step 5: Commit**

```bash
git add Sources/PaperShelf/Commands.swift Sources/PaperShelf/Catalogue.swift
git commit -S -m "feat: keys and palette entries for the tabs

Four commands, so they are in the palette, in the generated shortcuts sheet,
and rebindable in Settings like everything else. The tab keys take the macOS
convention rather than the obvious one, since command bracket is already back
and forward here."
```

---

## Self-Review

**Spec coverage.** This plan covers the spec's model, `TabBar`, the preview tab, place history, the commands and persistence. It does not cover: the split, both orientations, cross-pane drag, `openBeside`, `moveTabToOtherPane`, or the palette's `⌥⏎`, all of which are plan 3. It also does not settle the two design questions the spec now flags as owed, `.document`'s meaning and where the fold decision lives; both bite only when there are two panes.

**Placeholders.** Tasks 1, 2, 3 and 5 carry complete code. Task 4 is wiring inside a 3900-line view and is written as precise instructions with exact line numbers and the four call sites that matter, because pasting a rewrite of that file would be less accurate than naming what changes.

**Type consistency.** `Deck`, `Deck.Pane`, `Deck.Tab`, `StoredDeck` and `ReadingDeck` are declared once in Task 1 and Task 2's Interfaces blocks and used unchanged after. `opening(_:kept:makeAnnotator:)` takes the same three labels everywhere. `TabBar.height` is referenced by the test before the view declares it, which is why it is `static`.

**Known risk.** Task 4 is the one that can go wrong quietly: `showsPage` and `Place` are read from many places in that file, and the compiler will find the call sites but not the behaviour. Its review should check that reading mode, the bibliography and duplicates views, and the back and forward keys all still do what they did.
