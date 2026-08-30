<img src="docs/icon.png" width="128" alt="PaperShelf">

# PaperShelf

A macOS library for keeping PDFs named, searchable, annotated, and easy to read.
It can also safely normalize filenames, preserve originals, and work with local AI.
Built on PDFKit and SwiftUI. No third-party dependencies.

```bash
./build.sh --install
```

Builds `dist/PaperShelf.app`, ad-hoc signs it, and copies it to `/Applications`.

## Distributing it

```bash
./Tools/make-dmg.sh
```

Produces `dist/PaperShelf-<version>.dmg` with the app and a drag-to-`/Applications`
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
NOTARY_PROFILE=papershelf ./Tools/make-dmg.sh
```

The notary profile is stored once:

```bash
xcrun notarytool store-credentials papershelf --apple-id you@example.com \
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

## The window

A sidebar, one thing in the middle, an inspector beside it, and a status bar along the
bottom.

The middle is either the collection or a document, never both. The shelf, the
bibliography and the duplicates view are about a collection and show no page; the list is
the reviewer, where a name is decided against the page it belongs to; and opening a
document — ⏎, a double-click, or **Read** in the Info tab — gives the page the middle with
its outline beside it. A page sitting next to every view was half a window spent on a file
nobody had asked to open.

The inspector has four tabs — Info, Rename, Notes, Cite. The notes used to be a column of
their own, 240 fixed points that the window's minimum width had to reserve for whether or
not anyone had opened them; they are a tab now.

Nothing widens the window. Under 1100 points the contents rail becomes a popover under the
button it already had; under 1000 the inspector takes what is left above the page's own
floor, and where there is no room for both, the page folds rather than the window growing.
Under 900 the sidebar is an overlay. The floor is 640 × 480, down from 1011 × 560 — and
1252 wide the moment the notes were open.

The sidebar is one sectioned list and nothing else: four library lists (All Documents,
Reading Now, Recently Added, Unfiled), the sources with their folder tree, the reading
projects, and the tags. Everything you set once lives in a settings window instead of
sharing that column: General, Files and passwords, Name rules, Highlighters, BibTeX,
Keyboard, AI and spend, Integrations, with a search over the lot. That is the rule the two
obey — a setting reachable from two places is a setting that can disagree with itself.

The filter bar under the toolbar is one row: where you are, the query as chips you can
take back one at a time, how much of the collection is shown, and the order. Anything
transient is in the status bar and only there: what is being scanned, how far through a
plan you are, how many files no password opened, what the session has cost, what the
library holds, whether the watcher is on. Clicking it opens the activity log. Nothing about
a running job changes the shape of the toolbar any more.

## Everything from the keyboard

Five regions — sidebar, contents, document, inspector, status bar — with a 2pt ring on
whichever has the keys. ⌃1 to ⌃5 jump straight to one, opening it first if it is
collapsed; ⌃⇥ cycles, skipping anything not drawn. ⎋ is a ladder with one rung per press:
out of the field keeping what you typed, out of the row into its region, then the filters,
then the place.

⌘K reaches everything else: the four library lists, the folders in the results, the
projects and the tags, the documents themselves, the passages inside them, and every
command — including the ones with no shortcut. Six prefixes narrow it: `>` commands,
`#` tags, `@` projects, `/` in the document on screen, `:` a page number, `?` the shortcut
list. Every shortcut is rebindable in Settings › Keyboard, which reports a conflict rather
than quietly taking a key from something else.

## Two views

**Catalogue** is the default: covers laid out as a shelf, each keeping the book's own
proportions, with its title, author, filename and size under it. Thumbnails render lazily
and are cached, so the cost follows the window rather than the size of the collection.
**List** groups the same results by folder instead, and is where a plan is reviewed.

The last run is written to Application Support and shown the instant the window opens,
labelled "From last time, rechecking the disk", while a real scan runs behind it and
replaces it. The cache is keyed to the sources it came from, so a different selection
never reuses it.

