# Reading tabs and a split reader

Date: 2026-09-07

## The problem

Reading one paper while looking at another is not possible without leaving the app. The
library window is a single `Window("PaperShelf", id: "main")` holding one `reader: String?`,
so it shows one document at a time. Standalone reader windows exist
(`AppDelegate.openReader(for:)`, keyed by resolved path, several at once) but only Finder can
open one; nothing inside the app does.

The workflow to support: read paper A while a reference B stays visible beside it, switch
between several open papers without losing where you were in each, and have the notes,
contents and find always describe whichever page you last touched.

## What is being built

Several documents open at once, drawn as tabs, in one or two panes side by side or stacked.
One pane is active; everything that is one-per-window today describes the active pane's
document.

Both the library window and Finder-opened reader windows get it, through a shared view.

## Decisions taken

| Question | Answer |
| --- | --- |
| Tabs, split, or both | Both |
| Which window | Both, through one shared `DocumentPane` |
| What the rails, find, notes and inspector describe | The focused pane |
| Split directions | Side by side and stacked, toggleable |
| Tab bar | One per pane |
| Relationship to place history | Tabs replace opening-as-a-place |
| The reviewer's selection | A preview tab |
| Second document's source | The library |

## Architecture

### The model

A plain `@Observable` class with pure decision functions beside it, in the shape this
codebase already uses for `Regions`, `SplitLayout` and `VisibleFilter`: the state lives
somewhere a test can reach without a window, which is the only reason those three have real
tests.

`Deck` is a value type carrying the whole arrangement. `ReadingDeck` is the observable box a
view holds; it owns exactly one `Deck` and every mutation is one of the pure functions below
applied to it. That split is the point: the decisions are testable without a window, and the
class exists only so SwiftUI can observe them.

```swift
struct Deck: Equatable {
    var panes: [Pane]                     // one, or two when split
    var activePane: Pane.ID
    var orientation: Orientation          // .sideBySide | .stacked
}

struct Pane: Identifiable, Equatable {
    let id: UUID
    var tabs: [Tab]                       // ordered, what the tab bar draws
    var active: Tab.ID?                   // nil only while the pane is empty
}

struct Tab: Identifiable, Equatable {
    let id: UUID
    let key: String                       // Item.key: the library's own identity
    var isPreview: Bool
    let annotator: Annotator              // one per open document
}

@MainActor @Observable
final class ReadingDeck {
    var deck: Deck
}
```

`Tab` holds a reference (`Annotator`) and is still a value type, which is what lets the
functions below be pure. `Equatable` on `Tab` compares `id`, not the annotator.

`Tab` owns its `Annotator`, so a document keeps its marks, contents, bookmarks and find
session while you switch away and back, and a tab dragged to the other pane carries that
state with it.

A `Tab` holds no `PDFDocument`. `PDFPreview` owns the document through its `NSView`, which is
destroyed when the tab is not on screen, so a background tab costs marks, contents and
bookmarks and nothing else. Switching back re-parses off the main thread, which
`PDFPreview.updateNSView` already does, and the scroll position is restored from
`PaperShelfCore/ReadingPositions.swift`.

Everything one-per-window today reads `deck.activeTab.annotator` instead of a passed-in
`annotator`: the contents rail, find, the notes rail, the status bar, the highlighter keys.
That single indirection is the whole of "the panel follows what I clicked". There is no
syncing to write.

### Pure functions

Beside the class, in the style of `Regions.next(from:by:available:)`, so each can be tested
with no window:

```swift
extension Deck {
    /// What is active after a close, and whether the pane goes away with it.
    func closing(_ tab: Tab.ID, in pane: Pane.ID) -> Deck

    /// A drag across the divider, including the case where it empties the source pane and
    /// so collapses the split.
    func moving(_ tab: Tab.ID, to pane: Pane.ID, at index: Int) -> Deck

    /// Open a document in a pane: activate the tab that pane already has for the key, or
    /// replace the preview tab, or add a new one. `kept: false` makes it the preview tab.
    func opening(_ key: String, in pane: Pane.ID, kept: Bool, annotator: () -> Annotator) -> Deck

    /// Turn the preview tab into one that stays.
    func promotingPreview() -> Deck

    /// Rebuild from what was stored, dropping tabs whose files are gone.
    static func restoring(_ stored: StoredDeck, reachable: (String) -> Bool,
                          annotator: (String) -> Annotator) -> Deck
}
```

