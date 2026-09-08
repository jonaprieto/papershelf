# DocumentPane Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the page-and-its-rails that `ReviewInspector` and `ReaderWindow` each draw separately into one `DocumentPane` view, so tabs and split have a single thing to instantiate per pane.

**Architecture:** `DocumentPane` owns the contents rail, `PDFPreview`, the page bar and the clipping. Everything that needs the palette, the meaning scopes or the ChatGPT handoff stays in `ReviewInspector` and is passed in through a `@ViewBuilder overlays:` closure. `DocumentPane` knows nothing about `Runner`, `Item`, or the library.

**Tech Stack:** Swift 6 toolchain in Swift 5 language mode, SwiftUI, PDFKit, XCTest. No third-party dependencies: the README states there are none and adding one would make that false.

## Global Constraints

- No emoji and no em-dashes anywhere: source, comments, Markdown written into the repo, commit messages. Use a comma, a colon, a semicolon, or two sentences.
- `swift build` must be clean with zero warnings.
- Commit messages are a Conventional Commits prefix and then a plain descriptive clause written for a person. No AI-attribution trailers of any kind.
- Every commit is signed and every commit builds and passes on its own.
- Comments explain consequences, not mechanics. Match the voice of the surrounding files.
- Do not enable `mcpFileOperations`. Do not write to the `com.jonaprieto.pdfhammer` preferences domain. Do not write into `~/Library/Application Support/PaperShelf/`.
- Do not launch the GUI app.
- A check that cannot fail is worse than no check. Every new assertion is confirmed by reverting the thing it covers and watching it go red.

## File Structure

- **Create** `Sources/PaperShelf/DocumentPane.swift`: the page, its contents rail, its page bar, and the clipping that holds a hosted `PDFView` inside its frame. One responsibility: draw one open document.
- **Create** `Tests/PaperShelfAppTests/DocumentPaneLayoutTests.swift`: offscreen hosting, subview-tree walk, checks nothing paints past the pane.
- **Modify** `Sources/PaperShelf/Review.swift`: `pageRegion` becomes a `DocumentPane` with the mark bars passed in as overlays.
- **Modify** `Sources/PaperShelf/ReaderWindow.swift`: the page half of its `HStack` becomes a `DocumentPane`.
- **Modify** `Tools/ui-smoke-test.applescript`: the stale "All Documents" precondition.

---

### Task 1: DocumentPane, used by ReviewInspector

**Files:**
- Create: `Sources/PaperShelf/DocumentPane.swift`
- Modify: `Sources/PaperShelf/Review.swift:286-324` (`pageRegion`)
- Test: `Tests/PaperShelfAppTests/DocumentPaneLayoutTests.swift`

**Interfaces:**
- Consumes: `Annotator`, `ContentsRail`, `PDFPreview`, `PageBar`, `PDFReadingAppearanceModifier`, `PageFit`, `PDFReadingAppearance`, `SplitLayout`, `Space`, all already internal to the `PaperShelf` target.
- Produces:
  ```swift
  struct DocumentPane<Overlay: View>: View {
      init(url: URL,
           passwords: [String],
           annotator: Annotator,
           fit: Binding<PageFit>,
           appearance: PDFReadingAppearance,
           presentation: Bool = false,
           showsContentsRail: Bool = true,
           showsPageBar: Bool = true,
           onDocumentSwipe: ((Int) -> Void)? = nil,
           onPageStep: ((Int) -> Void)? = nil,
           onMarkClick: ((CGPoint) -> Void)? = nil,
           onPointer: ((CGPoint?) -> Void)? = nil,
           openFind: @escaping () -> Void,
           togglePresentation: (() -> Void)? = nil,
           @ViewBuilder overlays: @escaping () -> Overlay)
  }
  ```
  `onPointer` receives the point while the pointer is over the page and `nil` when it leaves, which is what `ReviewInspector.pointer(at:)` and `hideMarkBar(after:)` need between them.

- [ ] **Step 1: Read the code being moved**

