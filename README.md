<img src="docs/icon.png" width="128" alt="PDF Hammer">

# PDF Hammer

A macOS app that strips passwords from PDFs and beats their filenames into
`YYYY-MM-name.pdf`. Built on PDFKit and SwiftUI. No third-party dependencies.

```bash
./build.sh --install
```

Builds `dist/PDF Hammer.app`, ad-hoc signs it, and copies it to `/Applications`.

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

**Trash spare copies** marks the extras of byte-identical groups only, keeping the
largest, then the shortest-named. A likely match is a guess, and guesses do not get to
delete a book on their own: those are badged and left for you.

## Naming with AI

`G`, or **Ask AI**, reads the opening pages and suggests a title. The reply becomes a
suggestion like any other: it still has to be confirmed, and you can type over it.
**Ask AI for N names** runs the whole pending queue, four at a time, behind a
confirmation that names the count, since you are billed per request.

Settings (the gear, or ⌘,) holds the key, model and endpoint. Any OpenAI-compatible
endpoint works. The key is kept in your Keychain rather than in preferences, which are a
plain file any process running as you can read. `OPENAI_API_KEY` is used as a fallback,
though an app launched from Finder does not inherit a shell's environment, so that only
helps when it is launched from a terminal.

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
| `S` `F` | skip the file / the rest of its folder |
| `D` | move to the Trash |
| `R` | reopen a decided file |
| `J` `K` | move without deciding |

Apply runs the reviewed plan against the exact files the preview found and uses
your confirmed names verbatim. Change a source, a password or a rule and it greys
out until you preview again, so a stale plan can never run.

Originals move to `original_pdfs/` inside each source by default, mirroring their
subfolders. You can rename that folder or point everything at one folder anywhere on
disk, in which case each source gets its own subfolder so two roots holding the same
relative path do not collide. Delete always means the Trash, never an outright removal.

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