Right-clicking a file gives Open, Open With, Quick Look, Reveal in Finder, the three
copies, and the review actions. Finder's own contextual menu cannot be borrowed by another
app, but everything behind it can: Open With is the real list of applications the system
says can open the file, and Quick Look is the system panel.

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

The background watcher checks each file as it arrives against what is already known,
rather than rescanning the shelf, and says so when a copy of something you already own
turns up. A pair you keep is remembered and never raised again.

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
`.bib` itself, syntax-highlighted and ordered alphabetically or by folder. **Wrap** folds
long lines into the pane so a `file` path can be read at any width; the file written out is
unaffected either way.

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

## Naming by pattern

The pattern is what Plan and Apply use. Chips decide what pieces a name has and in what
order; the tidying rules below them decide how each piece is written. Leave the pattern
empty and the ordinary rename takes over — the date lifted out of the filename and put
back at the front.

**Settings › Name rules** is a row of chips you drag into the order you want: date, author, title,
year, publisher, a literal separator, a counter. Each shows what it currently produces for
the selected file, and a chip that resolves to nothing looks empty rather than vanishing,
so a name that came out short says why.

A chip carries its own case, length and abbreviation, and the whole pattern is also a
line of text you can type instead, which parses back into chips exactly, both ways.
Presets cover the shapes people actually want. A token whose value is missing takes its
separator with it, so `[author]-[title]` with no author is `title`, not `-title`.

Values are tidied by the same rules the ordinary rename uses, which matters more than it
sounds: a book downloaded from the wild arrives carrying the publisher, a hash and the
name of the site, and without that step a pattern would copy all of it through.

## Reading projects

A project is a named subset of the shelf, filed into sections, that you can ask questions
about with its documents as context. It is a place in the window, listed in the sidebar
and opened into it: the conversation in the middle, the documents it asks across beside
it, grouped the way they are filed and honest about the ones with no text yet. The
extracted Markdown is chunked, selected against your question through the library's own
full-text index, and each chunk keeps its document and page so an answer can cite where it
came from and you can click through.

What would be sent is a line above the composer the whole time a question is being typed —
how many documents, roughly how much text, to which host, answered by which model — rather
than a dialog restating it after the decision is made. The dialog survives for the case
that is actually different: an endpoint that is not the default, or one reached in the
clear.

## What it costs

Every AI call is priced and recorded: model, endpoint, what asked for it, tokens each way
including cached and reasoning ones, and the cost. Settings shows the total, this
session, and a breakdown by model and by feature. Where a model is chosen, its price per
million tokens is shown beside it.

Amounts are exact decimals carrying their currency, never floating point, because any
OpenAI-compatible endpoint is allowed and a rate from a provider that does not bill in
dollars must not be added as though it did. A call is recorded even when it fails, since
the provider billed for it either way. A model with no known price is recorded as unknown
rather than as zero, and the price table says when each rate was written down.

## The library

Everything the app has seen is kept in a small SQLite database under Application Support:
what the document is, every path it has been seen at, its tags, its notes, how far into it
you have read, and its extracted text with a full-text index over it. The filesystem
watcher keeps it current.

A reading position is keyed on the document rather than the path, so a book renamed
halfway through is still the book you were reading. Opening one goes back to where you
left off, Info says how far in you are, and **Reading Now** in the sidebar is every book
opened past its first page and not yet finished.

A document's identity is its own, not a hash of its bytes. This app decrypts, renames and
writes highlights into PDFs, so the bytes change under ordinary use; keying on them would
lose a book's tags and notes the first time you renamed it. Renaming tells the library
where the file went instead.

It is SQLite rather than a JSON file because two processes use it: the app writes while
the MCP server reads. That is WAL's job, and it was measured rather than assumed.