### The views

**`DocumentPane`** (new file, `Sources/PaperShelf/DocumentPane.swift`). Holds what
`ReviewInspector.pageRegion` (`Sources/PaperShelf/Review.swift:286`) and `ReaderWindow`'s body
(`Sources/PaperShelf/ReaderWindow.swift:39`) are already both doing: the contents rail,
`PDFPreview`, `PageBar`, the floating selection and mark bars, the locked overlay, and the
bookmark context menu. It takes a URL, an `Annotator`, a fit binding and callbacks. It knows
nothing about `Runner`, the library, or the reviewer.

After the extraction:

- `ReviewInspector` is `DocumentPane` plus its panel column.
- `ReaderWindow` is `DocumentPane` plus its notes rail.

This extraction is the bulk of the work and the main risk. `pageRegion` is tangled with about
ten pieces of `ReviewInspector`'s own state (hover, mark bar visibility, selection rect) that
have to move with it. It lands as its own commit with no behaviour change at all.

**`TabBar`** (new file). One per pane, above the page. Draws the pane's tabs, marks the active
one, italicises the preview tab, offers a close button, and accepts a drop from the other
pane. Reorder within a pane and drag across the divider are the same model operation.

**`ReadingSplit`** (new file). The pane container: one pane, or two with a draggable divider,
in either orientation. Reuses the existing divider drag handling in
`ResultsPane.dividerBody`, which already clamps to a minimum and a maximum.

### The reviewer and the preview tab

In list and catalogue mode the page follows the selected row. If every selection opened a tab,
reviewing two hundred files would open two hundred tabs.

So the reviewer's document is a **preview tab**: one, always leftmost in the first pane, drawn
in italics, replaced as the selection moves, never accumulating. `⏎`, `⌘T`, or dragging it
promotes it to a kept tab. Only one preview tab exists in the whole deck.

### Place history

Opening a document no longer pushes a `Place` carrying a reader key. `Place` goes back to
being about the shelf: view mode, shelf, folder, query. This removes the current oddity where
`⌘[` closes the document you were reading.

`ResultsPane.reader: String?` is replaced by the deck's active tab.
`ResultsPane.openReader(_:)` opens or activates a tab. `closeReader` closes it.
`showsPage` becomes true when the deck has any tab, or `reading`, or the view mode is list or
catalogue.

## Layout

Measured budget. On a 13.3 inch laptop (1440 x 900, 875 usable) the detail column is 1176
points; the reviewer's document region is 647 of that after `inspectorShareCeiling`, and
reading mode gets all 1176.

```
reading mode, 1176:  notes 321 + contents 197 -> 658 for pages -> 328 each
                     notes 321 only            -> 855           -> 427 each
reviewer,      647:  notes 321 beside the page -> 326           -> does not fit
reviewer,      647:  notes overlaying the page -> 647           -> 323 each
```

Two pages need `2 * previewFloorBesideContents + 1` = 601 points. Side by side therefore fits
reading mode comfortably, and fits the reviewer only once the notes panel overlays the page
rather than sitting beside it.

That is machinery `SplitLayout` already has. The change is a generalisation, not a new system:
every existing floor gains "when the split is on, the page floor is doubled plus a divider".
`inspectorOverlaysBelow` goes from 561 to 862 while split is on, so the panel overlays sooner.
Nothing else moves.

Below 601 the split folds to the active pane. The tabs stay; only the second pane goes. The
fold order stays outside-in as today: contents rail to a popover, then the panel to an
overlay, then the split.

