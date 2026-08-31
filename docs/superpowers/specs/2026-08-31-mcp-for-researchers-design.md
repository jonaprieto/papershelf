# PaperShelf MCP for researchers

Design, 2026-08-31.

## What this is for

A researcher using the ChatGPT desktop app should be able to ask about the papers on
their own Mac the way they would ask a colleague who had read them: find the ones about
a topic, quote a passage with the page it came from, see what they highlighted, get a
BibTeX entry, and file what they found into a reading project. Today the MCP server can
almost do the first half and none of the second.

The server is `Sources/PaperShelfMCP`, a hand-rolled JSON-RPC-over-stdio server shipped
inside `PaperShelf.app` and installed as a local plugin for the ChatGPT desktop app
through `Sources/PaperShelf/PluginInstall.swift`. It stays that. No HTTP transport, no
OAuth, no remote connector: the files never leave the machine, and nothing here changes
that.

## What is wrong today

Twelve tools, and four of them (`list_documents`, `search_documents`, `bibliography`,
`find_duplicates`) require an absolute `folder` path. A researcher who asks "find my
papers on session types" gives the model no path, so the model guesses one or gives up.
Meanwhile `Library.fullTextSearch` already searches the whole indexed library and is not
exposed at all.

Search returns rows, never text, so every quote costs a second round trip. The
library-backed tools hand back a document `id` and the file-backed tools accept only a
`path`, so the two halves of the surface cannot be chained.

Nothing writes. A researcher can find twelve relevant papers and has no way to keep
them.

`passwords: []` is passed at every call site, so a locked PDF is unreadable even though
the app is holding the password that would open it.

And the index itself is the wrong shape, which is the finding that shapes most of this
document.

## The index has two shapes

`extracted_text.markdown` is written by three producers that do not agree.

| producer | shape | page markers | cap |
| --- | --- | --- | --- |
| bulk indexer, `Sources/PaperShelf/TextIndexing.swift:90` | `documentText()`, raw page concatenation | no | 100,000 chars |
| project read, `Sources/PaperShelf/ProjectsLive.swift:155` | `markdown(for:passwords:using:)` | `## Page N` | none |
| convert panel, `Sources/PaperShelf/LibrarySync.swift:237` | same, whichever engine the user kept | `## Page N` | none |

So a document that has been opened in a project or converted by hand is already stored
as complete, page-marked markdown. One that the bulk indexer read is neither, and
nothing in the schema records which kind a row is.

Two consequences. A search cannot report a page, because most rows have no page
information in them. And a search of a 400-page book only ever sees its opening: at
100,000 characters a book contributes about thirty dense pages, so a phrase past that is
invisible.

## Fixing the index

The bulk indexer stores page-marked markdown, so every producer agrees and the page is
readable straight out of the text.

```swift
// Sources/PaperShelf/TextIndexing.swift:90
- let text = documentText(of: job.url, passwords: passwords)
+ let text = indexedMarkdown(of: job.url, passwords: passwords)
```

`markdownFromPDF` underneath, and not `markdown(for:passwords:using:)`. The
engine-choosing entry point falls through to `markdownFromScan` (Vision OCR, page by
page) for any document without a text layer, and to a spawned external process per
document when marker or docling is installed. Over fourteen thousand books that is hours
to days, where the old `documentText` was minutes. `markdownFromPDF` walks the same
`page.string` loop `documentText` did and costs the same. The project and convert-panel
paths keep calling the engine-choosing entry point; only the bulk pass changes.

`indexedMarkdown` rather than `markdownFromPDF` directly, because the two disagree about
failure in a way that would quietly corrupt the index. `documentText` returns nil when
the file will not open or stays locked, which the indexer counts as a failure and retries
on a later pass, and `""` when the document opened and has no text layer, which is a
permanent answer worth storing so the file is never read again. `markdownFromPDF` returns
`"# Title\n\n"` in all three cases: a locked book would be stored as successfully indexed,
counted as a success, and never retried.

So `documentText` is replaced, not deleted, by a sibling in
`Sources/PaperShelfCore/TextIndex.swift` that keeps its contract:

```swift
/// The document as page-marked Markdown, up to the cap, with `documentText`'s own
/// answers for the two cases that are not text: nil when the file will not open or
/// stays locked, "" when it opened and has no text layer.
public func indexedMarkdown(of url: URL, passwords: [String],
                            limit: Int = textIndexCharacterLimit) -> String?
```