Read `Sources/PaperShelf/Review.swift` lines 286 to 324 (`pageRegion`) and `Sources/PaperShelf/ReaderWindow.swift` lines 39 to 70. These are the two bodies being unified. Note that `ReviewInspector` overlays `PageBar` on the page while `ReaderWindow` puts page controls in a row underneath; `showsPageBar` exists so `ReaderWindow` keeps its row in Task 2 and nothing visible moves.

- [ ] **Step 2: Write the failing layout test**

Create `Tests/PaperShelfAppTests/DocumentPaneLayoutTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import PaperShelfCore
@testable import PaperShelf

/// A hosted PDFView does not honour the frame SwiftUI gives it while that frame is
/// shrinking: squeezed narrow it goes on drawing at the width it had a moment ago,
/// straight over whatever is beside it. Clipping is what actually holds it, and this is
/// how the clipping is checked, since `fittingSize` reports an ordinary size either way.
@MainActor
final class DocumentPaneLayoutTests: XCTestCase {

    /// The rightmost edge anything under `view` actually paints at, in `view`'s own
    /// coordinates.
    private func rightmostEdge(_ view: NSView, root: NSView) -> CGFloat {
        var edge = view.convert(view.bounds, to: root).maxX
        for sub in view.subviews { edge = max(edge, rightmostEdge(sub, root: root)) }
        return edge
    }

    private func overflow(of view: some View, width: CGFloat) -> CGFloat {
        let hosting = NSHostingView(rootView: view.frame(width: width, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        return rightmostEdge(hosting, root: hosting) - width
    }

    private func pane(contentsRail: Bool) -> some View {
        DocumentPane(url: URL(fileURLWithPath: "/nonexistent/paper.pdf"),
                     passwords: [],
                     annotator: Annotator(),
                     fit: .constant(.width),
                     appearance: .normal,
                     showsContentsRail: contentsRail,
                     openFind: {},
                     overlays: { EmptyView() })
    }

    /// The widths a pane can really be: a 13 inch shelf's document region split in two,
    /// the preview floor itself, and the whole region on a laptop.
    private let widths: [CGFloat] = [SplitLayout.previewFloorBesideContents, 328, 647, 1176]

    func testThePaneStaysInsideItsOwnWidth() {
        for width in widths {
            for rail in [false, true] {
                XCTAssertLessThanOrEqual(overflow(of: pane(contentsRail: rail), width: width), 0.5,
                                         "width \(width), contents rail \(rail)")
            }
        }
    }

    /// The rail gives way before the page does, which is what `contentsRailWidth` is for.
    /// Asking for it at a width that leaves the page under its floor must draw no rail
    /// rather than a rail that pushes the page off the edge.
    func testTheRailIsNotDrawnWhereThePageWouldHaveNoRoom() {
        let narrow = SplitLayout.previewFloorBesideContents - 40
        XCTAssertEqual(SplitLayout.contentsRailWidth(inspectorWidth: narrow), 0)
        XCTAssertLessThanOrEqual(overflow(of: pane(contentsRail: true), width: narrow), 0.5)
    }
}
```

- [ ] **Step 3: Run it and watch it fail**

```
swift test --filter DocumentPaneLayoutTests
```

Expected: `error: cannot find 'DocumentPane' in scope`.

- [ ] **Step 4: Create DocumentPane**

Create `Sources/PaperShelf/DocumentPane.swift`. Move the body of `ReviewInspector.pageRegion` into it verbatim, substituting the parameters for the properties it used to read off its host. The result:

