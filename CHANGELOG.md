# Changelog

All notable changes to PaperShelf are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are plain semantic
numbers rather than dates.

## [Unreleased]

### Added

- Suggest subject tags for the current PDF with the configured model, review and edit
  them before saving, and browse a library-wide tag cloud with document counts.
- Turn off AI features in General settings to hide model tools, cancel pending requests,
  and block assistant handoffs and MCP access. Reading, notes, search and citation metadata
  remain available. Configure local model servers with separate local credentials.
- Navigate websites, save versioned reading copies and web archives, and cite page-supplied
  metadata with the source URL and capture date. Saved articles use the PDF reader's notes,
  highlights, search and split panes. Reopening the live page and freezing again retains
  the old annotated version.
- Ask the configured API provider about a passage, a mark or all notes without requiring
  the ChatGPT application.

### Fixed

- Keep a compact command-palette button beside the website and highlighter controls.
  Restore toolbar help and add tooltips to reader, tab, search, naming and settings actions.
- Simplify notes export and file actions, align saved-website details, and keep the web
  highlighter compact. Wait for equations and fonts before capture, and retain refreshed
  citation metadata and revision dates without altering older versions.
- Reflow long websites onto A4 PDF pages with margins instead of saving one tall strip.
- Show the note editor from the reader toolbar and command palette.
- Keep the split inspector attached to the clicked page instead of changing on hover.
- Accept file drops in the single reader, drag tabs between panes, and enlarge tab close
  targets. Add selection highlighting, copying and notes to the reader context menu.

## [1.14.1] - 2026-09-07

### Fixed

- Draw one tab strip for each split page, rather than a second strip across both pages.
- Return to one reader when opening a paper from the catalogue or list. Split reading stays
  an explicit action from its command, tab menu, split button, or a drop onto the reader.

## [1.14.0] - 2026-09-07

### Added

- Hold more than one document open at a time, drawn as tabs above the page. The reviewer's
  selection is a preview tab, replaced as the selection moves rather than accumulating, so
  walking a folder of two hundred files still opens nothing; Return or the new command keeps
  one. Four commands come with it, in the palette and rebindable: keep this document open in
  a tab, close this tab, next tab, previous tab. What was open comes back at the next launch.
- Read two open papers side by side. The tab menu, split control, palette, and dragging a
  library PDF into a reader all place a paper in either pane; the inspector follows whichever
  page has focus. Close all open tabs from the palette to return to the library.
- Right-clicking a file in the Sources tree opens a menu. Only folders had one, so a file
  reached an empty menu, which macOS draws as nothing at all.
- Read on sepia paper. A fourth PDF contrast beside Normal, Dark tint and White on black,
  warming the page without touching the ink, so it is worth having under a light theme as
  well as a dark one. The shelf's covers and the scripting command know it too.

### Fixed

- Keep the shelf wider than its bare floor beside the inspector. One absolute width was
  shared by every display, so a 13 inch laptop opened with a 360 point file list.
- Fold the filter bar into an overflow menu rather than drawing it over the inspector. Its
  controls could not shrink, so a running plan painted up to 305 points past the pane.
- Open a reader from Finder at a size the display can show, and reopen it where you left it.
- Draw no outline where it would be too narrow to read, rather than a sliver of one.
- Find the selected file by key instead of walking the shelf. Every walk resolved symlinks
  per file, which measured 48ms over five thousand documents on each pass.
- Hold the file list's rows instead of flattening the whole tree on every redraw.
- Make the command palette available from every window, and make the pane shortcut work from
  the focused reader as well as the catalogue.

## [1.13.0] - 2026-09-05

### Added

- Add a full-screen Presentation mode that fits each PDF page without scrolling, hides every
  panel initially, and supports optional left and right arrow page turns.
- Let the command palette teach each command's shortcut and toggle the Sidebar, Inspector,
  Notes, and Contents while presenting.

### Fixed

- Keep incomplete Find fields from filtering the document list.

## [1.12.0] - 2026-09-05

### Added

- Find text in an open PDF with ⌘F, a focused query field, every occurrence listed by page,
  keyboard selection, and Return to jump to the selected occurrence.

### Fixed

- Put Find controls in the Find panel so searching stays usable in reading mode.
- Let a stale Markdown notes companion be synchronized directly from Notes.

## [1.11.4] - 2026-09-04

### Added

- Show the timestamp for each mark, the Markdown companion's current state, and a direct
  way to open that companion from Notes.

### Fixed