`Tests/PaperShelfCoreTests/TextIndexTests.swift` moves onto it rather than being deleted:
its four cases (whole text, clipped at a limit, empty for a blank document, nil for a
missing one, nil for a locked one without the password) are exactly the contract that
must survive the change.

### The cap stays, much higher

Uncapped, a 400-page book is roughly 800KB of text and fourteen thousand of them are
about 11GB of SQLite. `textIndexCharacterLimit` rises from 100,000 to 2,000,000 and
becomes a preference. That is whole-book for essentially every real document while
bounding a five-thousand-page scan. A row that hits the cap is recorded as truncated and
every tool that reads it says so, so a miss is never reported as an absence.

### Re-reading what is already stored

`needsIndexing(extractedAt:fileModified:)` only re-reads a document whose file changed,
so existing rows would keep the old shape forever.

`schemaV3` adds `extracted_text.format TEXT`, written as `"markdown-v1"` by every
producer from now on. A row with a null or older `format` is stale regardless of its
file's mtime, so the next index pass rewrites it.

A `format` column rather than sniffing the text for `## Page`: a document with no text
layer at all also has no markers, and a heuristic would re-read it on every pass forever.

## Tool surface

Sixteen tools. The twelve keep their names, so nothing that already works stops working.
`folder` becomes optional on the four that demanded it, and with no folder they read the
library instead of the disk.

### The twelve, deepened

`list_documents(folder?, recursive?, limit?, cursor?)`
With a folder, scans it as today. With none, returns the library's totals (documents,
how many have text, how many are truncated, projects, tags) followed by the first page of
documents. This doubles as the orientation tool, which is why there is no separate
`library_overview`.

`search_documents(query, folder?, recursive?, limit?, cursor?, pages_per_document?)`
With a folder, the live scan and the app's own query language, as today. With none, FTS5
over the library ranked by bm25, with excerpts and pages (see below). Default 20 hits.

`read_document(document_id?, path?, pages?, page_markers?, max_characters?, password?)`
Either identifier. `pages` is a range like `"12-20"`, sliced out of the stored markdown by
its markers. Serves the stored text when there is one; extracts, stores and returns it
when there is not.

`read_page(document_id?, path?, page, password?)`
Either identifier. Slices the stored markdown when the document has one, falls back to
PDFKit otherwise.

`list_highlights(document_id?, path?, password?)`
Either identifier. Also returns the library's own notes for that document
(`Library.notes`), which are invisible to every tool today.

`bibliography(folder?, project?, tag?, document_ids?, recursive?, type?)`
Exactly one scope, and more than one is an `isError` result naming which were given
rather than a silent precedence order. A researcher who has just been shown eight search
hits can cite those eight by id.

`find_duplicates(folder?, recursive?)`
With a folder, `duplicateGroups(in:)` over a fresh scan as today. With none, library-wide,
grouped by `documents.content_hash`.

`list_projects`, `list_tags`
Unchanged.

`list_project_documents`, `search_project`, `documents_by_tag`
Unchanged in shape. `search_project` gains the same excerpts and pages as
`search_documents`.

### The four new ones

`add_to_project(project, document_ids?, paths?, section?, note?)`
Creates the project when the name is not already one. Files the documents, optionally
under a section, and attaches a note. Documents given by path that the library has never
seen are indexed first, the way `storeAsDocumentText` already does it.

`set_tags(document_ids?, paths?, add?, remove?)`
Both lists in one call, so "tag these six as read and drop the todo tag" is one round trip.

`propose_file_changes(folder, rules?, recursive?)`
Runs `process(jobs:options:)` with `dryRun: true` and returns the proposed renames along
with a token. Writes nothing to disk except the plan file. Works whether or not file
operations are enabled, because it never touches a file.

`apply_file_changes(token)`
The only tool that moves anything. See the safety gate below.

### Passwords

The server reads the stored password list through
`UserDefaults(suiteName: "com.jonaprieto.pdfhammer")` and `PasswordList.active(_:)`, and
passes it wherever it passes `passwords: []` today. It never places a password in any
result, error message, or log line.