**The fold decision is currently in the wrong place, and plan 3 has to move it.** Found by
the final review of plan 1. `DocumentPane` takes `showsContentsRail` as a plain Bool that the
host computes, and `ReviewInspector` computes it from `paneWidth`, which is the whole document
region (`Sources/PaperShelf/Catalogue.swift:2203`), not the pane's own width. That is safe
today only because `contentsFoldsBelow` is 1100, so far above the ramp that the difference
never shows.

With two panes it shows immediately. A 855 point region split in two gives roughly 427 a
pane: `contentsIsPopover` is answered at 855 and says no popover, while each pane's own
`contentsRailWidth` returns 127. The pane already computes the one number that decides this,
inside its own `GeometryReader`, and its interface has no way to report it or act on it.

So `showsContentsRail` becomes a request rather than an answer: the host says whether the
reader asked for an outline, the pane decides from its own width whether it can draw one, and
reports back so the host can offer the popover instead.

Stacked has its own floor. Reading mode on a 13 inch leaves 769 points of height, less two tab
bars and a divider, so 356 a pane; a letter page at that width is over 400 tall, so stacked
shows less than a page each. It is right for peeking at a figure and wrong for reading, so
side by side is the default and stacked is the toggle. Floor of 240 a pane: a judgement, to
be pinned by the offscreen-hosting harness.

New in `Sources/PaperShelfCore/Layout.swift`:

```swift
public static let dividerBetweenPanes: CGFloat = 1
public static var splitFloorWidth: CGFloat       // 2 * previewFloorBesideContents + dividerBetweenPanes
public static let paneFloorHeight: CGFloat = 240
public static var splitFloorHeight: CGFloat      // 2 * paneFloorHeight + dividerBetweenPanes
/// Whether a region this size can hold two pages in this orientation.
public static func splitFits(width: CGFloat, height: CGFloat, orientation: Orientation) -> Bool
/// The existing rule, widened by the second page when the split is on.
public static func inspectorOverlays(paneWidth: CGFloat, split: Bool) -> Bool
```

The existing `inspectorOverlays(paneWidth:)` keeps working and forwards with `split: false`,
so no call site outside the split has to change.

## Focus

**This section rests on a wrong reading of `Region` and has to be settled before plan 3
starts.** The final review of plan 1 found it, by tracing every consumer.

`.document` does not mean the page today. It is claimed by `collection`, the shelf list, at
`Sources/PaperShelf/Catalogue.swift:2200` and `:2220`, and read as such by `selectionTint`.
So "`.document` keeps meaning the document, and `activePane` decides which pane that is"
describes a `Region` the code does not have.

`Regions.shared` is also process-wide with no window scoping, which plan 1 had to correct
once already: putting `.region(.contents)` inside the shared `DocumentPane` made a click in a
Finder-opened reader grey out an open library window's selection and take its sidebar's arrow
keys. The region claim now lives at `ReviewInspector`'s call site for that reason.

Three ways out, to decide before plan 3:

1. **A region per pane.** `.document` splits into a claim carrying a pane identity. Largest
   change, and it forces `Regions.available` to be maintained by whoever draws a pane, which
   only `Catalogue` does today.
2. **Scope `Regions` to a window.** One `Regions` per window rather than a singleton, which
   also fixes the cross-window bug at its root rather than by keeping the claim out of the
   shared view. Then `activePane` is a deck concern and `Region` stays five places.
3. **Leave `Region` alone and let the deck own pane focus outright.** `.document` keeps
   meaning the shelf list; the active pane is `deck.activePane` and nothing else, set by
   clicking a page, making a highlight, or switching a tab. Cheapest, and it means
   ⌃3 does not reach a page.

Option 2 looks right and is not obviously large, but it is a decision, not a detail.

Whichever is chosen, `DocumentPane` needs a way to say which pane was clicked. It has no such
callback today: it puts a region claim on the rail and nothing on the page, and none of its
callbacks carries pane identity.

## Commands

New cases on `Command` (`Sources/PaperShelf/Commands.swift`), which is all it takes to get a
palette entry, a line in the generated shortcuts sheet, and a rebindable row in
Settings › Keyboard.