```swift
import SwiftUI
import AppKit
import PDFKit
import PaperShelfCore

/// One open document: the page, the outline beside it, and the bar that says where you
/// are in it.
///
/// The reviewer and the reader were each drawing this, separately, with the same three
/// pieces and the same two bugs waiting in them. One view rather than two is what lets a
/// window hold more than one document at a time: a pane is an instance of this.
///
/// It knows about a URL and an `Annotator` and nothing else. Everything that needs the
/// palette, a document's meaning scopes or the ChatGPT handoff -- the selection bar, the
/// mark bar, the locked overlay -- is drawn by whoever hosts this and handed in through
/// `overlays`. That is the boundary that keeps this file small: those three bars pull in
/// half of `Review.swift` behind them.
struct DocumentPane<Overlay: View>: View {
    let url: URL
    let passwords: [String]
    var annotator: Annotator
    @Binding var fit: PageFit
    let appearance: PDFReadingAppearance
    var presentation = false
    /// Whether the outline is drawn as a column here. The host decides: it knows whether
    /// the reader asked for it, whether the document has pages to list, and whether the
    /// pane is narrow enough that it should be a popover instead.
    var showsContentsRail = true
    /// The reader window puts its page controls in a row under the page, with the
    /// filename beside them, so it asks for no bar of its own here.
    var showsPageBar = true
    var onDocumentSwipe: ((Int) -> Void)?
    var onPageStep: ((Int) -> Void)?
    var onMarkClick: ((CGPoint) -> Void)?
    /// The point while the pointer is over the page, and nil when it leaves. One closure
    /// rather than two, because the host's two handlers are a pair: the bar is held up for
    /// a moment after the pointer leaves so it can be reached.
    var onPointer: ((CGPoint?) -> Void)?
    let openFind: () -> Void
    var togglePresentation: (() -> Void)?
    @ViewBuilder let overlays: () -> Overlay
    private let prefs = Prefs.shared

    var body: some View {
        // The contents rail's width is read off the room the page actually got, so on a
        // pane too narrow for both it is the chapter list that narrows and not the page
        // that is squeezed to nothing, or worse, pushed off the edge.
        GeometryReader { page in
            HStack(spacing: 0) {
                if showsContentsRail {
                    ContentsRail(annotator: annotator, findActive: annotator.showsFind)
                        .frame(width: SplitLayout.contentsRailWidth(
                            inspectorWidth: page.size.width))
                        .region(.contents)
                    Divider()
                }
                PDFPreview(url: url, passwords: passwords,
                           annotator: annotator, fit: fit,
                           appearance: appearance,
                           presentation: presentation,
                           onDocumentSwipe: onDocumentSwipe,
                           onPageStep: onPageStep,
                           onMarkClick: onMarkClick)
                .modifier(PDFReadingAppearanceModifier(appearance: appearance))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The page is an AppKit view hosted in SwiftUI, and a hosted view does
                // not honour the frame it was given while it is being resized: squeezed
                // narrow, it kept drawing at its old width, straight over the panel
                // beside it. Clipping is what actually holds it to its pane.
                .clipped()
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let point): onPointer?(point)
                    case .ended: onPointer?(nil)
                    }
                }
                .overlay(alignment: .topLeading) { overlays() }
                .overlay(alignment: .bottom) {
                    if showsPageBar && !presentation {
                        PageBar(annotator: annotator, fit: $fit, openFind: openFind,
                                presentation: presentation,
                                togglePresentation: togglePresentation)
                            .padding(.bottom, Space.roomy)
                    }
                }
                .contextMenu {
                    Button(annotator.bookmarkOnCurrentPage == nil
                           ? "Add Bookmark" : "Remove Bookmark") {
                        _ = annotator.toggleBookmark()
                    }
                    Button("Show Bookmarks") {
                        prefs.contentsShown = true
                        prefs.contentsRailMode = .bookmarks
                    }
                }
            }
            .clipped()
        }
    }
}
```

- [ ] **Step 5: Run the layout test**

```
swift test --filter DocumentPaneLayoutTests
```

Expected: PASS, 2 tests.

- [ ] **Step 6: Confirm the test has teeth**

Remove the inner `.clipped()` on the `PDFPreview` and run the test again. It must fail at one of the narrow widths. Put the `.clipped()` back and confirm it passes. If it does not fail, the test is measuring nothing and must be fixed before going on.

- [ ] **Step 7: Point ReviewInspector at it**

In `Sources/PaperShelf/Review.swift`, replace the whole of `pageRegion` (currently lines 286 to 324) with:

```swift
    /// The page, with the outline beside it where the pane is wide enough to hold both.
    private var pageRegion: some View {
        DocumentPane(
            url: item.currentURL,
            passwords: passwords,
            annotator: annotator,
            fit: $prefs.pageFit,
            appearance: prefs.readingAppearance,
            presentation: presentation,
            showsContentsRail: prefs.contentsShown && hasContents && !contentsIsPopover,
            onDocumentSwipe: stepDocument,
            onMarkClick: selectMark(at:),
            onPointer: { point in
                if let point { pointer(at: point) } else { hideMarkBar(after: .milliseconds(350)) }
            },
            openFind: openFind,
            togglePresentation: togglePresentation
        ) {
            ZStack(alignment: .topLeading) {
                lockedOverlay
                floatingSelectionBar
                floatingMarkBar
            }
        }
    }
```

