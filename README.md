<img src="docs/icon.png" width="128" alt="PDF Hammer">

# PDF Hammer

A macOS app that strips passwords from PDFs and beats their filenames into
`YYYY-MM-name.pdf`. Built on PDFKit and SwiftUI. No third-party dependencies.

```bash
./build.sh --install
```

Builds `dist/PDF Hammer.app`, ad-hoc signs it, and copies it to `/Applications`.

## Distributing it

```bash
./Tools/make-dmg.sh
```

Produces `dist/PDF-Hammer-<version>.dmg` with the app and a drag-to-`/Applications`
symlink, and prints its SHA-256.

Signing is layered, and each layer changes what someone who downloads it sees:

| | what they get |
|---|---|
| unsigned | Gatekeeper refuses it: "damaged and can't be opened". Right-click → Open, or `xattr -d com.apple.quarantine`, is the only way past |
| `DEVELOPER_ID` set | Signed with a hardened runtime, but still warns about an unidentified developer |
| `NOTARY_PROFILE` set | Submitted to Apple and stapled. Opens with no warning |

Both come from the environment, so nothing secret is in the repo:

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=pdfhammer ./Tools/make-dmg.sh
```

The notary profile is stored once:

```bash
xcrun notarytool store-credentials pdfhammer --apple-id you@example.com \
      --team-id TEAMID --password <app-specific-password>