The app used to be called PDF Hammer, so the folder used to be called that too. It is
moved to `~/Library/Application Support/PaperShelf` on first launch, once, and only when
there is nothing already there to overwrite: nobody should lose a library to a rename. The
bundle identifier is deliberately left as it was, since changing it would drop the folder
permissions macOS granted, the settings stored against it, and the API key in the Keychain,
none of which the new name is worth.

The MCP server moved with it, to `Contents/MacOS/papershelf-mcp`. An editor configured
against the old path needs the new one:

```
claude mcp remove pdf-hammer
claude mcp add papershelf -- "/Applications/PaperShelf.app/Contents/MacOS/papershelf-mcp"
```

## Naming with AI

`G`, or **Ask AI**, reads the opening pages and suggests a title. The reply becomes a
suggestion like any other: it still has to be confirmed, and you can type over it.
**Ask AI for N names** runs the whole pending queue, four at a time, behind a
confirmation that names the count, since you are billed per request.

Settings (the gear, or ⌘,) is a window with eight panes; **AI & spend** holds the key,
model and endpoint. Any OpenAI-compatible
endpoint works. The key is kept in your Keychain rather than in preferences, which are a plain file
anything running as you can read. `OPENAI_API_KEY` is used as a fallback. A
Finder-launched app inherits launchd's environment rather than a shell's, so when the
variable is not visible the login shell is asked for it once, in memory only.

Only the filename and the first pages' text are sent. The file itself never leaves the
machine, and nothing is sent unless you ask.

## Search

A query bar over the results, filtering the list, the shelf, the bibliography and the
duplicates alike. `/` focuses it, and the magnifying glass is a menu of the fields.

```
extracto 2024            both words appear in either name
author:pearl title:causal   who wrote it, what it calls itself
abstract:epidemic        the document opens by saying this
text:"do calculus"       those words appear anywhere inside it
folder:bank size>10mb    in a folder called bank, over ten megabytes
pages>100 status:locked  long, and no password opened it
```

A query is answered in two halves. What a file says about itself, `name:` `was:`
`folder:` `status:` `year:` `size:` `pages:` `tag:` and bare words, is answered from a
searchable form built once per result set: **1 ms** over 10,000 files, filtering as you
type. What a document says inside itself, `text:` and `abstract:`, is answered by the
library's own index and waits for Return.

`title:` and `author:` read what the PDF says about itself, falling back to what an
earlier pass stored, so they work on a shelf whose files have been listed but not opened.
`year:` matches the year in the name, the year the PDF says it was made, or the year the
file was last written. `pages:` uses the library's count for a file nothing has opened,
and an unknown count matches no `pages:` term rather than passing as zero. Sizes take
`k`, `mb`, `gb`. Terms are joined with and. A field that does not exist is still searched
for as literal text, but the bar says so rather than leaving a typo looking like an empty
result.

Searching inside documents needs their text read once, which is the one pass that opens
every file on the shelf, so it is asked for by name (`Index text for search`, or the
button the bar offers when a query needs it). It reads across every core, writes in
batches so stopping keeps what it read, skips what it has already read unless the file
has changed since, and stores up to 100,000 characters per document. Documents it has
never read are counted in the bar rather than quietly answered "no match".

Matching a name is a byte scan over normalised UTF-8 rather than `String.contains`, which
is grapheme-cluster aware and roughly fifty times slower. Both sides are canonically
composed first, so an accent written as one code point still matches one written as two.

## Talking to it from an editor

PaperShelf ships an MCP server, so Claude Code, Codex and anything else that speaks the
Model Context Protocol can search your library, read a document as Markdown, build a
bibliography and find duplicates. It is a separate binary inside the app bundle at
`/Applications/PaperShelf.app/Contents/MacOS/papershelf-mcp`, and it holds no state: the
protocol has no sessions, so every call names the folder it works on.

Claude Code:

```
claude mcp add papershelf -- "/Applications/PaperShelf.app/Contents/MacOS/papershelf-mcp"
```

Codex, in `~/.codex/config.toml`:

```toml
[mcp_servers.papershelf]
command = "/Applications/PaperShelf.app/Contents/MacOS/papershelf-mcp"
```

