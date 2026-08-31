# PaperShelf as the default PDF viewer

Date: 2026-08-31

## What this is for

Today PaperShelf is a library that happens to contain a reader. To become the app that
opens when you double-click a PDF anywhere on the machine, it has to be a reader that
happens to have a library: open in well under a second, show the page and nothing else,
and let you mark the page with the five highlighters before it has decided what the file
is or where it belongs.

Nothing here changes what the library does. It changes what has to have happened before
you can read.

## Decisions

Every fork below was decided in favour of the reading path. Where a choice cost the
library something, the library pays.

### 1. Three scenes, two lifecycles

- `Window(id: "main")`: the library, as today.
- `WindowGroup(for: URL.self)`: the reader. One window per file.
- About and Settings: unchanged.

An `NSApplicationDelegateAdaptor` implements `application(_:open:)`, which is the call
Finder actually makes, and forwards each URL to `openWindow(value:)`. When the app is
launched by a file rather than by its icon, the delegate closes the library window before
it draws.

macOS 14 has no `defaultLaunchBehavior(.suppressed)`; that is macOS 15. Closing the window
is the portable move and the deployment target stays at 14. The cost is one frame in which
an empty library window exists, which is why the next decision matters more than this one.

### 2. The library window does nothing until it is visible

`ContentView.onAppear` currently restores sources, starts the file watcher, shows the
cached shelf and kicks off a preview. All of it moves behind visibility: the work starts
when the library window is on screen, not when the process starts.

This is the decision that makes the rest possible. A reader window that has to wait for a
source scan is not a viewer, whatever the launch path looks like.

### 3. PDF handler, ranked Alternate

`CFBundleDocumentTypes` declaring `com.adobe.pdf`, `CFBundleTypeRole` Viewer,
`LSHandlerRank` Alternate.

Alternate rather than Owner on purpose: Owner claims the type against Preview on every
install, and this is an app that gets rebuilt and reinstalled several times a day. You set
it once in Get Info and macOS remembers.

### 4. The reader window is a page

Chrome is the window title (document name) and the page count. No sidebar, no inspector,
no toolbar. ⌘B and ⌘⇧B do nothing here, because there is nothing to toggle.

Marking works two ways, both on by default:

- Keys 1 to 5 for the five highlighters, N for a note on the selection.
- A colour bar that appears beside the selection, switchable off in Settings.

The keys are the fast path and the bar is the discoverable one; neither is worth having
alone. ⌘⇧N slides the inspector over the page for the notes list, and puts it away again.

⌘K opens the palette here too, which is what makes `/` (find in this document) and `:`
(turn to page) reachable without a menu.

Implementation note: the reading view has to be usable without `Runner`, `Covers` or the
shelf. That means extracting a `ReaderPane` that takes a URL and an `Annotator` and
nothing else, and having both windows use it. If that extraction turns out to drag the
whole of `Catalogue` behind it, that is the moment to stop and re-plan rather than to
thread a fake runner through.

### 5. Opening a file records it, and moves nothing

Opening any PDF writes a document row: content hash, path, page count. No rename, no move,
no source folder, no naming rules. Highlights continue to live in the PDF itself.

What the row buys: reading position across launches, notes, full-text search, and a
document that can later be filed without losing what you did to it.

A fifth smart list, `Opened`, lists documents whose locations sit under no source, most
recently opened first. Forgetting one uses the machinery that already exists for
documents whose files are gone.

It does not overlap the lists already there. `Unfiled` means carrying no tag, and `All
Documents` means everything the sources hold, so a file you opened from Downloads is in
neither: the sources never saw it. That division stays. Sources are what the app manages;
`Opened` is what you have read. The shelf keeps scanning folders and does not merge
database rows into `All Documents`, which would make the shelf's own counts stop matching
what is on disk.

Search crosses the line even though the lists do not. The palette's library search reads
document rows, so an orphan is findable by title, author or text from the moment it is
opened, whichever list is showing.

### 6. The page draws before the library answers

Critical path is PDFKit opening the file and drawing page 1. The library opens on a
background task.

- Position arrives within 150ms: the page moves, invisibly.
- Later than that: the page stays where it is, and the status line offers `resume at
  p. 12` until you scroll or ten seconds pass.

Never a jump under a reader who has already started reading. This is the rule the timing
serves, not the other way around.

Deferred to the library window becoming visible, or to idle: text extraction, cover
rendering, source scans, the file watcher, BibTeX refresh.

### 7. Marks are read off the file, not remembered separately

A `MarkReader` actor: given a URL, loads the PDF off the main actor, returns its highlight
annotations, caches by path and modification date, drops the cache when either changes.

The Notes panel asks it whenever the selection changes and no document is open, which
fixes the panel that says "Open this document to see the passages marked in it" over a
paper with nine highlights on it. Clicking a mark opens the document at that page.

No second copy in the database. The PDF is the record; a mirror would be a thing that can
be wrong, and a panel that is confidently wrong is worse than one that is slow.

### 8. Settings are commands

Every switch in Settings is findable by name in the palette, which toggles it in place with
its current state on the row.

Built as their own small table rather than as `Command` cases, which is what this said
first. A command has a scope, a shortcut and a line in the shelf's dispatch; a preference
has none of those, and fifteen more cases would each have needed a row in the shortcut
table and a branch in a switch to express a name, a value and one thing to do about it.
Settings with a handful of values cycle through them on Return, which is the whole editor a
choice of three needs.

Settings that take a value get an input line in the palette: `> AI model ⟩ ` completes over
the allowed values. Settings whose value is free text (API keys, contact email, naming
patterns) open the Settings window at the right pane instead. A key typed into a search
field is a key in a search field's history, and no amount of convenience is worth that.

## Order of work

1. Handler declaration, reader scene, delegate, deferred library startup. This is the
   phase that makes the app usable as a viewer; everything after it is refinement.
2. Reading position timing and the resume affordance.
3. The `Opened` list and the row written on open.
4. `MarkReader` and the Notes panel.
5. Settings in the palette.

Each phase stands alone and can ship on its own.

## Testing

- The orphan query and the `Opened` list: documents under a source, documents under none,
  a document whose source is removed while it is open.
- `MarkReader`: a fixture PDF with three highlights and one note; the cache invalidated by
  touching the file; a file that cannot be read returning empty rather than throwing.
- Palette settings commands: a toggle changes the pref, a value command offers exactly the
  allowed values, a secret command opens the window instead of an input line.
- Reading position: within the grace period the page moves, past it the page does not and
  the affordance appears.

The launch path itself is checked by hand. It is `NSApplication` behaviour, and a test
that fakes `application(_:open:)` tests the fake.

## Before starting

Two things in the tree first:

- The spacing-token sweep across 21 files in `Sources/` is uncommitted and was not part of
  this work. It lands as its own commit, or is reverted, before any of this begins.
- `Shell.swift` still hardcodes ⌥⌘I on the inspector menu item while `Keymap` now says
  ⌘⇧B. The menu and the palette disagree. Fixed in phase 1.