- Keep a new highlight's exact selected text instead of including the rectangular gap
  around wrapped lines.
- Create a library record when bookmarking an open PDF that has not been scanned yet, so
  the Bookmarks view receives the new bookmark.

## [1.11.3] - 2026-09-02

### Fixed

- Start directly in the catalogue when catalogue view is selected, even when automatic
  previews are disabled.

## [1.11.2] - 2026-09-02

### Added

- Make the current file's BibTeX citation directly searchable in the command palette.

### Changed

- Keep PDF contrast consistent in thumbnails, pages, and the surrounding reading canvas.
- Remember the library window's layout and appearance preferences between launches.
- Keep Info actions beside the metadata they act on, and restore standard Settings window
  controls.

### Fixed

- Remove redundant filename lines under catalogue thumbnails.
- Keep the reading-mode toolbar state and source navigation in sync with the current view.
- Restore the inspector shortcut even when no file is selected.
- Make Zen mode hide every panel, fit the page to width, and restore the previous layout
  when it ends.
- Handle native trackpad swipes over a PDF as previous/next document navigation.

## [1.11.1] - 2026-09-01

### Added

- Add Finder-style context menus to catalogue PDF cards, including a recoverable Move to
  Trash action that runs through the existing Apply flow.

### Changed

- Align scoped highlight editing with Settings, including editable colours and blank fields
  that clearly inherit the library meaning.

## [1.11.0] - 2026-09-01

### Added

- Publish a focused landing page, a real catalogue screenshot, and newcomer build and
  contribution guides.
- Make the repository public with GitHub Pages and a protected release workflow.

### Changed

- Keep vendored agent skills out of the repository and remove machine-specific paths from
  tracked files.
- Center the app icon artwork and keep its geometry covered by a regression test.

## [1.10.2] - 2026-09-01

### Added

- Open the selected Catalogue or List PDF with Space in native Quick Look, and close it
  with Escape.

## [1.10.1] - 2026-09-01

### Added

- Configure PaperShelf as the macOS default PDF viewer from Settings.

### Fixed

- Make settings search keywords case-insensitive.

## [1.10.0] - 2026-09-01

### Added

- Pull live highlights and notes through MCP with revision polling, so ChatGPT can check for
  changes without receiving the same document twice.
- Read and update highlight colors and semantic meanings through MCP at library, folder,
  project, or document scope.

### Fixed

- Preserve quoted text from PDFs whose embedded font mapping makes PDFKit return mangled text.

## [1.9.0] - 2026-09-01

### Added

- Share all highlights and notes from the Notes rail with ChatGPT, either in a new
  conversation or by copying them into an existing one.
- Add quick theme and PDF contrast controls to the top toolbar.

### Fixed

- Find `OPENAI_API_KEY` from `~/.zshrc` when the app is launched outside a shell.

## [1.8.0] - 2026-09-01

### Added

- Move between PDFs with a horizontal trackpad gesture and read any PDF in a focused full-screen window.
- Choose normal, tinted, or white-on-black PDF contrast.
- Start a note directly from the note action or highlighting bar, keep selected highlights and notes in sync, and dictate notes with audio transcription.
- Keep annotations synchronized with a generated Markdown companion beside each PDF, with a preference to turn synchronization off.
- Review and apply file renamings from the command palette.
- Customize highlight meanings at library, project, or paper scope, with paper settings surviving filename changes.

### Fixed

- Preserve annotation quote text for imported PDFs and text containing Unicode punctuation or ligatures.

## [1.7.0] - 2026-09-01

### Added

- Searching the library no longer needs a file path. Asking about a topic searches every
  indexed document and comes back with quoted passages and the page each one came from.
- Every result carries an id that reading, highlighting, citing, filing and tagging all
  accept, so nothing needs a path once something has been found.
- Documents can be filed into reading projects and tagged from a conversation.
- Bibliographies can be scoped to a folder, a project, a tag, or an explicit set of
  documents.
- Duplicate copies of the same work can be found across the whole library, not only
  within one folder.
- Renaming files from a conversation, off by default behind a preference in Settings,
  Integrations. A proposal shows what would happen before anything moves; applying it
  re-checks every file and refuses the whole plan if anything changed underneath it.

### Changed

- The stored text index now records which page each passage came from, so page numbers
  in an answer are real rather than estimated. Existing documents are re-read once to
  pick this up.

### Security

- Encrypted documents open with the passwords already saved in the app. No tool asks
  anyone to type one any more.
