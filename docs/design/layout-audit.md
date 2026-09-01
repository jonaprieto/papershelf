# layout-audit

## Summary

The file the task named, App.swift, no longer exists: while I was reading it, commit 4d6aaea landed in this repo and split it verbatim into 9 files (ContentView.swift, Catalogue.swift, Review.swift, Runner.swift, Reading.swift, Bibliography.swift, Shell.swift, plus the untouched Converting.swift/SettingsView.swift/Palette.swift/Annotations.swift/FileMenu.swift/Tooltips.swift/AI.swift/Watcher.swift). The commit message confirms "declarations moved unchanged," which I verified line-by-line against my earlier reads of the monolith, and `swift build` succeeds on the current tree. All findings below are cited against the current, real files. The two structural bugs the task asked about (fixed-shape backgrounds, panes overflowing at narrow width) have each already been hit and fixed once in this repo's history (see commits e346c19, e29cad8); my audit found one place each pattern has partially regressed or was never fully applied.

## Design

Repair list, ranked by how visibly it breaks. All paths are under Sources/PaperShelf/. No rewrite of the view hierarchy is proposed: every fix is a local arithmetic or modifier correction to code the previous two fix commits (e346c19, e29cad8) already established as the right shape.

1. [HIGH — silent, no crash, but defeats the intent of a fix already shipped once] `Catalogue.swift:669` — `split`'s `maximum = max(360, geometry.size.width - 360)` reserves room for the inspector but not for the notes rail, so once `notesShown` is true the effective floor for the browser pane drops from the intended ~360pt to as low as 118pt (360 minus the rail's 240 minus ~2pt of dividers), and the same stale `maximum` is reused by the drag handler at `Catalogue.swift:708`, letting the user drag the inspector to a width that was only ever safe without notes open.
   Fix: thread the reserved width through instead of hardcoding it twice.
   ```swift
   private var split: some View {
       GeometryReader { geometry in
           let reserved: CGFloat = notesShown ? 360 + 240 + 2 : 360   // inspector floor + notes rail + dividers
           let maximum = max(360, geometry.size.width - reserved)
           let width = min(max(inspectorWidth, 360), maximum)
           ...
   ```
   Pass the same `reserved`/`maximum` into `divider(width:maximum:)` so the drag gesture at line 708 clamps against the notes-aware ceiling, not the stale one.

2. [HIGH — same root cause, not yet fixed even once for this rail] `Review.swift:79-92` — `ContentsRail` (`.frame(width: 196)` at line 84) is still nested inside `ReviewInspector`, itself pinned to a width computed by `split` (item 1) that has no idea `contentsShown` exists. Opening the table of contents while the inspector is already at its 360pt floor squeezes `PDFPreview` to ~163pt with no lower bound.
   Fix: apply the same treatment `e29cad8` already gave the notes rail — make `ContentsRail` a sibling in `split`'s top-level `HStack` (`Catalogue.swift:671-690`) instead of a child of `ReviewInspector`, and fold its 196pt into the same `reserved` calculation from item 1 when `contentsShown` is true. This also removes the need for `ReviewInspector` to know about `contentsShown` at layout time at all — it only needs it for the toggle button in `panelHeader`.

3. [MEDIUM — cosmetic clamp, but the comment claims otherwise] `ContentView.swift:977` — `sizeWindowOnFirstLaunch` requests `NSSize(width: 980, height: 680)`, but `980 < 1000`, the window's own declared `minWidth` at `ContentView.swift:246` (notes closed by default). AppKit clamps the content size up to the window's minimum, so the app always opens at 1000pt wide regardless of this line, silently, with no visible symptom beyond "the requested width is a dead constant."
   Fix: `window.setContentSize(NSSize(width: max(1000, 980), height: 680))` or simply raise the literal to `1000`.

4. [MEDIUM — degrades card sizing, no overflow] `Catalogue.swift:628-631` — `catalogueColumns(for:)` computes `(width - spacing + spacing) / (ideal + spacing)`, which is algebraically just `width / (ideal + spacing)`; it does not subtract the 36pt of outer padding (`.padding(18)` on both sides, applied at `Catalogue.swift:652`) that the grid it sizes will actually consume. At column-count boundaries this renders cards up to ~18pt narrower than the `ideal` of 168 the function targets.
   Fix:
   ```swift
   private func catalogueColumns(for width: CGFloat) -> Int {
       let spacing: CGFloat = 18
       let ideal: CGFloat = 168
       let usable = width - 2 * spacing   // the grid's own outer padding
       return max(1, Int((usable + spacing) / (ideal + spacing)))
   }
   ```