```

Both require a paid Apple Developer account. Without one the image is still perfectly
usable, it just asks the person opening it to right-click → Open the first time.

Pushing a `v*` tag runs `.github/workflows/release.yml`, which tests, builds the image
and attaches it to a GitHub release. It signs and notarizes only if the repository has
`MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD`, `MACOS_DEVELOPER_ID`,
`NOTARY_APPLE_ID`, `NOTARY_TEAM_ID` and `NOTARY_PASSWORD` set, and produces an unsigned
image otherwise.

## What it does

| before | after |
|---|---|
| `Cuenta_ABC123_2024-06.pdf` | `2024-06-cuenta_abc123.pdf` |
| `reporte-anual-2024.pdf` | `2024-reporte-anual.pdf` |
| `extracto_23_08_2026_acme66.pdf` | `2026-08-extracto_acme66.pdf` |
| `2024-broker-statement.pdf` | unchanged |

It reads `YYYY-MM-DD`, `DD-MM-YYYY`, `YYYY-MM` and `YYYY`, day-first on ambiguity.
The date is lifted out of the name and moved to the front, so a file that already
starts with its date never grows a second one.

**A date in the filename always wins.** It is the only date the document itself
states. An annual statement for 2024 is routinely generated in 2025, so a
timestamp read off the file would destroy information rather than add it. Only
when the name has no date at all does it fall back, in order, to the folder name,
the PDF's creation date, then the file's modification date, each switchable.

Optional rules cover casing, separator style (kebab or snake), symbol stripping and
accent folding. Flip one and the whole list restyles instantly, without reopening a
single PDF.

## Two views

**Catalogue** is the default: covers laid out as a shelf. Thumbnails render lazily and
are cached, so the cost follows the window rather than the size of the collection.
**List** groups the same results by folder instead.

Sources are remembered between launches, and adding one runs a preview straight away
unless you turn that off. **Forget sources and cached covers** clears both.

Sources are kept as a set of non-overlapping roots. Picking a folder absorbs anything
already selected inside it, and a file or folder already covered is never added twice.
Overlap is not harmless: a file reachable from two roots would be attributed to whichever
was scanned first, and that root decides where its `original_pdfs/` backup lands.

## Duplicates

**Find duplicates** groups files that are the same book twice.

Byte-identical copies are found by hashing, but only within groups that already share a
file size, so a large collection is not read end to end to answer a question most files
settle by size alone. Everything else is grouped by a name key that ignores the date and
copy markers, so `Dune.pdf`, `dune-2.pdf` and `Dune (1).pdf` land together while
`Catch 22.pdf` stays clear of `Catch.pdf`.

Three passes, weakest claim last:

1. **Identical** — the same bytes, by SHA-256, hashed only within groups that already
   share a size.
2. **Same pages** — different bytes, but the opening pages read the same. Catches a
   re-download, a re-encode, or one copy encrypted and one not, under names that share
   nothing. A file with too little extractable text is skipped entirely: without that
   floor every scan with no text layer would fingerprint alike and the whole shelf would
   report as one enormous duplicate.
3. **Similar names** — only the names agree, once dates and copy markers are removed.

A file lands in at most one group, and the stronger claim wins.

Duplicates get their own view, because choosing between two copies means seeing them
beside each other and beside the page. Each group shows its copies with sizes, the keeper
starred, and **Keep this one** on the others to change that choice. **Trash the other N**
works per group; the bar's **Trash identical spares** does every byte-identical group at
once and never touches a likely match, since that is a guess and a guess should not
delete a book on its own.

## Bibliography

A third view generates a `.bib` for everything currently selected, rebuilt on every
change, so it always describes what Apply would produce rather than what is on disk now.

Title and year are read back out of the normalized name. Author cannot be, so entries
missing one are listed along the top as chips: click one to jump to that file and run
**Ask AI**, which fills in author and year. **Complete only** hides the gaps, and the
result can be copied or saved.

Citation keys are `surname:year:firstword`, with a letter appended when two works would
otherwise collide.

The **entry type** decides what counts as missing: `@book`, `@article` and `@techreport`
want an author, a title and a year, `@online` wants a title and a year, and `@misc` wants
only a title. Publisher, journal and institution are never written and never reported as
missing, because nothing here can read them off a PDF and a complaint you cannot act on is
just noise. The `file` field is omitted by default.

The BibTeX view has two panes: **Entries**, the browser above, and **File**, the generated
`.bib` itself, syntax-highlighted and ordered alphabetically or by folder.

Entries are built only when something is about to look at them, so a run that never opens
this view never pays for it. The file is rendered one entry at a time inside a lazy stack,
so only what is on screen is ever tokenized, and it is rebuilt off the main thread and
only when its inputs actually move.

Formatting follows bibtex-tidy: line width (80 by default, 0 to turn wrapping off),
indent, `{braces}` or `"quotes"`, aligned equals signs, trailing comma, blank lines
between entries, alphabetical fields, lowercasing ALL-CAPS values, and omitting the
`file` field. All of it lives in Settings. A value longer than the line wraps onto
indented continuations; a single word longer than the budget is left whole, since
breaking a path to satisfy a column is worse than exceeding it. **Edit** switches to a plain editor and the text becomes
yours; ordering is frozen while it is, and **Discard edits** goes back to the generated
version. The highlighter's tokens rebuild their input exactly, so what you read is
character for character what Copy and Save write.

## Naming with AI

`G`, or **Ask AI**, reads the opening pages and suggests a title. The reply becomes a
suggestion like any other: it still has to be confirmed, and you can type over it.
**Ask AI for N names** runs the whole pending queue, four at a time, behind a
confirmation that names the count, since you are billed per request.

Settings (the gear, or ⌘,) holds the key, model and endpoint. Any OpenAI-compatible
endpoint works. The key is kept in your Keychain rather than in preferences, which are a
plain file any process running as you can read. `OPENAI_API_KEY` is used as a fallback. A
Finder-launched app inherits launchd's environment rather than a shell's, so when the
variable is not visible the login shell is asked for it once, in memory only.

Only the filename and the first pages' text are sent. The file itself never leaves the
machine, and nothing is sent unless you ask.

## Preview, review, apply

Nothing on disk moves until you have looked at every file. **Preview** is read-only
and produces a plan; the reviewer then walks it one file at a time, showing the PDF
next to an editable name.

| key | |
|---|---|
| `Return` `C` | confirm and go to the next file |
| `E` | edit the name |
| `A` | apply this one file now |
| `S` `F` | leave the file alone / the rest of its folder |
| `D` | move to the Trash |
| `M` | move to another folder, under its new name |
| `R` | reopen a decided file |
| `J` `K` `N` `P` arrows | move without deciding |
| `B` | copy this file's BibTeX entry, asking the model first if fields are missing |
| `O` | open in the default PDF viewer |
| `⌘Z` | undo the last decision |

The header of the inspector has buttons to reveal the file in Finder and to open it
externally. List rows carry the file's size, page count and date, which is what tells two
similar-looking files apart.

A toggle beside **Ask AI** makes the model answer automatically as you reach each new
file. It fires only for a file that is undecided and has never been asked about, so
browsing back over work already done costs nothing.

Apply runs the reviewed plan against the exact files the preview found and uses
your confirmed names verbatim. Change a source, a password or a rule and it greys
out until you preview again, so a stale plan can never run.

Originals move to `original_pdfs/` inside each source by default, mirroring their
subfolders. You can rename that folder or point everything at one folder anywhere on
disk, in which case each source gets its own subfolder so two roots holding the same
relative path do not collide. Delete always means the Trash, never an outright removal.

## Sorting

**Sort by** on the results bar reorders on the fly: folder, new name, original name, size,
pages, date or status. Size, pages and date start largest-or-newest first, since that is
the question being asked when you sort by them; the arrow reverses any of them. Names sort
the way a person reads them, so `chapter 9` comes before `chapter 10`.

Ordering applies within each folder in the tree views, and across the whole grid in the
catalogue.

## Activity

Every decision and every operation is recorded as it happens, with a timestamp, and shown
newest-first in the Activity panel. It can be copied or saved as fixed-width text:

```
2026-08-24 10:12:03  renamed    bank/2024/Extracto.pdf  -> 2024-06-extracto.pdf
2026-08-24 10:12:03  trashed    junk.pdf
```

Greppable rather than pretty, on the grounds that a log is read when something has gone
wrong and piping it through `grep` matters more than alignment.

`⌘Z` takes back the last decision. A step that touched many files, like **Confirm all
remaining** or `F`, is undone as one step. It undoes decisions, not disk operations: once
Apply or `A` has run, the originals folder or the Trash is the way back.

## Notes

PDFKit's `write(to:)` carries the source encryption over even after a successful
`unlock`, so a decrypted file is rebuilt page by page. Files needing no decryption
are copied byte for byte rather than re-serialized.

Directory scanning walks levels concurrently with prefetched resource keys. A dry
run opens PDFs across all cores since it mutates nothing; a real run stays serial so
collision suffixes (`-2`, `-3`) stay deterministic.

```
Sources/PDFHammerCore/Hammer.swift   naming, file operations, scanning
Sources/PDFHammer/App.swift          SwiftUI window and reviewer
Tools/make-icon.sh                   regenerates the icon
```

`swift test` runs 50 tests, including real encrypted PDFs through the full pipeline.

The app is unsandboxed and ad-hoc signed, which is enough for local use. macOS asks
once for access to Desktop, Documents and Downloads.