The explicit suite name is required, not stylistic. The app reads
`UserDefaults.standard`, which resolves to `com.jonaprieto.pdfhammer` because it is a
bundled app; the server is a bare executable at `Contents/MacOS/papershelf-mcp` with no
Info.plist of its own, so its `UserDefaults.standard` is a different domain and would
silently read nothing.

## Search results

FTS5 narrows to documents by bm25. For each hit the server loads that document's stored
markdown, locates the match, and reads the page from the nearest preceding `## Page N`
marker.

It parses the marker's own number rather than counting markers. `markdownFromPDF` skips a
page with no text entirely, its marker included, so on any document with a blank or
image-only page a count and the real page number diverge.

A hit carries: title, author, year, path, document id, tags, and up to two excerpts, each
with the page it came from. Twenty hits by default, a hard character cap on the whole
result, and an opaque cursor for the next page. Every result that was cut reports
`truncated: true`.

## Writing

Curation writes open a second, read-write `Library` (`public actor Library`,
`public init(url:)`) alongside the existing read-only `LibraryReader`. WAL is what makes
that safe next to a running app: a reader never blocks a writer and a writer never blocks
a reader.

Reads stay on `LibraryReader`, which is synchronous and sits in the hot path of the stdio
loop. The handful of write tools block on a `DispatchSemaphore` to cross into the actor.
That is a deliberate simplification: writes here are a few statements, and making the
whole server async to avoid a semaphore on four tools is not worth it. If the write side
ever grows, the run loop becomes async and the semaphore goes.

### Indexing on demand

`read_document`, `read_page`, `search_project` and `list_project_documents` extract and
store text for the documents in play that have none, and report how many they did.

`search_documents` never does. A library with nothing indexed says so plainly and points
at the app, rather than opening fourteen thousand files inside one tool call that ChatGPT
will kill long before it finishes.

### The safety gate on file operations

File operations are off until the user turns them on in PaperShelf's settings. This is a
new preference, default false.

1. With the preference off, `propose_file_changes` still works, since it only ever dry
   runs. `apply_file_changes` refuses and says which setting to turn on.
2. `propose_file_changes` writes the plan to
   `~/Library/Application Support/PaperShelf/pending-plan-<hash>.json`. On disk, not in
   memory: this revision of the protocol is stateless and ChatGPT may restart the server
   between the propose call and the apply call. Each entry records the source path, the
   destination, and the file's size and modification date. The plan expires fifteen
   minutes after it is written.
3. `apply_file_changes(token)` re-stats every file in the plan and refuses the plan whole
   if any one of them has moved, grown, or been touched since. It honours the existing
   `BackupSettings`, and anything removed goes through `moveToTrash`, never `unlink`.

The token is the plan's hash, so a token cannot be pointed at a different plan, and a
plan cannot drift out from under a token that was issued for it.

## Errors and limits

A problem the model can fix by calling again with different arguments stays an `isError`
result with a plain sentence saying what to do, which is the pattern the server already
follows. JSON-RPC errors are for protocol faults only.

Every tool result is capped in characters. A capped result sets `truncated: true` and,
where it makes sense, hands back a cursor.

## Testing

`Tools/mcp-check.sh` drives the new tools against its scratch database, including the
case that matters most: a plan token applied after the file underneath it has been
touched, which must be refused with nothing moved.

Core tests cover page attribution over markdown containing a skipped page, so the
parse-the-marker rule is pinned rather than assumed, and the truncation flag.

An app test covers the indexer producer switch: text stored by a bulk pass must carry
`## Page` markers and `format = "markdown-v1"`.

## Versioning

`Sources/PaperShelfMCP/main.swift` says `1.1.0` and
`Plugin/papershelf/.codex-plugin/plugin.json` says `1.2.3`. One constant in
PaperShelfCore becomes the source, read by the server's `serverInfo` and checked against
the plugin manifest by the build. The binary gains a `--version` flag so a user
debugging an install can see which one they have.

## What this deliberately does not do

No HTTP transport and no remote connector: ChatGPT on the web is out of scope, and the
stdio server stays the only surface.

No `remove_from_project`, no `create_project`, no `add_note` as separate tools. Creating
is folded into `add_to_project` and removal is done in the app. Sixteen tools is already
near what a model chooses well from.

No background indexing job and no `index_library` tool. A long-running job inside a
stateless stdio server that the client may kill at any moment has no good failure story.

No deletion of PDFs. `apply_file_changes` renames and moves; anything it removes goes to
the Trash.
