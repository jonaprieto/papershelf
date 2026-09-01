# Changelog

All notable changes to PaperShelf are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are plain semantic
numbers rather than dates.

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