`lockedOverlay` was `.overlay(alignment: .topTrailing)`; inside the `ZStack` give it `.frame(maxWidth: .infinity, alignment: .topTrailing)` so it stays in the same corner.

- [ ] **Step 8: Build and run everything**

```
swift build 2>&1 | grep -E "warning:|error:" ; swift test
```

Expected: no warnings, no errors, and the full suite green at its previous count plus 2.

- [ ] **Step 9: Commit**

```bash
git add Sources/PaperShelf/DocumentPane.swift Sources/PaperShelf/Review.swift Tests/PaperShelfAppTests/DocumentPaneLayoutTests.swift
git commit -S -m "refactor: one view draws an open document

The reviewer and the reader each drew the same three pieces -- the outline,
the page, the bar under it -- with their own copies of the clipping that
holds a hosted PDFView inside its frame. One view rather than two is what
lets a window hold more than one document: a pane is an instance of it.

The bars that need the palette, a document's meaning scopes or the ChatGPT
handoff stay with the reviewer and are handed in. They pull half of
Review.swift behind them, and that is the boundary that keeps the new file
small."
```

---

### Task 2: ReaderWindow adopts DocumentPane

**Files:**
- Modify: `Sources/PaperShelf/ReaderWindow.swift:39-70`

**Interfaces:**
- Consumes: `DocumentPane` from Task 1, with exactly the initialiser listed there.
- Produces: nothing new.

- [ ] **Step 1: Replace the page half of the HStack**

In `Sources/PaperShelf/ReaderWindow.swift`, the outer `VStack`'s first child is an `HStack` holding the contents rail, a divider, and `PDFPreview` with a `.inspector` attached. Replace the contents rail, the divider and the `PDFPreview` with one `DocumentPane`, keeping the `.inspector` modifier on it:

```swift
            DocumentPane(
                url: url,
                passwords: passwords,
                annotator: annotator,
                fit: $fit,
                appearance: prefs.readingAppearance,
                presentation: presentation,
                showsContentsRail: !presentation && prefs.contentsShown && annotator.hasPages,
                // This window keeps its page controls in the row underneath, with the
                // filename beside them, so it asks for no bar over the page.
                showsPageBar: false,
                onPageStep: presentation && prefs.leftRightTurnsPages
                    ? { annotator.go(toPage: annotator.page + $0) } : nil,
                onMarkClick: selectMark(at:),
                openFind: openFind
            ) {
                selectionBar
            }
            .inspector(isPresented: $showsNotes) {
                NotesRail(annotator: annotator, palette: palette,
                          addingNote: $addingNote, noteText: $noteText,
                          lastColour: nextColour, title: title, source: url.path,
                          close: { showsNotes = false }, isWritingNote: $writingNote,
                          documentID: documentID,
                          effectiveProjectScopes: documentProjectScopes)
                .inspectorColumnWidth(min: SplitLayout.panelFloor, ideal: 320)
            }
```

The `.contextMenu` with the bookmark buttons is now inside `DocumentPane`, so delete the one that was on `PDFPreview` here rather than leaving two.

`selectionBar` was `.overlay(alignment: .top)`. Inside `overlays` it is top-leading; give it `.frame(maxWidth: .infinity, alignment: .top)` so it stays centred as it was.

- [ ] **Step 2: Build and run everything**

```
swift build 2>&1 | grep -E "warning:|error:" ; swift test
```

Expected: no warnings, no errors, suite green.

- [ ] **Step 3: Check what actually changed on screen**

The reader window's contents rail was a fixed `SplitLayout.contentsReserved - SplitLayout.dividerBeforeInspector` wide; `DocumentPane` derives it from `SplitLayout.contentsRailWidth(inspectorWidth:)` instead. On a window with room those are the same 196 points. On a narrow one the rail now narrows rather than squeezing the page. Confirm by adding this to `Tests/PaperShelfCoreTests/LayoutTests.swift` in `FoldingTests`:

