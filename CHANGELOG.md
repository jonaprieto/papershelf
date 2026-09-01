# Changelog

All notable changes to PaperShelf are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are plain semantic
numbers rather than dates.

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
