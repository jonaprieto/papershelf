# Adversarial critique of the combined design


# critique:simplicity

## Verdict

Not buildable as designed, and shouldn't be: across the seven documents the proposed surface is roughly three to six times the size of the problems it addresses, and three of the seven (knowledge-graph in full, bibtex-compliance's BibCompliance.swift, biblio-apis' five-source client with a general merge engine) invent problems nobody asked for rather than solving ones that exist, so they should not be built at all in their current form. Two more (ai-cost, rename-patterns) contain a real, proportionate feature wrapped in avoidable permanent-parallel-machinery (NamePattern kept forever beside NameRules) or unmaintainable hardcoded data (a seeded price table admitted to go stale); cut those specific pieces and what remains is small and worth building. mcp-spec's core idea (thin tool wrappers over PDFHammerCore's existing pure functions) earns its keep, but its speculative modern-protocol path, optional resource/prompt adapters, and a projects concept duplicated wholesale in knowledge-graph should go. duplicates-watcher's incremental DuplicateIndex is the right size for its problem and should ship; its OS-notification integration and new-Window-plus-hoist review UI are not, given the design's own fallback already suffices. layout is the one document that needs no cutting: it is exactly the shape everything else should have taken, a numbered list of line-level corrections to existing code with no new types, files, or layers. Separately, the task's premise that a single 4900-line App.swift forces serialization is out of date; that file was split into nine during this research pass, and the real shared-file risk that remains is Hammer.swift, where rename-patterns and duplicates-watcher both propose landing new code in the same neighborhood.

## Objections


### [fatal] knowledge-graph: full SQLite library store (documents/locations/tags/document_tags/projects/project_members/marks/document_notes/chunks + 2 FTS5 virtual tables + trigger triple + actor wrapper + PRAGMA migrations)

Nothing in this document or any other invokes a concrete, already-existing need for a relational store. It invents tagging, saved-query projects, a mirrored copy of PDF annotations, and a page-chunked RAG pipeline, then justifies a 9-table schema by the scale of the problems it just invented. The largest thing this app persists today is a 4-field RunCache (Cache.swift, 53 lines total). This proposal is not 3x the size of a real problem, it has no problem yet.

**FIX:** Do not build it. If exactly one piece turns out to be real (durable free-text notes on a document, the one capability with no existing mechanism), ship that alone as a single JSON file keyed by resolved path, same shape as RunCache, through the shared JSON-store helper named below. No tags, no chunking, no full-document markdown persistence, no marks mirror, no Q&A feature, until each is separately asked for.


### [fatal] knowledge-graph: chunks/chunks_fts + AIContext.swift (selectExcerpts, readingProjectInstruction/Prompt, bm25 budget packing)

This is a complete retrieval-augmented-generation feature, page-scoped chunking, relevance ranking, a second AI prompt contract, layered on top of a store that doesn't exist yet, to answer a question ('let me chat with my reading project') that no fact in any of the seven documents shows anyone asking for.

**FIX:** Cut entirely. The app's one existing AI feature (BookGuess) reads a filename and an excerpt to guess three fields; that is not evidence a Q&A-over-library feature is wanted. Design this only if and when it is actually requested, as its own task.


### [serious] knowledge-graph: marks table mirroring PDFKit annotations

Annotations already have one authoritative source: the PDF file itself (Annotations.swift). Mirroring them into SQL creates a second copy with no stated reader, and the design has to invent a 'supersede' heuristic (flagged in its own RISKS as 'a heuristic, not a guarantee') purely to stop the mirror from silently orphaning itself every time a user highlights something, since saving an annotation rewrites the file's bytes and thus its content hash.

**FIX:** Do not mirror. If cross-document annotation search is ever wanted, read live from PDFKit at query time, the same way the existing `text:` search field already reads document text on demand with no persisted index.


### [serious] knowledge-graph: tags/document_tags/projects/project_members with a tag_filter saved-query language extending Query.swift

Tagging is invented here from nothing (grep confirms no 'tag' concept anywhere in Search.swift's field set today), and this ReadingProject is a second, incompatible invention of the exact same concept mcp-spec independently proposes (mcp-spec: UUID + name + itemKeys + note, one JSON file; knowledge-graph: a SQL table with a saved AND-only tag query). Two documents solved the same non-existent problem twice, in two incompatible shapes.

**FIX:** If reading-projects are wanted at all, there is exactly one answer and it is the smaller one already in mcp-spec: a ReadingProject struct with id/name/itemKeys/note in one JSON file. No tags, no tag_filter DSL, no Query.swift extension. Decide it once, delete it from whichever document loses.


### [fatal] knowledge-graph: choice of SQLite over a flat JSON file, justified primarily by giving a second process (the MCP server) lock-free concurrent read access

The entire storage-engine decision rests on 'the MCP server, as a separate process, resolves the identical path, no IPC needed.' That server is, per mcp-spec's own summary, a 'recommended path' that has not been built. Two speculative designs are propping each other up: SQLite is justified by a server that doesn't exist, and that server's own projects tool (see above) is justified by data that wouldn't need to exist without it.

**FIX:** Do not pick a storage engine to solve a two-process concurrency problem before either process's real feature set is settled. If a store is ever needed, decide its shape after the MCP server, if any, actually ships and its read-only tool surface is known.


### [serious] mcp-spec: modern (2026-07-28) stateless per-request _meta path plus server/discover RPC

The spec revision is about a month old, and by the design's own facts neither installed client negotiates it by default (Claude Code 2.1.241 defaults to legacy; Codex 0.149.1's version is unverified). This means writing and shipping an entire protocol mode, roughly a third of the estimated 700-900 line budget (_meta detection, server/discover, UnsupportedProtocolVersionError), with zero current callers to exercise it.

**FIX:** Ship legacy-only first: initialize / notifications/initialized / tools/list / tools/call, which is what both real clients actually speak today. Add the modern path later, if and when a client actually negotiates it.


### [minor] mcp-spec: resources/list, resources/read, prompts/list, prompts/get adapters

The design's own text calls these optional, and none of the 8 proposed tools return a resource or a prompt template. This is dead protocol surface built ahead of any tool that needs it.

**FIX:** Drop both pairs. Ship tools/list and tools/call only; add a resources or prompts adapter the day a specific tool actually needs one.


### [serious] mcp-spec: ReadingProject Core type plus projects.list/projects.create tools

Duplicates knowledge-graph's own project concept in an incompatible shape (see above). Building both means one becomes silently wrong the moment the other lands.

**FIX:** Keep only this smaller JSON version if reading-projects are wanted at all, and say so explicitly rather than letting two documents each assume they own the concept. Otherwise drop projects.* from the MCP surface until a project feature is actually requested; the other 6 tools (list_sources, search, read_markdown, bibliography.list, bibliography.export_bibtex, renames.propose) are the ones that earn their existence, since each is a thin wrapper over an already-existing pure Core function.


### [fatal] biblio-apis: five parallel API clients (Crossref REST, arXiv Atom, OpenAlex, Semantic Scholar, OpenLibrary), each with its own request builder, Decodable struct, and fetch function, plus a general n-source field-merge precedence function (mergeMetadata)

No fact in this or any other document shows a requested 'look up my PDF online' feature; the app's bibliography path today is local PDF metadata plus an AI guess (BookGuess.swift). This proposes five independent implementations of fetch-parse-normalize for a need with no caller, then builds a general reconciliation algorithm to arbitrate between sources nothing calls yet. That is the textbook shape of speculative abstraction the house rules name directly.

**FIX:** Do not build five sources. If a metadata lookup is wanted at all, the smallest version is two functions against doi.org's own content negotiation (doiRequest / parseCSLWork), since that single endpoint already covers Crossref, DataCite, and mEDRA DOIs. No Crossref REST search, no arXiv parsing, no OpenAlex, no Semantic Scholar, no OpenLibrary, and no merge function, until a second real source has an actual caller.


### [fatal] bibtex-compliance: BibField (24 cases) / BibStandard / BibFieldRule / BibRequirement / BibGap / bibCompliance in a new BibCompliance.swift

This is a self-audit engine whose own RISKS section admits it will report nearly every required field as an unfixable gap, because BibEntry structurally has nowhere to hold journal/institution/booktitle/doi. It is an 8-type by 2-standard requirement matrix built to restate a fact the code already states more simply: BibEntry.missing already reports what's absent, and BibType's own comment already explains why more can't be captured.

**FIX:** Do not write this file. If a compliance note is wanted, it is a sentence added to BibEntry's existing doc comment, not a new enum, a new file, and a two-standard field-requirement table.


### [serious] bibtex-compliance: BibtexOptions superseding BibStyle (numericYear, monthAbbreviations, enclosingBraces, maxAuthors, escaping on/off toggle)

BibStyle already covers everything the app's 7-field BibEntry can render. These extra knobs exist to match bibtex-tidy's feature set for normalizing arbitrary third-party .bib files, a job this app never does since it only ever renders entries it built itself (the design says so explicitly when scoping out bibtex-tidy's document-hygiene surface).

**FIX:** Leave BibStyle as is. Add a formatting knob only the day a new BibEntry field that needs it actually ships, not preemptively.


### [minor] bibtex-compliance: CitationKeyStyle preset enum (Better BibTeX / JabRef parity)

The document argues at length against building a citation-key formula engine, then proposes a 3-case enum anyway for a want nobody expressed.

**FIX:** Cut it. citationKey() stays the existing fixed surname:year:firstword shape until a different one is actually requested.


### [serious] rename-patterns: NamePattern kept permanently alongside NameRules (Options.pattern: NamePattern?, with NameRules deletion deferred to 'a separate, later commit')

The design's own migration function proves NamePattern is a strict, lossless superset of NameRules: every NameRules combination maps onto exactly one NamePattern. Keeping both as parallel renderers of the same responsibility once that equivalence is proven is the 'two implementations, keep both' pattern the house rules exist to catch.

**FIX:** Cut over in the same commit: run the migration once, delete NameRules and normalizedName's field-by-field decomposition, and delete the `if let pattern { render } else { normalizedName }` branch. If a same-commit cutover feels too risky, that is a signal to shrink NamePattern itself, not to keep two name renderers indefinitely.


### [minor] rename-patterns: 13-token menu, six of which (pdfTitle/pdfAuthor/pdfSubject/pdfCreator/pdfProducer/pdfKeywords) are raw PDF metadata fields

The app's own BookGuess feature exists specifically because PDF metadata is usually missing or wrong; offering six drag-chips for fields the codebase already treats as unreliable pads the token menu for completeness rather than for a stated need.

**FIX:** Ship 7 tokens: date, year, title, author, folder, stem, counter. Add a pdfX token later, one at a time, only when someone has metadata clean enough to want it.


### [minor] rename-patterns: generic 6-modifier chain (upper/lower/titleCase/truncate/compact/surname) applied left-to-right to every token

By the design's own admission, compact and surname are each meaningful for exactly one token. A general modifier-pipeline framework is being built to serve two single-purpose transforms.

**FIX:** Ship the 4 genuinely generic modifiers (upper/lower/titleCase/truncate). Fold compact into a token spelling (e.g. a distinct `datecompact` token) and fold surname-only extraction into how the author token resolves, until a second real per-token modifier justifies the general chain.


### [serious] ai-cost: PriceTable.seeded, 10 hardcoded per-model prices baked into source with a verifiedAt staleness marker

This commits to hand-maintaining a pricing table forever with no refresh path. The design's own RISKS admit it 'will silently go stale,' and one of its own entries (gpt-5.6-sol) was already found to disagree with a third-party source during the same research pass. A stale number reported as fact is worse than an honest 'unknown.'

**FIX:** Ship the `custom` half only, the user-entered (baseURL, model) to ModelPrice override map already in the design. Delete PriceTable.seeded and the hardcoded dictionary; an unpriced model shows 'cost unknown,' which is accurate and needs no maintenance.


### [minor] ai-cost: PriceOverrides as a second ObservableObject with its own UserDefaults store, alongside SpendTracker's separate Application-Support-JSON store

Two small, related pieces of state (spend history, price overrides) get two observable classes and two storage backends for no structural reason.

**FIX:** Make price overrides a second @Published property on SpendTracker itself, backed by UserDefaults, instead of a second class threaded separately through the view tree.


### [serious] duplicates-watcher: UNUserNotificationCenter integration (authorization flow, delegate callback, categories/actions) as part of v1

The design's own text names the in-app Duplicates tab 'the guaranteed, always-visible path' and treats the OS notification as a convenience whose failure is silent and whose grant-survives-ad-hoc-rebuild behavior is explicitly unverified against Apple's own documentation. Building a full notification-framework integration for something already designed to be non-essential is backwards.

**FIX:** Ship v1 with just the sidebar badge/count on the existing Duplicates tab, which the design already proposes as the fallback. Add OS notifications later only if the badge turns out to be missed in practice.


### [serious] duplicates-watcher: new Window scene for duplicate review, requiring Runner and Covers to be hoisted from ContentView to PDFHammerApp

This is an invasive refactor, the design's own RISKS say every @StateObject ownership assumption inside ContentView needs re-auditing after the hoist, undertaken just to show two covers side by side, when the app already has a Duplicates tab with keeper stars, filenames, sizes, and a live Covers renderer sitting exactly where the decision needs to happen.

**FIX:** Extend the existing DuplicateRow (Catalogue.swift) with the missing fields (dates, page count, a larger thumbnail) inline or behind a .sheet, reusing the Covers instance ContentView already owns. Only reach for a second window if a sheet is later shown to be too small.


### [serious] cross-cutting: mcp-spec's projects.json, ai-cost's spend-ledger.json, and duplicates-watcher's dismissed-duplicates.json each hand-copy Cache.swift's existing URL/save/load/clear pattern from scratch, one per proposal, one per filename

Three separate documents each reimplement the same roughly 15-20 line 'JSON blob in Application Support/PDF Hammer, atomic write, silent failure' pattern that already exists once, in RunCache. This is exactly the 'parallel machinery that should be one thing' the review is meant to catch, just distributed across research documents instead of within one.

**FIX:** Factor the existing pattern in Cache.swift into one generic pair, `appSupportURL(named:)` (already RunCache's own body, generalized) plus `loadJSON<T: Decodable>(_:from:)` / `saveJSON<T: Encodable>(_:to:)`, and have RunCache and any surviving small store (dismissed duplicates, a spend ledger, a notes file) call that one pair instead of each defining its own four free functions.


## Sequencing

The orchestration premise is stale: Sources/PDFHammer/App.swift no longer exists. It was split, verbatim, by commit 4d6aaea into ContentView.swift, Catalogue.swift, Review.swift, Runner.swift, Reading.swift, Bibliography.swift, and Shell.swift (confirmed against the current tree: no App.swift, and the successor files total the same line count). So there is no single 4900-line file forcing serialization anymore. The real shared hotspot, once the cuts above are applied, is Sources/PDFHammerCore/Hammer.swift (1374 lines): both the surviving rename-patterns work (NamePattern, added directly into Hammer.swift's own 'Name patterns' section, reusing private findDate/tidy/clipped) and the surviving duplicates-watcher work (DuplicateIndex, added directly into Hammer.swift to reuse the private rank/fileDigest/contentKey/duplicateKey helpers) land in the same file's same neighborhood by their own design choice. Those two must be built one after the other, not in parallel, regardless of which goes first. Secondary shared files are ContentView.swift and Runner.swift, touched by the trimmed ai-cost work (aiPanel, identify()/absorbChanges wiring) and by the trimmed duplicates-watcher work (absorbChanges, DuplicateRow) and by layout's arithmetic fixes to Catalogue.swift/Review.swift/ContentView.swift.

Recommended order: (1) layout's repair list first, since it is pure line-level arithmetic with no new types, touches Catalogue.swift/Review.swift/ContentView.swift, and everything else should be rebased on the corrected geometry rather than compounding bugs in it; (2) the small shared-JSON-store helper extraction in Cache.swift (cross-cutting fix above), in its own tiny commit, since whatever survives of ai-cost's spend ledger and duplicates-watcher's dismissal store should build on it rather than duplicate it; (3) rename-patterns and duplicates-watcher's Hammer.swift additions, serialized against each other (order between them doesn't matter functionally, just don't run them concurrently); (4) the trimmed ai-cost feature (AI.swift/Runner.swift/SettingsView.swift/ContentView.swift's aiPanel), which can run in parallel with mcp-spec's legacy-only 6-tool server, since the server is a new executable target that only calls existing pure Core functions and edits nothing rename-patterns or duplicates-watcher touch; (5) mcp-spec last among the substantive work, so its tool wrappers settle against the final shape of Options.pattern (post rename-patterns) rather than needing a second pass. biblio-apis (if built at all, DOI-only) and bibtex-compliance (if anything survives beyond a doc-comment) are single new-file, low-conflict additions that can slot in anywhere. knowledge-graph is cut and has no place in the sequence.


# critique:feasible

## Verdict

Not buildable as eight parallel features against the current tree, and one pair of them cannot both be built as written at all: mcp-spec and knowledge-graph each independently declare `public struct ReadingProject` inside PDFHammerCore with incompatible shapes and storage models, which is a compile-time redeclaration error, not a stylistic overlap, if both land. The framing that constrains this review — 'a 4900-line single-file SwiftUI view' — is also already stale: commit 4d6aaea split App.swift into 9 files before any of these eight designs were written, and I confirmed against the live tree that App.swift no longer exists. That is good news (there is real file-level parallelism available) and bad news (the actual contention is now a specific, identifiable set of files — ContentView.swift, Hammer.swift, Catalogue.swift/Review.swift, and the PDFHammerCore type namespace itself — touched by four, two, two, and two of the eight designs respectively, verified line-by-line against the current checkout). Individually, each design is unusually well-grounded (I spot-checked the single most load-bearing external claim, the 2026-07-28 MCP changelog, and it fetched back verbatim), and the internal Hammer.swift/Cache.swift/Runner.swift/Search.swift citations all check out against the real files with only trivial (1-5 line) drift. But 'eight at once' is not a safe plan: at least one pair is a hard conflict, two more pairs have unaddressed sequencing dependencies that will force rework if built out of order, and one design's entire premise (cross-process UserDefaults visibility) and another's (a strictly-read-only SQLite connection from a second process) are asserted from reasoning, not from a test run on this machine, despite each admitting exactly that in its own risk section.

## Objections


### [fatal] mcp-spec + knowledge-graph: PDFHammerCore type collision

Both designs independently add `public struct ReadingProject` to PDFHammerCore. mcp-spec's version is `Identifiable` via a `UUID`, holds `itemKeys: [String]` and a free-text `note`, and persists as a JSON array at `~/Library/Application Support/PDF Hammer/projects.json`. knowledge-graph's version is `Identifiable` via `Int64`, holds `tagFilter: Query?`, and persists as rows in `projects`/`project_members` tables inside `library.sqlite`. These are not compatible extensions of the same idea — they are two different answers to 'what is a reading project' with different identity types and different backing stores. If both are implemented, PDFHammerCore fails to compile on the redeclaration alone, before any semantic conflict is even reached.

**FIX:** Treat these as one feature decision, not two. Pick knowledge-graph's model (content-hash identity survives file moves/renames, which mcp-spec's own path-keyed `Item.key` does not; it also already has a tag-filter query and an FTS-backed store to resolve membership against). Delete mcp-spec's `Project.swift`/`loadProjects`/`saveProjects` entirely and rewrite mcp-spec tools 6 and 7 (`projects.list`, `projects.create`) to call `Library.createProject`/`Library.resolvedMembers` instead. This also means mcp-spec cannot be finalized before knowledge-graph's `Library` actor exists, at least for those two tools.


### [serious] knowledge-graph: SQLite readonly reader vs. WAL crash recovery

The design opens the MCP server's connection `SQLITE_OPEN_READONLY` specifically to make writer/writer collisions structurally impossible, which is the right call for the stated 'write collision' question. But SQLite's own documented WAL behavior is that a connection opened read-only cannot perform WAL recovery, and recovery is exactly what's needed if the previous writer (the GUI app) did not shut down cleanly — an ad-hoc-signed, actively-developed local app is a realistic candidate for exactly that. The local testing described in the doc (CLI opening the file itself, or a single in-process read/write connection) never exercised the specific failure case of a second process opening the file strictly read-only against a WAL file left in a needs-recovery state. If the GUI ever crashes mid-write, the MCP server — quite plausibly the first thing to touch the file afterward, since asking an agent a question doesn't require relaunching the GUI — will fail to open the database at all until the GUI is relaunched to recover it, with no fallback described.

**FIX:** Either open the MCP connection read-write and immediately issue `PRAGMA query_only = ON` (still structurally prevents writes, but is capable of running recovery on open), or catch the specific SQLite error from a failed readonly open, transiently reopen read-write just long enough for recovery to run, then reopen readonly. Test this by killing the GUI process with SIGKILL mid-write and confirming the MCP server can still open the store afterward.


### [serious] mcp-spec: cross-process UserDefaults(suiteName:) visibility

The entire library-roots/passwords story for 5 of the 8 tools (list_sources, search, bibliography.list, bibliography.export_bibtex, renames.propose all default their `roots` from this read) rests on `UserDefaults(suiteName: "com.jonaprieto.pdfhammer")` returning the same live values the GUI has. I confirmed the GUI never uses that API anywhere — it uses `@AppStorage("sources")`/`@AppStorage("passwords")` (i.e. `UserDefaults.standard`), and `synchronize()` is called nowhere in the codebase. The suite-name trick is a real, generally-working mechanism given no App Group entitlement exists, but 'the same bytes on disk, eventually' is not the same guarantee as 'visible to a concurrently-running second process the instant the user changes it in the GUI' — CFPreferences batches writes, and there is no code anywhere forcing an immediate flush. A tool call that runs moments after the user edits their library folders in the GUI can silently return an empty `sources` list, which looks identical to 'user has no library configured' rather than a timing problem — there is no error path designed for this distinction anywhere in the 8-tool surface.

**FIX:** Before writing any of the ~700-900 lines of JSON-RPC scaffolding, spike this in isolation: launch the GUI, change the sources list, and from a separate standalone Swift executable (not yet the real MCP server) read `UserDefaults(suiteName:)` in a loop to measure actual propagation latency. If it is not near-instant, either have the GUI call `UserDefaults.standard.synchronize()` after every write to `sources`/`passwords` (a one-line, low-risk change to the existing app) or have every MCP tool that depends on it report a warning field alongside an empty result rather than silently returning `{"sources": []}`.


### [serious] Scope framing: the '4900-line single file' premise is stale

The premise handed to me — that Sources/PDFHammer/App.swift is a single 4900-line file all eight features must share — no longer describes the checked-out repository. Commit 4d6aaea deleted App.swift and split it into ContentView.swift (1186 lines), Catalogue.swift (1461), Review.swift (605), Runner.swift (805), Reading.swift (349), Bibliography.swift (255), and Shell.swift (216), plus the pre-existing Converting.swift/SettingsView.swift/Palette.swift/Annotations.swift/FileMenu.swift/Tooltips.swift/AI.swift/Watcher.swift — I verified this directly (`find` for App.swift returns nothing; `wc -l` on the 9 files sums correctly). This changes the real answer to 'can these run in parallel': it is not one file blocking everything, it is a specific, checkable set of collisions — ContentView.swift is edited by four of the eight designs (ai-cost's aiPanel, rename-patterns' namingPanel/AppStorage migration, layout's window-sizing fixes, and duplicates-watcher's structural @StateObject-to-@ObservedObject hoist of runner/covers), and Hammer.swift is edited by two (rename-patterns' large NamePattern addition, duplicates-watcher's DuplicateIndex, both reusing the same private `rank` helper I confirmed at Hammer.swift:882).

**FIX:** Re-run the sequencing decision against the actual 9-file split rather than the assumed monolith — see the sequencing field for the concrete order this implies.


### [serious] duplicates-watcher: ContentView ownership refactor collides with three other designs' line-anchored patches

duplicates-watcher requires changing ContentView's `@StateObject private var runner`/`covers` (verified at ContentView.swift:57-58) to `@ObservedObject let`, hoisting both up to PDFHammerApp — a structural, initializer-changing edit to the exact file that ai-cost (aiPanel, verified at line 573, a 1-line drift from the doc's cited 572), rename-patterns (namingPanel, verified at line 445, plus the AppStorage keys and namingFingerprint), and layout (window minWidth and sizeWindowOnFirstLaunch, verified at lines 246 and 972, a 5-line drift from the doc's cited 977) all also edit. All three of those are written against specific line numbers in the pre-hoist file. Line numbers have already drifted by a handful between when these docs were researched and now — before a single one of the eight designs has been implemented — which means whichever of the four lands last will find its cited lines wrong regardless of build order, and if the hoist lands after the other three, all three need to be re-verified against a file whose property-wrapper types (not just line numbers) changed under them.

**FIX:** Land the ContentView ownership hoist (duplicates-watcher's Part C structural change) by itself, as the very first change touching that file, before any of ai-cost/rename-patterns/layout's ContentView edits are written — then have those three rebase their patches against the post-hoist file rather than the line numbers cited in their own research docs.


### [serious] mcp-spec renames.propose vs. rename-patterns' plan to delete NameRules

mcp-spec's tool 8 inputSchema is specified as 'exact NameRules cases (Hammer.swift:62-83)' — verified, NameRules does have exactly those fields today. But rename-patterns' own design treats NameRules as transitional scaffolding it explicitly plans to delete once NamePattern's migration is complete ('Options.rules and NameRules itself can be deleted in a separate, later commit'). If rename-patterns ships and its cleanup commit lands, mcp-spec's renames.propose tool — inputSchema, dispatch, and its `Options(rules: NameRules(...))` construction — breaks outright. If mcp-spec ships first, it becomes an un-anticipated second consumer of NameRules that rename-patterns' own migration plan never accounts for (its migration section only discusses ContentView's AppStorage keys).

**FIX:** Build rename-patterns' NamePattern/SlugStyle model before mcp-spec's renames.propose tool, and write tool 8's inputSchema against NamePattern/SlugStyle directly rather than against NameRules, so there is exactly one thing to delete later, not two things to keep in sync.


### [minor] duplicates-watcher: notifications, silent permission flip has no ongoing detection

I confirmed the app has no entitlements file anywhere and build.sh signs ad-hoc (`codesign --force --sign -`, no hardened runtime, no notarization step) on every build — exactly what the design's own facts state. The design's mitigation (always populate the in-app Duplicates tab regardless of notification authorization) correctly prevents duplicates from becoming invisible, which is the right call. What is missing: the design only checks `getNotificationSettings` at launch to set an initial `notificationsAvailable` flag; it never compares that against the previously-observed state, so a permission that silently flips from granted to denied between one ad-hoc rebuild and the next (the exact failure mode the design's own risk section flags as plausible, sourced from third-party reports, not Apple docs) produces no signal to the user at all, ever — not even a one-time 'notifications were turned off, re-enable in System Settings' message.

**FIX:** Persist the last-known authorization status (a single UserDefaults bool is enough) and compare it against the current `getNotificationSettings` result at each launch; when it has dropped from authorized to anything else, surface a one-time, dismissable banner rather than staying silent.


### [minor] knowledge-graph: actor boundary is unenforced against the codebase's existing concurrency idiom

The design correctly identifies that `sqlite3_threadsafe()==2` requires a single connection never be touched from two threads at once, and proposes wrapping the connection in `public actor Library` to enforce serialization. But Hammer.swift's existing scanning/hashing pipeline is built entirely around `DispatchQueue.concurrentPerform` (confirmed: `fileDigest`/`duplicateGroups` explicitly parallelize this way today), and the design's own ingest-glue prose tells a future implementer to compute hashes 'off the main thread (parallel, as duplicateGroups already does)' before awaiting into the actor — correct in principle, but nothing in the design stops a future contributor from reaching for the same `concurrentPerform` idiom one level too deep and touching the raw `OpaquePointer` directly from inside one of those parallel closures, which the design itself calls out as 'undefined behavior, not just slow' in its risks section without proposing any enforcement beyond code-review discipline.

**FIX:** Do not expose the raw `OpaquePointer` as an internal (even file-private) property of `Library` at all — keep it as a local inside the actor's methods only, reachable exclusively through `await`. That alone makes the foot-gun this design already worries about a compile error instead of a review-time judgment call.


### [minor] bibtex-compliance + biblio-apis: two independent BibEntry field-extension plans

Both docs propose (as explicitly out-of-scope future work, not built here) additive fields on BibEntry/BibType — bibtex-compliance's BibField enum carries ~25 cases including deliberately-separate classic/biblatex spellings (journal vs. journaltitle), while biblio-apis' NormalizedMetadata is a flatter ~14-field shape with no such spelling distinction. Neither conflicts with the other or with any existing file today since neither is implemented, but whichever of the two (or knowledge-graph's own follow-up, which also touches BibEntry) is implemented first will end up being the de facto schema the other has to conform to, and nothing in either doc names the other as something to reconcile against.

**FIX:** Before implementing either, do a short reconciliation pass that produces one field list, not two, so the second implementation is additive to the first rather than a rework of it.


## Sequencing

Phase 0 (spike only, before writing any real code): empirically verify the two cross-process assumptions the rest of the plan depends on — (a) how quickly a value written via @AppStorage("sources")/@AppStorage("passwords") in the running GUI becomes visible to UserDefaults(suiteName:"com.jonaprieto.pdfhammer") read from a separate freshly-launched process, and (b) whether a strictly SQLITE_OPEN_READONLY connection from a second process can open a WAL database the GUI is actively writing to, and what happens if the GUI was killed uncleanly first. Both are asserted-not-tested in the source docs and gate whether mcp-spec and knowledge-graph's MCP-facing halves work at all. Phase 1 (storage decision, blocking): resolve the ReadingProject collision by choosing knowledge-graph's SQLite Library model over mcp-spec's flat-JSON one, and re-scope mcp-spec's tool surface (especially tools 2, 4-7) to call into Library once it exists rather than re-deriving everything via collectJobs/process on every call — these two designs cannot be implemented independently of each other despite being written as separate research tracks. Phase 2 (fully parallel-safe, new files only, zero edits to existing files): biblio-apis (Metadata.swift) and bibtex-compliance (BibCompliance.swift/BibtexOptions) can be built simultaneously by different people right now, with only a short reconciliation pass between them before either one's BibEntry-field extension actually ships. Phase 3 (Hammer.swift, sequential, one branch at a time): land rename-patterns' NamePattern/SlugStyle/Options.pattern changes first (mcp-spec's renames.propose and duplicates-watcher's DuplicateIndex both need to build on top of whichever naming model wins, and rename-patterns is the one already planning to delete NameRules), then layer duplicates-watcher's DuplicateIndex on top of the same file. Phase 4 (ContentView.swift, alone, first): land duplicates-watcher's @StateObject-to-@ObservedObject hoist of runner/covers into PDFHammerApp by itself, touching nothing else in that file in the same change, specifically because ai-cost, rename-patterns, and layout each have their own pending edits to ContentView.swift that are currently line-anchored against the pre-hoist file and will need rebasing regardless of order — doing the hoist first means they only rebase once. Phase 5: layout's Catalogue.swift/Review.swift arithmetic fixes (items 1-2 especially, since they touch the same `split` function duplicates-watcher's new DuplicateReviewView will eventually sit beside), then duplicates-watcher's review-window UI once Phase 4's hoist exists for it to consume. Phase 6 (any time after Phase 4, low collision risk): ai-cost's Runner.swift/AI.swift/SettingsView.swift/ContentView.swift wiring. Phase 7 (its own long-running branch, gated on Phase 0 and Phase 1, and the single item most worth building in total isolation): mcp-spec's PDFHammerMCP executable target — a ~700-900 line hand-rolled dual-era JSON-RPC server with no SDK to check it against and no compiler check for protocol-negotiation correctness, whose only real verification is live traffic from Claude Code and Codex; it should not be started until Phase 0's UserDefaults spike and Phase 1's storage decision are both settled, since roughly half its tool surface depends on one and its projects tools depend entirely on the other.


# critique:correctness

## Verdict

Individually, most of these documents are careful and well-sourced — the SQLite/WAL choice, the Decimal-based cost math, the dual-era MCP handshake, and the arithmetic layout fixes are all sound. But as a combined design, it is not safe to build as literally specified. The flagship idea that content-hash equals document identity is undermined by the app's own core decrypt-and-rename feature in a way the proposed supersede heuristic never catches, and even where the heuristic could fire, no concrete API actually migrates the dependent rows while cascading foreign keys stand ready to erase them for good. Two of the documents independently invent an incompatible ReadingProject type and storage model for the same concept, one of them keyed by exactly the kind of path identity the other document explains is unsafe. A new incremental duplicate index goes stale on the single most ordinary user action in the app. The spend ledger can silently blend currencies and silently drop the very calls most likely to signal wasted money. Three separate new features each reach for an unlocked whole-file JSON overwrite for state that either needs real cross-process locking or belongs in the SQLite store already justified elsewhere in the same design set. And a real, currently-shipping data-loss bug in the rename path — remove-then-move instead of write-then-swap — is inherited silently by every new feature that renames a file. None of this is unfixable, but each item needs a decision and a code change before implementation starts, not a discovery made after users' libraries are already touched.

## Objections


### [fatal] knowledge-graph: content-hash identity vs. decrypt+rename (the app's own core feature)

The design's only defense against a changed content_hash orphaning a document's tags/notes/marks is a 'supersede' heuristic that fires on 'same path, new hash.' But the app's flagship operation — decrypt-and-rename via process(job:options:) — changes the path AND the hash in the same step (Hammer.swift:1298-1316, and the backup branch at 1266-1294): the encrypted original moves to a backup/whatever path, and decryptedCopy() rebuilds an entirely new PDFDocument byte-for-byte (Hammer.swift:1027-1041) at a new, renamed destination. 'Same path' never holds, so the heuristic never triggers for exactly the case it most needs to cover. Any tags, notes, marks, or reading-project membership a user attached to a locked PDF before running PDF Hammer's normal unlock-and-rename feature on it silently vanish the next time the library is re-ingested — with no error, no warning, nothing.

**FIX:** Don't key the supersede decision on path equality. Have the app's own move/decrypt code (moveFile/process in Hammer.swift) report an explicit (oldKey, newKey) pairing at the moment it performs the operation, and have ingest consult that operation log instead of reverse-engineering identity from 'did the path stay the same.' Absent that, at minimum widen the heuristic to match on (old page_count/title/author) regardless of path, since decrypting never changes those.


### [serious] knowledge-graph: Library API surface has no supersede/migration method, and every child table cascade-deletes

The schema adds documents.superseded_by, but the concrete Library actor API (upsertDocument, setMarkdown, addTag, replaceMarks, addNote, createProject, addMember, ...) never includes a method that actually reassigns tags/document_notes/project_members/marks from an old content_hash to a new one. Every one of those tables is declared with `ON DELETE CASCADE` on content_hash. 'Carry tags/project-membership/document_notes forward' is prose intent in the design's own risk section, not a real code path — so the moment anything (a future cleanup pass, a manual DELETE) removes a superseded row, its entire annotation/tag/project history is destroyed permanently and irreversibly, with the schema itself providing the mechanism.

**FIX:** Add Library.supersede(from oldHash: String, to newHash: String) that runs the FK reassignment as one transaction before the old row can ever be deleted, and never delete a superseded documents row automatically — only ever mark it, so the migration path this design promises actually exists in code, not just in a comment.


### [serious] mcp-spec vs. knowledge-graph: two incompatible ReadingProject designs

mcp-spec proposes `public struct ReadingProject` in a new Sources/PDFHammerCore/Project.swift, keyed by a UUID id and `itemKeys: [String]` (Item.key, i.e. resolved filesystem paths), persisted as a flat projects.json. knowledge-graph separately proposes `public struct ReadingProject` in Library.swift, keyed by an Int64 rowid with a `tagFilter: Query?`, persisted in SQLite. Both are `public` types in the same PDFHammerCore module with the same name and incompatible shapes — a straight compile collision if both are implemented as written, and two competing sources of truth for 'what a reading project is' if one is renamed to dodge the collision.

**FIX:** Pick one identity/storage model for reading projects before either lands. Given knowledge-graph's SQLite/WAL store already solves the cross-process-safety problem mcp-spec explicitly needs, build mcp-spec's projects.create/projects.list directly against Library.createProject/addMember instead of inventing Project.swift/projects.json.


### [serious] mcp-spec: ReadingProject.itemKeys is path-keyed, so it goes out of sync with the filesystem by design

itemKeys is populated from `paths.map { URL(...).resolvingSymlinksInPath().path }`, matching Item.key exactly — a resolved absolute path. Hammer.swift:527's own doc comment already frames this as fragile ('a moved or renamed file gets a different key'). The moment the user runs PDF Hammer's own core renaming feature on a file that is a member of a reading project, that file's path changes and it silently, permanently drops out of the project — no error surfaces anywhere, nothing tells the user their project just lost a document. This is exactly 'a store that could go out of sync with the filesystem,' triggered by the app's single most routine action.

**FIX:** Never key project membership by path. If content-hash identity (knowledge-graph) isn't ready yet, at minimum re-resolve membership at read time by matching current library items back to a stored (filename, byte-size, page-count) fingerprint rather than an exact path string, so a rename doesn't silently evict a member.


### [serious] duplicates-watcher: DuplicateIndex goes stale on Runner.applyNow, an existing everyday action

The design only seeds/updates DuplicateIndex from preview()/showCached()/absorbChanges(). But Runner.applyNow (Runner.swift:262-269) — the existing 'carry out one file right now' inline path used by ordinary single-file rename/decrypt — also mutates `results` via replace(_:with:) (Runner.swift:273-286), and is not one of the three audited call sites. Because Item is a value type, DuplicateIndex's stored copy of that item is an independent snapshot from insert time: after an inline apply, the index still carries the file's OLD byteCount/hash (risking a false match against some unrelated future file of that old size) and never indexes the NEW bytes actually on disk (so a genuine duplicate of the freshly renamed/decrypted file goes undetected). The design's own risk list admits DuplicateIndex 'wasn't audited beyond the three call sites identified' — applyNow is the fourth, and it is one of the most common actions in the app.

**FIX:** Route Runner.applyNow's replace(_:with:) through DuplicateIndex.remove(oldKey) followed by .insert(newItem), the same as the watcher path already does.


### [serious] ai-cost: spend ledger has no currency field

ModelPrice/SpendEntry model every rate and every stored cost as a bare Decimal literally named costUSD, with no currency unit anywhere. The design explicitly supports 'arbitrary OpenAI-compatible endpoints' via user-entered `custom` prices for any (baseURL, model) pair. A user who points baseURL at a non-USD-billed provider and types in that provider's own rate will have that number silently folded into costUSD and summed into sessionTotals/allTimeTotals as if it were dollars — exactly the 'quietly reporting wrong numbers' failure the review brief calls out for money.

**FIX:** Add a currency (ISO 4217) field to ModelPrice and SpendEntry; never sum Decimal costs across differing currencies into one total, group and display per-currency instead.


### [serious] ai-cost: real spend is dropped exactly when a call goes wrong

The design's own IdentifyResult bundles usage together with the parsed BookGuess in one return value. AI.swift:149-153's current identify() throws AIError.unreadable when a 2xx response's content doesn't parse into valid JSON/title — a case where the provider already billed real prompt+completion tokens. Because usage only ever reaches the caller alongside a successfully parsed guess, that thrown path discards the usage entirely, and per the design's own Runner integration ('after a successful call... append it to the ledger'), no SpendEntry is ever created. The one failure mode most likely to indicate something is actually burning money — a broken custom endpoint, a model returning garbage on every call — is invisible to both session and all-time totals.

**FIX:** Parse and attach TokenUsage to the result before the JSON/title validation can throw, so a SpendEntry (with cost computed if a price is known) is recorded regardless of whether the reply content itself was usable.


### [serious] Concurrency: three unlocked whole-file JSON stores under concurrent writers

dismissed-duplicates.json (duplicates-watcher), spend-ledger.json (ai-cost), and projects.json (mcp-spec) are each read once into memory, mutated, and blind-overwritten on save, with no locking across the read-modify-write cycle (atomic *file* writes don't protect against two writers racing the *cycle*). PDF Hammer.app has no LSMultipleInstancesProhibited entry (checked in Resources/Info.plist), so nothing stops two GUI processes running concurrently, and mcp-spec explicitly configures both Claude Code and Codex CLI as clients of the same PDFHammerMCP binary — meaning two independent MCP server processes can call projects.create around the same time. Any such race silently loses one side's write: a dismissed duplicate can resurface, a created reading project can vanish, and a completed AI call's cost can disappear from the permanent ledger — the same 'lost write' bug in three different new files.

**FIX:** Don't add three more unlocked JSON files. knowledge-graph's SQLite/WAL library was already justified for exactly this cross-process problem — put dismissed-duplicate ids, spend entries, and projects into it as tables instead, or at minimum wrap each existing JSON store's load-mutate-save cycle in a real file lock (flock).


### [fatal] Existing rename path (Hammer.swift:1296-1313), inherited by every new design that renames files

In process(job:options:)'s no-backup decrypt branch, the code calls fm.removeItem(at: source) and only then fm.moveItem(at: temp, to: destination). If the move throws after the remove already succeeded, the function returns an Item with status .failed and the raw error string — but the original file is already gone, and its only surviving copy is an orphaned, hidden dotfile (.pdfhammer-<uuid>.pdf) that the failure message never names, that nothing cleans up, and that a user would never find in Finder. rename-patterns' NamePattern renderer, duplicates-watcher's incremental scanning, and mcp-spec's renames.propose (a preview today, but the documented precursor to a future apply tool) all funnel through this exact function without addressing it — this is a live, load-bearing, un-flagged data-loss bug in the one operation the brief specifically asks to be checked for irreversibility.

**FIX:** Reorder to write-then-swap instead of remove-then-move: write the decrypted copy to temp, then use FileManager.replaceItemAt(source, withItemAt: temp) to atomically become the new file at the original path (or destination), exactly the pattern Annotations.swift:254-255 already uses correctly for note-saving. A failed swap then always leaves the original untouched.


### [serious] Privacy: knowledge-graph's reading-project 'ask' vs. today's excerpt-only AI usage

Today the only AI call in the app (identify()) sends at most ~1800 characters from the first 3 pages of one file, only when the user explicitly asks to identify it. selectExcerpts/readingProjectPrompt can, in 'full recall' mode, send the entire extracted Markdown of every document in a reading project (every chunk, not just excerpts, whenever the project fits the character budget) to whatever baseURL is configured — which the app explicitly allows to be any OpenAI-compatible endpoint the user typed in, with no scheme check anywhere in AI.swift (a plain http:// endpoint is accepted exactly like https://). The design reuses AI.swift's existing request plumbing outright and adds no distinct disclosure step before this much larger payload leaves the machine.

**FIX:** Add an explicit, visible confirmation before a reading-project question is sent — naming the destination endpoint and roughly how much content (character count, document count) is about to leave the machine — and treat any baseURL other than the trusted https://api.openai.com/v1 default as warranting extra confirmation now that full document bodies, not three-page excerpts, are on the line.


### [minor] duplicates-watcher: 'Trash the other(s)' in the new review window only queues, then closes

DuplicateReviewView's Trash button calls trashExtras(of:) — identical to the existing Catalogue tab's button — which only records a `.deleted` decision; the file is not moved to Trash until the user separately finds and clicks Apply in the main window. The new design immediately calls dismiss() right after, closing the entire popup as if the action were complete. Reached via a clicked OS notification, a user can work through several duplicate pairs believing each 'Trash the other' click already reclaimed space, while nothing on disk has changed and this narrow standalone window carries none of the persistent pending-count/Apply affordance the main catalogue view has. Runner already has a distinct 'do this one file right now' pattern (applyNow) built for exactly this single-decision situation, and this design reaches for the batch-queue pattern instead.

**FIX:** Either have this window's Trash button apply immediately (mirroring applyNow's moveToTrash(dryRun:false) call) so the label matches the actual effect, or keep it queued but replace the bare dismiss() with a visible 'queued — N changes pending, Apply from the main window' state.


## Sequencing

The premise in the prompt is stale: Sources/PDFHammer/App.swift no longer exists. Commit 4d6aaea (already in the repo's history) split it into 9 files — ContentView.swift, Catalogue.swift, Review.swift, Runner.swift, Reading.swift, Bibliography.swift, Shell.swift, plus the untouched Converting.swift/SettingsView.swift/Palette.swift/Annotations.swift/FileMenu.swift/Tooltips.swift/AI.swift/Watcher.swift. The real contention is a handful of shared hot spots across those files (ContentView.swift's @StateObject ownership and window layout, Catalogue.swift's split()/catalogueColumns(), Hammer.swift's Options/Item/process()), plus the choice of persistence layer for anything new and stateful. Given that: (1) land `layout`'s pure arithmetic fixes to Catalogue.swift/ContentView.swift first — no dependents, and it fixes the exact functions (`split`, `catalogueColumns`) that duplicates-watcher's Part A/C also rewrite, so later edits aren't compounding a live bug or diverging on what 'reserved width' should mean. (2) Resolve and land knowledge-graph's SQLite/Library foundation next — with the identity/supersede fixes from the objections above — before building anything else that needs durable, cross-process-safe state: mcp-spec's projects.create/projects.list should be built directly against this Library rather than its own Project.swift/projects.json, and ai-cost's spend ledger plus duplicates-watcher's dismissed-duplicate set should become tables in the same database rather than two more unlocked JSON files. (3) Land rename-patterns' NamePattern/Options.pattern change to Hammer.swift before finalizing mcp-spec's renames.propose input schema, since that schema currently encodes NameRules directly and would need an immediate breaking revision once NamePattern exists. (4) mcp-spec's six read-only tools (list_sources, search, read_markdown, bibliography.list/export_bibtex) depend on none of the above and can ship independently at any point; only its two projects.* tools and its renames.propose schema are gated on steps 2-3. (5) ai-cost's AIClient.identify signature change and its Runner/SettingsView call-site updates can land any time; only its choice of persistence store depends on step 2. (6) duplicates-watcher's Part C — hoisting Runner/Covers from ContentView to the App level, by far the largest structural edit to ContentView.swift of any of these designs — should land last among the UI changes, after layout (1) and after rename-patterns' naming-panel edits to the same file, and only once its DuplicateIndex is fixed to also update on Runner.applyNow (see objections), so the hoist isn't rebasing across two other concurrent edits to the same section of the same file.