5. [LOW-MEDIUM, dark-mode consistency] `Catalogue.swift:1145` and `Review.swift:309` — `item.message` text uses plain `Color.red`/`Color.orange` at `.font(.caption)`, exactly the combination `StatusPill`'s own comment (`Catalogue.swift:1322-1324`) calls out as illegible ("System greens and oranges sit around 2:1 on a light background, which is unreadable at caption size"). Every sibling color in the same views goes through the hand-tuned `Color(light: srgb(176,29,29), dark: srgb(248,130,130))` / `Color(light: srgb(163,88,8), dark: srgb(251,191,60))` pair.
   Fix: replace both with the same pair already defined and used one screen away — e.g. `.foregroundStyle(item.status == .failed ? Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)) : Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60)))`.

6. [LOW, Dynamic Type] `Review.swift:429-431` (`KeyLabel`'s key badge, `.frame(width: 14, height: 14)` around a single glyph) and `ContentView.swift:475-477` / `ContentView.swift:677-679` (`.frame(width: 26/30, alignment: .trailing)` around a plain, unstyled — hence scalable — numeric `Text`) will clip at larger Dynamic Type / macOS "Larger Text" accessibility sizes, since none of the three boxes grow with text size and none use `minimumScaleFactor`.
   Fix: either fix the font too (`.font(.caption2)` on the two numeric Texts, matching the rest of the row, so they no longer scale independently of their box) or drop the fixed width in favor of a `.frame(minWidth: 14/26/30, alignment: .trailing)` so the box can grow instead of clip.

Not proposed: any change to the view-hierarchy shape itself. The two structural mechanisms already in place — a `GeometryReader`-driven three/four-pane `HStack` with one persisted `@AppStorage` width, and a window `.frame(minWidth:...)` that is supposed to sum the panes' floors — are the right shape; items 1-2 are arithmetic bugs in that existing shape (missing terms), not evidence the shape itself needs replacing.

## Verified facts

- App.swift (the file the task specified) does not exist in the current working tree; it was deleted by commit 4d6aaea, which split its 4847 lines verbatim into 9 new files.
  EVIDENCE: git show 4d6aaea --stat: 'Sources/PaperShelf/App.swift | 4847 ----...' plus 8 new files totaling 4877 insertions; commit body: "The declarations moved unchanged; only a top-level 'private' ... was dropped. Same build, same 144 tests."

- The refactor happened live, mid-session, while I was reading the original App.swift.
  EVIDENCE: git log -1 shows commit 4d6aaea authored 2026-08-27 01:17:52; my first Read of App.swift succeeded (4877 lines) and a later Read of the same path returned 'File does not exist'.

- The window's declared floor is minWidth 1000 (1180 when the notes rail is open), minHeight 560.
  EVIDENCE: Sources/PaperShelf/ContentView.swift:246 `.frame(minWidth: chrome.notesShown ? 1180 : 1000, minHeight: 560)`

- The detail (results) column separately declares its own floor of 700, independent of whether notes are open.
  EVIDENCE: Sources/PaperShelf/ContentView.swift:239 `.frame(minWidth: 700)` on ResultsPane

- The sidebar column's width range is 290–400 (ideal 310).
  EVIDENCE: Sources/PaperShelf/ContentView.swift:218 `.navigationSplitViewColumnWidth(min: 290, ideal: 310, max: 400)`

- The three-pane split computes the inspector's max allowed width as `geometry.size.width - 360`, which reserves 360pt for the browser pane but never subtracts the notes rail's fixed 240pt (+ divider) when notes are shown, so that reserved 360pt floor for the browser silently shrinks to about 118pt whenever notes are open.
  EVIDENCE: Sources/PaperShelf/Catalogue.swift:669-670 `let maximum = max(360, geometry.size.width - 360)` / `let width = min(max(inspectorWidth, 360), maximum)`, combined with Catalogue.swift:680-689 adding a sibling `.frame(width: 240)` NotesRail inside the same HStack whose total width is `geometry.size.width`; the same unadjusted `maximum` is reused by the drag handler at Catalogue.swift:708.

- This exact class of bug (a fixed-width rail nested where the surrounding math doesn't know about it) has already caused a visible overflow once, and was fixed by making the notes rail a sibling instead of nesting it in the inspector.
  EVIDENCE: commit e29cad8 message: "The notes rail was nested inside the inspector, which is width-constrained, so the page and the rail together overflowed that frame and drew over the browser... is now a sibling in the split where each pane owns its width."

- The contents rail (table of contents) was never given the same treatment: it is still nested inside the width-constrained ReviewInspector, as a sibling of the flexible PDFPreview, and its 196pt is not reserved anywhere in the outer sizing math.
  EVIDENCE: Sources/PaperShelf/Review.swift:79-92, ContentsRail given `.frame(width: 196)` at line 84 inside ReviewInspector's own top HStack, alongside `PDFPreview(...).frame(maxWidth: .infinity, maxHeight: .infinity)` at lines 87-88; no reference to contentsShown anywhere in ContentView.swift's window-size or Catalogue.swift's split-size logic.

- The Capsule/RoundedRectangle-background-needs-fixedSize bug (the one that has hit this project twice per the task description) is documented in code as having recurred once already on StatusPill, and is currently guarded there, but the same pattern (background shape + Text/Label with no other height constraint) appears at several other sites without a fixedSize comment, some of which are protected only incidentally by an outer fixed frame.
  EVIDENCE: Sources/PaperShelf/Catalogue.swift:1304-1307 background(...,in: Capsule()) immediately followed by a comment ("A Capsule fills whatever height it is handed...") and `.fixedSize()`; commit e29cad8: "The status pill had lost the fixedSize that stops a Capsule filling whatever height it is given, so it went back to rendering as a tall coloured slab. That is the second time."

- catalogueColumns computes the number of grid columns from the full, unpadded width, even though the grid it sizes is later given 18pt of padding on each side; the `- spacing + spacing` term cancels to a no-op and does not account for that padding.
  EVIDENCE: Sources/PaperShelf/Catalogue.swift:628-631 `return max(1, Int((width - spacing + spacing) / (ideal + spacing)))` where `width` is `geometry.size.width` from the enclosing GeometryReader (line 620-624), and Catalogue.swift:652 applies `.padding(18)` to the LazyVGrid inside that same measured region.

- sizeWindowOnFirstLaunch sets the initial window content width to 980, which is below the app's own declared minWidth of 1000, so AppKit will clamp it up to 1000 and the requested 980 can never actually apply.
  EVIDENCE: Sources/PaperShelf/ContentView.swift:977 `window.setContentSize(NSSize(width: 980, height: 680))` vs. ContentView.swift:246 minWidth of 1000 (notesShown defaults to false, so 1000 is the floor in effect at first launch).

- Two call sites use plain system Color.red/.orange for a caption-sized error/warning message, in the same file that documents system red/orange as illegible at caption size and hand-tunes every other status color for exactly that reason.
  EVIDENCE: Sources/PaperShelf/Catalogue.swift:1145 and Sources/PaperShelf/Review.swift:309, both `.foregroundStyle(item.status == .failed ? .red : .orange)` on a `.font(.caption)` Text; contrast with Sources/PaperShelf/Catalogue.swift:1322-1324 comment on StatusPill.color: "System greens and oranges sit around 2:1 on a light background, which is unreadable at caption size. These are darkened for light and lifted for dark."

- Every other semantic status/warning/error color in the app (roughly 60 call sites across Catalogue.swift, ContentView.swift, Review.swift, Reading.swift, Bibliography.swift, SettingsView.swift) uses a hand-tuned Color(light:dark:) pair via the shared `srgb()` helper, so hardcoded-color dark-mode risk is otherwise low; the .red/.orange sites above are the outliers.
  EVIDENCE: grep across the 9 relevant files for `srgb(` returns ~50 matching foregroundStyle/tint/fill call sites, all paired as `Color(light: srgb(...), dark: srgb(...))`; defined once at Sources/PaperShelf/Shell.swift:202-213.

- No occurrence of minimumScaleFactor exists anywhere in the audited files; the app relies entirely on lineLimit/truncationMode plus SwiftUI's default text-style scaling for Dynamic Type, which is a legitimate default, but several fixed-size boxes wrap plain (scalable) Text rather than a fixed-size icon, and can clip at larger Dynamic Type sizes.
  EVIDENCE: grep -n minimumScaleFactor across all 15 PaperShelf source files returns zero hits; e.g. Sources/PaperShelf/Review.swift:429-431 KeyLabel wraps a single-character `Text(key).font(.caption2.weight(.bold).monospaced())` in `.frame(width: 14, height: 14)`; Sources/PaperShelf/ContentView.swift:475-477 and 677-679 wrap a plain, unstyled `Text` (inherits Form's scalable body font) in `.frame(width: 26/30, alignment: .trailing)`.


## Risks

- App.swift, the file named in the task, was deleted by a live refactor commit partway through this audit; every line reference below is against the current 9-file layout (ContentView.swift, Catalogue.swift, Review.swift, Runner.swift, Reading.swift, Bibliography.swift, Shell.swift, plus the untouched files), not against App.swift. If the orchestrator's downstream tooling still expects App.swift:line citations, those will not resolve.

- The pixel-precise floors I derived for item 1 (118pt browser floor when notes are open) are computed from the stated constants (360, 240, ~2pt of Divider width) and verified against how NavigationSplitView is asked to size its columns, but I did not run the app in a live window to visually confirm the exact pixel count — Divider's rendered width in this context is assumed to be ~1pt based on AppKit convention, not measured.

- Runner.swift (805 lines) and Watcher.swift/AI.swift were not read line-by-line; I verified by exhaustive grep across all layout/color/font/lineLimit tokens that none of the three contain any View body or layout-relevant code, consistent with the split commit's own description ('split by what it draws'), but a very unusual hand-rolled layout construct not matching any of those grep patterns could in principle be sitting there unnoticed.

- I did not check PaperShelfCore (the pure-logic target) at all, since the task scoped this to the SwiftUI app; if any of the string-formatting/measurement logic that feeds these views (e.g. sample name generation, byte-count formatting) has its own width assumptions, that is out of scope here.

- Item 5's grep for hardcoded colors was pattern-based (Color.red/.orange, Color(red:, NSColor(, Color.white/.black); a color hazard expressed some other way (e.g. an asset-catalog color, or a literal hex string parsed at runtime) would not have been caught, though no such pattern exists anywhere in this project per its README's no-third-party-dependency, no-asset-catalog-dependent style.


## Unverified (do not build on this without checking)

- Whether the ~118pt (or ~163pt for the contents-rail case) squeezed states are visually broken or merely uncomfortable was not confirmed by actually launching the app at the window's declared minimum size with notes/contents open — this is an arithmetic derivation from the source, not an observed screenshot.

- Whether SwiftUI's NavigationSplitView on macOS 14 actually honors navigationSplitViewColumnWidth(min:290) as a hard floor when the window itself is dragged to its absolute minWidth, versus letting the sidebar shrink further than its stated minimum under pressure — this affects how much width the detail column (and therefore the split/browser/inspector/notes math) actually receives at the window's floor, and I could not verify AppKit/SwiftUI's exact column-negotiation algorithm from source alone.

- Whether the two .red/.orange call sites (item 5) were an intentional simplification (e.g. because item.message failures are rare enough that the contrast issue was judged not worth the extra characters) rather than an oversight — I have only the code and the StatusPill comment as evidence, not the author's stated intent for these two specific sites.

- Whether CoverCard's fixed `.frame(height: 168)` (Catalogue.swift:1241) against a flexible-width grid column is considered an acceptable proportions trade-off by the project's own design taste, versus something they'd also want addressed — I judged it low severity and did not include it as a numbered repair item, but did not confirm that judgment against any design intent documented in the repo.

- The exact rendered width AppKit gives a vertical `Divider()` with no explicit `.frame(width:)` in this SwiftUI/AppKit bridging context (assumed ~1pt for the arithmetic in item 1's fix and in the facts above).