```swift
    /// The reader's rail used to be a fixed width whatever the window was. It is the
    /// same 196 points wherever there is room, and narrows rather than squeezing the
    /// page where there is not.
    func testTheReadersRailIsUnchangedWhereverThereIsRoom() {
        let ideal = SplitLayout.contentsReserved - SplitLayout.dividerBeforeInspector
        XCTAssertEqual(SplitLayout.contentsRailWidth(inspectorWidth: 900), ideal)
        XCTAssertEqual(SplitLayout.contentsRailWidth(inspectorWidth: 520), ideal)
        XCTAssertLessThan(SplitLayout.contentsRailWidth(inspectorWidth: 420), ideal)
    }
```

Run `swift test --filter FoldingTests`. Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/PaperShelf/ReaderWindow.swift Tests/PaperShelfCoreTests/LayoutTests.swift
git commit -S -m "refactor: the reader window draws its page the same way

It kept its own copy of the outline, the page and the clipping around them,
with the rail at a fixed width whatever the window was. It uses the shared
pane now, so a narrow reader narrows the chapter list rather than squeezing
the page, which is what the reviewer already did."
```

---

### Task 3: Make the UI smoke test a real gate

**Files:**
- Modify: `Tools/ui-smoke-test.applescript`

**Interfaces:** none.

- [ ] **Step 1: Reproduce the failure**

```
Tools/ui-smoke-test.sh dist/PaperShelf.app
```

Expected today: `execution error: Timed out waiting for a PaperShelf window named All Documents (-2700)`. The app restores into whatever it was last showing, and the window is titled with that document, so waiting for a window named "All Documents" waits forever. This is a stale precondition in the script, not a regression in the app.

- [ ] **Step 2: Read the script and find the wait**

Read `Tools/ui-smoke-test.applescript` and find where it waits for the window named "All Documents".

- [ ] **Step 3: Wait for the app's window rather than for one title**

Replace that wait with one that waits for any window of the process to exist, then, if the window is showing a document rather than the shelf, put it back to the shelf first. The window's own title is `placeTitle`, which is the document's name while a reader is open and the shelf's name otherwise, so a title match cannot be the precondition. Waiting for `(count of windows) > 0` and then sending the shortcut for `viewCatalogue` is what makes the rest of the script's assumptions true.

- [ ] **Step 4: Run it**

```
./build.sh && Tools/ui-smoke-test.sh dist/PaperShelf.app
```

Expected: the script runs to completion and reports no failures. Note this launches the GUI: ask the user before running it and do not run it unattended.

- [ ] **Step 5: Commit**

```bash
git add Tools/ui-smoke-test.applescript
git commit -S -m "fix: the smoke test waits for the window, not for one title

The window is titled with whatever it is showing, so an app that restored
into a document never produced a window named All Documents and the script
waited until it timed out. It waits for the window and puts the shelf back
itself, which is what the checks after it were already assuming."
```

---

## Self-Review

**Spec coverage.** This plan covers the spec's "The views / `DocumentPane`" section and the smoke-test gate under "Testing". The model, `TabBar`, `ReadingSplit`, the preview tab, place history, layout floors, focus, commands, the palette and persistence are all plan 2 and plan 3, which are written after this one lands so they describe interfaces that exist rather than interfaces that were guessed.

**Placeholders.** None. Every code step carries the code. The two "move this verbatim" steps name exact line ranges and show the replacement in full.

**Type consistency.** `DocumentPane`'s initialiser is written out once in Task 1's Interfaces block and used unchanged in Task 1 Step 7 and Task 2 Step 1. `onPointer` takes `CGPoint?` in all three places. `fit` is a `Binding<PageFit>` in all three.

**Known behaviour changes, both deliberate:**
1. The reader window's contents rail narrows on a narrow window instead of staying 196 points and squeezing the page. Pinned by the test in Task 2 Step 3.
2. Nothing else. `showsPageBar: false` exists so the reader keeps its row of page controls exactly where it is.