| Command | Default | Scope | Meaning |
| --- | --- | --- | --- |
| `openInNewTab` | `⌘T` | reader | Keep the preview tab, or open the selected row as a kept tab |
| `closeTab` | `⌘W` | reader | Close the active tab; close the window when there is none |
| `nextTab` | `⌘⇧]` | reader | |
| `previousTab` | `⌘⇧[` | reader | |
| `toggleSplit` | `⌘\` | reader | |
| `swapOrientation` | `⌘⇧\` | reader | Side by side or stacked |
| `focusOtherPane` | `⌘⌥→` | reader | |
| `openBeside` | none | reader | Open the selected document in the other pane |
| `moveTabToOtherPane` | none | reader | |

`⌘[` and `⌘]` are already back and forward, which is why the tab keys take the macOS
convention `⌘⇧[` / `⌘⇧]`. `⌘\` is the Xcode and VS Code convention for split.

`⌘W` is a deliberate change: it closes the window today and will close the active tab first.
That is what Safari and Xcode do.

`CommandsTests.testNoCommandIsClaimedTwice` and the conflict check must stay green; every new
default is checked against `Keymap.conflict(for:assigning:)`.

### The palette is the main entry point

The command palette already lists every document and `⏎` opens one. `⌥⏎` opens it **beside**,
splitting if it has to. One modifier on an action that already exists, which is exactly the
"read this while looking at that" gesture, and it needs no new key.

Opening a document a pane already holds activates that tab rather than duplicating it. The
same document may be open in both panes.

## Persistence

The deck is stored as JSON under one defaults key, in the shape `Prefs` already uses for
string-valued settings (`Store.text`). Stored: for each pane, the ordered tab keys and which
is active; plus which pane is active, the orientation, and whether the split is on.

On launch, tabs whose files are gone are dropped without comment, the way an unreachable
source already is. The preview tab is never stored.

Where you were on each page keeps coming from `ReadingPositions`, unchanged.

## Testing

Three shapes, all already trusted in this repo.

**Pure model, XCTest, no window.** `ReadingDeck`'s four functions: what is active after a
close, what happens when a drag empties a pane, promoting the preview tab, opening a key a
pane already holds, restoring a deck whose files have moved.

**Pure layout, `FoldingTests`.** `splitFloorWidth`, `splitFloorHeight`, the widened overlay
threshold, and that `inspectorOverlays(paneWidth:split: false)` is identical to the old
one-argument form at every width.

**Offscreen hosting, the harness that caught the filter bar.** The tab bar is an HStack of
tabs in a pane that can be 328 points wide, which is the filter bar's bug waiting to happen
again: eight tabs must truncate and scroll rather than paint over the divider. Measured with
the subview-tree walk, not `fittingSize`.

Every check is confirmed by reverting the thing it covers and watching it go red, per
`AGENTS.md`. A check that cannot fail is worse than none.

`Tools/ui-smoke-test.sh` must stay green. It currently times out waiting for a window named
"All Documents" when the app restores into a document view, which is a stale precondition in
the script rather than a regression; fix that as part of plan 1 so the smoke test is a real
gate for plans 2 and 3.

## How it ships

Three plans, each green and useful on its own.

1. **`DocumentPane` extraction.** No behaviour change. Both hosts use it. Acceptance: the
   whole suite and the UI smoke test, unchanged.
2. **Tabs.** One pane, tab bar, preview tab, tabs replace opening-as-a-place, the commands,
   the palette, persistence. After this, several papers stay open.
3. **Split.** Second pane, both orientations, the layout floors, focus across the divider,
   open-beside, drag between panes. After this, two papers are visible at once.

## Out of scope

- Loose files not in the library as the second document. The library is the source.
- More than two panes.
- Tabs in the settings, about, or duplicate-compare windows.
- Close-others and close-to-the-right.
- Syncing the deck between the library window and Finder-opened reader windows; each window
  has its own deck.