The tools are `list_documents`, `search_documents`, `read_document`, `bibliography` and
`find_duplicates`. Paths are absolute paths on this machine.

The server answers revision `2026-07-28`, which is stateless and asks for `server/discover`,
and it also answers the older `initialize` handshake, because that is what installed clients
still open with. `Tools/mcp-check.sh` drives it over stdio and checks both.

## Encryption

**Lock the output with a password** writes every file out encrypted with a password of
your choosing, which is the inverse of the rest of the app. A file that no password opened
is passed through as it is rather than being sealed with a new one, since that would
strand it behind a password it never had.

Locking rebuilds the document page by page first, the same as unlocking does, because
PDFKit would otherwise carry the source's own encryption over into the copy. The outline
travels with it, so a book keeps its table of contents.

The password is held in memory only and never written to preferences, so it has to be
given again each launch.

## ChatGPT

The ChatGPT desktop app reads plugins from a personal marketplace on this machine, and a
plugin may declare an MCP server spoken to over stdio. PaperShelf already ships one, so it
can be installed as a local plugin: nothing is published, nothing is reviewed, and nothing
leaves the machine.

```
Tools/install-chatgpt-plugin.sh
```

Then restart ChatGPT and add PaperShelf from its plugin list. It can search the library,
read a document or a single page, list what you highlighted, and build a bibliography.

Note that this is the desktop app's own plugin system. ChatGPT on the web connects to MCP
servers over HTTPS only, so a local server is not reachable from there without exposing it.

Separately, every highlight in the notes rail offers **Open in ChatGPT**, which starts a
conversation with the passage already in the composer, and **Copy for ChatGPT**, for a
conversation you already have open. The app registers only a `codex://` scheme and can
address a new thread but not an existing one, which is why copying is offered as well.
Neither sends anything on its own: the text lands in the composer and you decide.

## Plan, review, apply

Nothing on disk moves until you have looked at every file. **Plan** is read-only
and works out the new names; the reviewer then walks the plan one file at a time,
showing the PDF next to an editable name.

| key | |
|---|---|
| `Return` `C` | confirm and go to the next file |
| `E` | edit the name |
| `A` | apply this one file now |
| `S` `F` | leave the file alone / the rest of its folder |
| `D` | move to the Trash |
| `M` | move to another folder, under its new name |
| `R` | reopen a decided file |
| `J` `K` `N` `P` arrows | move without deciding; in the catalogue `↑``↓` cross a row |
| `?` | every shortcut, in one sheet |
| `⌘K` | the command palette: any file, and every command whether or not it has a key |
| `⌘1`…`⌘4` | list, catalogue, BibTeX, duplicates |
| `⌘D` `⌘R` | find duplicates, reveal in Finder |
| `⌘⇧Return` | confirm everything still pending |
| `B` | copy this file's BibTeX entry, asking the model first if fields are missing |
| `O` | open in the default PDF viewer |
| `⌘Z` | undo the last decision |

Every one of these is a row in **Settings › Keyboard**, and every one can be changed.
The list is the same table the key monitor reads, so it cannot drift from what actually
happens, and taking a key that another command already answers to asks first and says
what it would cost. A command with no shortcut at all is still reachable: `⌘K` lists all
of them.

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
Sources/PaperShelfCore/Hammer.swift        naming, file operations, scanning
Sources/PaperShelf/ContentView.swift       window, library sidebar and source lifecycle
Sources/PaperShelf/Catalogue.swift         shelf, list, reader and keyboard commands
Sources/PaperShelf/Review.swift             PDF preview, notes, highlights and inspector
Tools/make-icon.sh                        regenerates the icon
```

`swift test` runs the full suite, including real encrypted PDFs, library persistence,
search, responsive layout arithmetic and the end-to-end naming pipeline.

The app is unsandboxed and ad-hoc signed, which is enough for local use. macOS asks
once for access to Desktop, Documents and Downloads.
