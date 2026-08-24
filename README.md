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

Originals move to `original_pdfs/` by default, mirroring their subfolders. Delete
always means the Trash, never an outright removal.

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
