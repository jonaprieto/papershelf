# PaperShelf MCP for researchers, implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the PaperShelf MCP server into something a researcher can use from the ChatGPT desktop app without knowing a single file path: search the whole library with quotable excerpts and real page numbers, read and cite by document id, file findings into projects, and rename files behind an off-by-default gate.

**Architecture:** The index is fixed first, because everything else reads it. The bulk indexer switches to page-marked Markdown and a `format` column marks rows written by the old producer as stale so they are re-read once. Then a pure excerpt/page-attribution function lands in Core with tests. Then the MCP server's twelve tools are deepened to make `folder` optional and accept document ids, and four write tools are added. The server stays a hand-rolled JSON-RPC-over-stdio process with a read-only SQLite connection for reads and a second read-write `Library` actor for writes.

**Tech Stack:** Swift 6 toolchain in language mode v5, SwiftPM, XCTest, Foundation, PDFKit, SQLite3 (system), CryptoKit (system), AppKit/SwiftUI for the one settings toggle.

**Spec:** `docs/superpowers/specs/2026-08-31-mcp-for-researchers-design.md`

## Global Constraints

- No third-party dependencies. `README.md:6` states "Built on PDFKit and SwiftUI. No third-party dependencies." Everything here uses Foundation, PDFKit, SQLite3, CryptoKit, AppKit or SwiftUI, all system frameworks.
- Platform floor `macOS(.v14)`, Swift tools version 6.0, every target `swiftSettings: [.swiftLanguageMode(.v5)]` (`Package.swift`).
- Nothing but JSON-RPC ever goes to stdout in `Sources/PaperShelfMCP`. Diagnostics go through `note(_:)`, which writes to stderr. A stray `print` corrupts the stream.
- No emoji and no em-dashes anywhere: source, comments, commit messages, Markdown written into the repo. Use a comma, a colon, a semicolon, or two sentences.
- Commit messages follow the repo's existing style: a Conventional Commits prefix and then a plain descriptive clause, for example `feat: the marks on a paper show without opening it`. No AI-attribution trailers of any kind.
- All commits must be signed. Never pass `--no-gpg-sign`. Verify with `git log --format='%H %G?' -1`, which must print `G` or `Y`.
- A password is never placed in any tool result, error message, structured content, or stderr line.
- The stored text format string is exactly `"markdown-v1"`, or `"markdown-v1-clipped"` when the cap was hit. These two literals appear in Core, in the app indexer, in the MCP server, and in `Tools/mcp-check.sh`.

---

## File Structure

**Created:**
- `Sources/PaperShelfCore/Excerpt.swift` — page attribution and excerpt extraction over page-marked Markdown. Pure, no I/O.
- `Sources/PaperShelfMCP/Prefs.swift` — the server's read of the app's `UserDefaults` suite: passwords, the file-operations gate, the text cap.
- `Sources/PaperShelfMCP/Writes.swift` — the read-write `Library` connection and the synchronous bridge into the actor.
- `Sources/PaperShelfMCP/Plan.swift` — the rename plan: build, hash, persist, re-verify.
- `Sources/PaperShelfMCP/LibraryTools.swift` — the tools backed by the indexed library (moved out of `Tools.swift`, which would otherwise pass 900 lines).
- `Sources/PaperShelfMCP/WriteTools.swift` — `add_to_project`, `set_tags`, `propose_file_changes`, `apply_file_changes`.
- `Tests/PaperShelfCoreTests/ExcerptTests.swift`
- `Tests/PaperShelfAppTests/IndexProducerTests.swift`

**Modified:**
- `Sources/PaperShelfCore/TextIndex.swift` — `indexedMarkdown` replaces `documentText`; the cap rises; `TextFormat` and a `needsIndexing` overload.
- `Sources/PaperShelfCore/Library.swift` — `schemaV7`, `format` on `extracted_text`, format written and read.
- `Sources/PaperShelfCore/Support.swift` — one version constant.
- `Sources/PaperShelf/TextIndexing.swift` — the bulk indexer's producer.
- `Sources/PaperShelf/ProjectsLive.swift`, `Sources/PaperShelf/LibrarySync.swift` — pass the format through.
- `Sources/PaperShelf/Prefs.swift`, `Sources/PaperShelf/SettingsWindow.swift` — the file-operations toggle.
- `Sources/PaperShelfMCP/Projects.swift` — `LibraryReader` grows library-wide reads.
- `Sources/PaperShelfMCP/Tools.swift` — the folder and document tools, deepened.
- `Sources/PaperShelfMCP/main.swift` — tool list, version, `--version`.
- `Tests/PaperShelfCoreTests/TextIndexTests.swift` — moved onto `indexedMarkdown`.
- `Tools/mcp-check.sh`, `Tools/mcp-check.py` — new cases.
- `Plugin/papershelf/.codex-plugin/plugin.json`, `README.md`.

---

### Task 1: `indexedMarkdown` in Core

The bulk indexer's producer changes in Task 3, but the function it will call has to exist and keep `documentText`'s contract first: nil when the file will not open or stays locked, `""` when it opened and has no text layer. `markdownFromPDF` returns `"# Title\n\n"` in all three cases, which would store a locked book as successfully indexed and never retry it.

**Files:**
- Modify: `Sources/PaperShelfCore/TextIndex.swift`
- Test: `Tests/PaperShelfCoreTests/TextIndexTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public enum TextFormat: String, Sendable, Equatable { case markdown = "markdown-v1"; case clipped = "markdown-v1-clipped" }`
  - `public func indexedMarkdown(of url: URL, passwords: [String], limit: Int = textIndexCharacterLimit) -> (text: String, format: TextFormat)?`
  - `public let textIndexCharacterLimit = 2_000_000`
  - `public func needsIndexing(extractedAt: Date?, fileModified: Date?, format: TextFormat?) -> Bool`

- [ ] **Step 1: Write the failing tests**

Replace the whole of `Tests/PaperShelfCoreTests/TextIndexTests.swift` with:

```swift
import XCTest
@testable import PaperShelfCore

final class TextIndexTests: XCTestCase {
    private func scratch(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName(name), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testTextIsReadFromTheWholeDocumentUpToTheCap() throws {
        let directory = try scratch("text-index")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("paper.pdf")
        try makeTextPDF(at: file, text: "Stochastic epidemic models")

        let read = try XCTUnwrap(indexedMarkdown(of: file, passwords: []))
        XCTAssertTrue(read.text.contains("Stochastic epidemic"))
        XCTAssertEqual(read.format, .markdown)

        // Every page the reader saw is announced, so a later search can say which one a
        // match came from.
        XCTAssertTrue(read.text.contains("## Page 1"))

        // The cap is a character count, not a page count, and hitting it is recorded
        // rather than left for a caller to guess at.
        let clipped = try XCTUnwrap(indexedMarkdown(of: file, passwords: [], limit: 6))
        XCTAssertEqual(clipped.text.count, 6)
        XCTAssertEqual(clipped.format, .clipped)
    }

    /// Two different answers that must not be confused: a file that cannot be opened is
    /// worth trying again when the disk comes back, a scan with no text layer is not.
    func testUnreadableIsNilAndATextlessDocumentIsEmpty() throws {
        let directory = try scratch("text-index-empty")
        defer { try? FileManager.default.removeItem(at: directory) }
        let blank = directory.appendingPathComponent("blank.pdf")
        try makePDF(at: blank, password: nil)

        let read = try XCTUnwrap(indexedMarkdown(of: blank, passwords: []))
        XCTAssertEqual(read.text, "", "a scan has no text, and that is a permanent answer")
        XCTAssertEqual(read.format, .markdown)
        XCTAssertNil(indexedMarkdown(of: directory.appendingPathComponent("gone.pdf"),
                                     passwords: []))
    }

    func testALockedDocumentNoPasswordOpensIsNotIndexed() throws {
        let directory = try scratch("text-index-locked")
        defer { try? FileManager.default.removeItem(at: directory) }
        let locked = directory.appendingPathComponent("locked.pdf")
        try makePDF(at: locked, password: "secret")

        XCTAssertNil(indexedMarkdown(of: locked, passwords: []), "no password, no text")
        XCTAssertNotNil(indexedMarkdown(of: locked, passwords: ["secret"]))
    }

    func testWhatHasToBeReadAgain() {
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)

        XCTAssertTrue(needsIndexing(extractedAt: nil, fileModified: late), "never read")
        XCTAssertTrue(needsIndexing(extractedAt: early, fileModified: late),
                      "the file changed after its text was read")
        XCTAssertFalse(needsIndexing(extractedAt: late, fileModified: early))
        XCTAssertFalse(needsIndexing(extractedAt: late, fileModified: nil),
                       "a missing date is not a reason to read every file again")
    }

    /// Text stored before page markers existed carries no format, and no file date will
    /// ever make it stale on its own, so the format is what asks for it to be read again.
    func testTextWithoutAFormatIsAlwaysStale() {
        let late = Date(timeIntervalSince1970: 2_000)
        let early = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(needsIndexing(extractedAt: late, fileModified: early, format: nil))
        XCTAssertFalse(needsIndexing(extractedAt: late, fileModified: early, format: .markdown))
        XCTAssertFalse(needsIndexing(extractedAt: late, fileModified: early, format: .clipped),
                       "clipped is as read as it is going to get, not unread")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TextIndexTests 2>&1 | tail -20`
Expected: FAIL, `cannot find 'indexedMarkdown' in scope`.

- [ ] **Step 3: Write the implementation**

In `Sources/PaperShelfCore/TextIndex.swift`, change the cap and replace `documentText` with `indexedMarkdown`, keeping `needsIndexing` where it is and adding the overload:

```swift
/// The cap is deliberate. A library of fourteen thousand books with no bound on stored
/// text is tens of gigabytes of SQLite, and a five-thousand-page scan would be a
/// single row of it. Two million characters is a whole book for anything real: a
/// four-hundred-page book is about eight hundred thousand.
public let textIndexCharacterLimit = 2_000_000

/// What shape a stored row is in. Absent, on a row written before this existed, means
/// text with no page markers and a far lower cap, which is stale by definition.
public enum TextFormat: String, Sendable, Equatable {
    case markdown = "markdown-v1"
    case clipped = "markdown-v1-clipped"
}

/// The document's text as page-marked Markdown, up to the cap.
///
/// Nil means the file could not be opened, or is locked and no password given fits, which
/// is worth trying again when the disk or the password comes back. An empty string means
/// the document opened and has no text layer, which is a scan: a normal, permanent answer
/// that should be stored so the file is not read again on every launch. That pair of
/// answers is the reason this is not `markdownFromPDF`, which returns its title heading
/// and nothing else in both cases and cannot be told apart.
///
/// No title heading, no paragraph joining and no Markdown escaping either, unlike
/// `markdownFromPDF`: this text exists to be matched against and quoted from, and escaping
/// changes the characters a quote would be taken from. The page markers are the one piece
/// of structure worth adding, because they are the only way a search result can say which
/// page it found something on.
public func indexedMarkdown(of url: URL, passwords: [String],
                            limit: Int = textIndexCharacterLimit) -> (text: String, format: TextFormat)? {
    guard let document = PDFDocument(url: url) else { return nil }
    if document.isLocked {
        for password in passwords where document.unlock(withPassword: password) { break }
    }
    guard !document.isLocked else { return nil }
    var collected = ""
    collected.reserveCapacity(min(limit, 1 << 16))
    for index in 0..<document.pageCount {
        guard let text = document.page(at: index)?.string, !text.isEmpty else { continue }
        collected += "## Page \(index + 1)\n\n"
        collected += text
        collected += "\n\n"
        if collected.count >= limit {
            return (String(collected.prefix(limit)), .clipped)
        }
    }
    return (collected, .markdown)
}

/// As `needsIndexing(extractedAt:fileModified:)`, plus the one thing a file date cannot
/// answer: text stored by a producer that predates page markers is stale however recently
/// it was written.
public func needsIndexing(extractedAt: Date?, fileModified: Date?, format: TextFormat?) -> Bool {
    guard format != nil else { return true }
    return needsIndexing(extractedAt: extractedAt, fileModified: fileModified)
}
```

Delete the old `documentText` function entirely. `needsIndexing(extractedAt:fileModified:)` at line 59 stays exactly as it is.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TextIndexTests 2>&1 | tail -20`
Expected: PASS, 5 tests.

Then check nothing else called the old function:

Run: `grep -rn "documentText" Sources/ Tests/ | grep -v storeAsDocumentText`
Expected: one line only, `Sources/PaperShelf/TextIndexing.swift:90`. That call is fixed in Task 3 and the build is expected to be red until then, which is why this task does not run a full `swift build`.

- [ ] **Step 5: Commit**

```bash
git add Sources/PaperShelfCore/TextIndex.swift Tests/PaperShelfCoreTests/TextIndexTests.swift
git commit -m "feat: indexed text says which page it came from"
```

---

### Task 2: The `format` column

`needsIndexing` can only ask about a format if the format is stored. This adds the column, writes it, and reads it back, with nothing yet changing about what gets written into `markdown`.

**Files:**
- Modify: `Sources/PaperShelfCore/Library.swift`
- Modify: `Sources/PaperShelf/ProjectsLive.swift:85`, `Sources/PaperShelf/LibrarySync.swift:252`
- Test: `Tests/PaperShelfCoreTests/LibraryTests.swift`

**Interfaces:**
- Consumes: `TextFormat` from Task 1.
- Produces:
  - `Library.setExtractedText(_ markdown: String, forDocument documentID: String, format: TextFormat, extractedAt: Date = Date()) throws`
  - `Library.setExtractedText(_ batch: [(documentID: String, markdown: String, format: TextFormat)], extractedAt: Date = Date()) throws`
  - `TextIndexRow.format: TextFormat?`
  - `Library.ExtractedText.format: TextFormat?`

- [ ] **Step 1: Write the failing test**

Append to `Tests/PaperShelfCoreTests/LibraryTests.swift`, inside the existing test class (match the file's own helper for making a scratch library, which every other test in it already uses):

```swift
    func testStoredTextRemembersWhatShapeItIsIn() async throws {
        let library = try await scratchLibrary()
        _ = try await library.indexDocuments([Library.IndexInput(path: "/tmp/a.pdf")])
        let id = try await XCTUnwrapAsync(library.document(atPath: "/tmp/a.pdf")).id

        try await library.setExtractedText("## Page 1\n\nhello", forDocument: id, format: .markdown)
        let stored = try await XCTUnwrapAsync(library.extractedText(forDocument: id))
        XCTAssertEqual(stored.format, .markdown)

        let rows = try await library.textIndexRows()
        XCTAssertEqual(rows.first(where: { $0.path == "/tmp/a.pdf" })?.format, .markdown)
    }

    /// A row written before the column existed reads back as nil, which is what makes it
    /// stale to `needsIndexing`. Written straight through SQL because no accessor can
    /// produce a formatless row any more.
    func testTextStoredBeforeTheColumnExistedHasNoFormat() async throws {
        let library = try await scratchLibrary()
        _ = try await library.indexDocuments([Library.IndexInput(path: "/tmp/b.pdf")])
        let id = try await XCTUnwrapAsync(library.document(atPath: "/tmp/b.pdf")).id
        try await library.setExtractedText("older text", forDocument: id, format: .markdown)
        try await library.clearFormatForTesting(documentID: id)

        let stored = try await XCTUnwrapAsync(library.extractedText(forDocument: id))
        XCTAssertNil(stored.format)
        XCTAssertTrue(needsIndexing(extractedAt: stored.extractedAt, fileModified: nil,
                                    format: stored.format))
    }
```

If `scratchLibrary()` and `XCTUnwrapAsync` are not already helpers in `LibraryTests.swift`, use whatever that file already does to build a library and unwrap an async optional; read the top of the file first and match it rather than adding new helpers.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter LibraryTests/testStoredTextRemembersWhatShapeItIsIn 2>&1 | tail -20`
Expected: FAIL, no `format` argument.

- [ ] **Step 3: Write the implementation**

In `Sources/PaperShelfCore/Library.swift`, add the migration. It is the seventh, so it goes at the end of the list:

```swift
    fileprivate static let migrations: [String] = [schemaV1, schemaV2, schemaV3, schemaV4,
                                                   schemaV5, schemaV6, schemaV7]
```

and beside the other schema strings:

```swift
    /// Which producer wrote a row's text, so text stored before page markers existed can be
    /// found and read again. Nullable and unbacked by a default on purpose: null is exactly
    /// the population that has to be re-read, and a default would hide it.
    ///
    /// `extracted_text_fts` is an external-content table over `markdown` alone, so adding a
    /// column beside it changes nothing about the index or its triggers.
    fileprivate static let schemaV7 = """
        ALTER TABLE extracted_text ADD COLUMN format TEXT;
        """
```

Change both `setExtractedText` overloads to carry the format:

```swift
    public func setExtractedText(_ markdown: String, forDocument documentID: String,
                                 format: TextFormat, extractedAt: Date = Date()) throws {
        try run("""
            INSERT INTO extracted_text(document_id, markdown, extracted_at, format) VALUES (?, ?, ?, ?)
            ON CONFLICT(document_id) DO UPDATE SET markdown = excluded.markdown,
                extracted_at = excluded.extracted_at, format = excluded.format;
            """) { statement in
            bindText(statement, 1, documentID)
            bindText(statement, 2, markdown)
            bindText(statement, 3, Library.isoString(extractedAt))
            bindText(statement, 4, format.rawValue)
        }
    }

    public func setExtractedText(_ batch: [(documentID: String, markdown: String, format: TextFormat)],
                                 extractedAt: Date = Date()) throws {
        guard !batch.isEmpty else { return }
        try execute("BEGIN IMMEDIATE;")
        do {
            for entry in batch {
                try setExtractedText(entry.markdown, forDocument: entry.documentID,
                                     format: entry.format, extractedAt: extractedAt)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }
```

Read it back in `textIndexRows`:

```swift
    public func textIndexRows() throws -> [TextIndexRow] {
        try withStatement("""
            SELECT l.path, l.document_id, e.extracted_at, e.format
            FROM locations l
            LEFT JOIN extracted_text e ON e.document_id = l.document_id;
            """) { statement in
            var rows: [TextIndexRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let path = columnText(statement, 0),
                      let id = columnText(statement, 1) else { continue }
                rows.append(TextIndexRow(path: path, documentID: id,
                                         extractedAt: columnText(statement, 2)
                                            .flatMap(Library.isoDate),
                                         format: columnText(statement, 3)
                                            .flatMap(TextFormat.init(rawValue:))))
            }
            return rows
        }
    }
```

Add `format` to `extractedText(forDocument:)` and to `extractedText(forDocuments:)` the same way: select `format` and map it through `TextFormat.init(rawValue:)`.

Add the fields to the two structs. `TextIndexRow` lives in `Sources/PaperShelfCore/TextIndex.swift`:

```swift
public struct TextIndexRow: Sendable, Equatable {
    public var path: String
    public var documentID: String
    public var extractedAt: Date?
    /// Nil for text stored before page markers existed, which is what makes it stale.
    public var format: TextFormat?

    public init(path: String, documentID: String, extractedAt: Date?, format: TextFormat? = nil) {
        self.path = path
        self.documentID = documentID
        self.extractedAt = extractedAt
        self.format = format
    }
}
```

Keep whatever fields and initialiser `TextIndexRow` already declares; this shows the shape after adding `format`, not a replacement for fields it already has. Do the same for `Library.ExtractedText`, adding `public var format: TextFormat?`.

Add the test-only helper next to the other accessors, marked plainly for what it is:

```swift
    /// Blanks the format of one row, so a test can produce the pre-column state that no
    /// accessor can write any more. Nothing in the app calls this.
    public func clearFormatForTesting(documentID: String) throws {
        try run("UPDATE extracted_text SET format = NULL WHERE document_id = ?;") { statement in
            bindText(statement, 1, documentID)
        }
    }
```

Fix the two app call sites so the project builds. `Sources/PaperShelf/ProjectsLive.swift:85` and `Sources/PaperShelf/LibrarySync.swift:252` both store the output of the engine-choosing converter, which is complete and page-marked, so both pass `.markdown`:

```swift
// ProjectsLive.swift:85
try await library.setExtractedText(read.map { ($0.documentID, $0.markdown, TextFormat.markdown) })
```

```swift
// LibrarySync.swift:252
return ((try? await library.setExtractedText(markdown, forDocument: document.id,
                                             format: .markdown)) != nil)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter LibraryTests 2>&1 | tail -20`
Expected: PASS. The whole existing `LibraryTests` suite must still pass; the migration runs against every scratch library those tests build.

- [ ] **Step 5: Commit**

```bash
git add Sources/PaperShelfCore/Library.swift Sources/PaperShelfCore/TextIndex.swift \
        Sources/PaperShelf/ProjectsLive.swift Sources/PaperShelf/LibrarySync.swift \
        Tests/PaperShelfCoreTests/LibraryTests.swift
git commit -m "feat: the library remembers which reader wrote a document's text"
```

---

### Task 3: The bulk indexer stores page-marked text

**Files:**
- Modify: `Sources/PaperShelf/TextIndexing.swift:35-37`, `:81-101`
- Test: `Tests/PaperShelfAppTests/IndexProducerTests.swift` (create)

**Interfaces:**
- Consumes: `indexedMarkdown`, `TextFormat`, `needsIndexing(extractedAt:fileModified:format:)` from Task 1; `setExtractedText(_:extractedAt:)` batch overload from Task 2.
- Produces: nothing new. `Runner.readText` changes its return element type to `(documentID: String, markdown: String, format: TextFormat)`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PaperShelfAppTests/IndexProducerTests.swift`:

```swift
import XCTest
import PaperShelfCore
@testable import PaperShelf

/// What the bulk index pass stores, which is the text every search reads. It has to carry
/// page markers, or no result can say which page it found anything on, and it has to say
/// which producer wrote it, or text written before markers existed is never read again.
final class IndexProducerTests: XCTestCase {
    private func scratch(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName(name), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testABulkPassStoresPageMarkedMarkdown() async throws {
        let directory = try scratch("index-producer")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("paper.pdf")
        try makeTextPDF(at: file, text: "Session types for the pi calculus")

        let read = await Runner.readText([(id: "doc-1", url: file)], passwords: [])

        XCTAssertEqual(read.failures, 0)
        let stored = try XCTUnwrap(read.stored.first)
        XCTAssertEqual(stored.documentID, "doc-1")
        XCTAssertTrue(stored.markdown.contains("## Page 1"))
        XCTAssertTrue(stored.markdown.contains("Session types"))
        XCTAssertEqual(stored.format, .markdown)
    }

    /// A locked book must count as a failure and be stored nowhere, so the next pass tries
    /// it again. Storing a title heading for it would mark it read forever.
    func testALockedDocumentIsAFailureAndIsNotStored() async throws {
        let directory = try scratch("index-producer-locked")
        defer { try? FileManager.default.removeItem(at: directory) }
        let locked = directory.appendingPathComponent("locked.pdf")
        try makePDF(at: locked, password: "secret")

        let read = await Runner.readText([(id: "doc-2", url: locked)], passwords: [])

        XCTAssertEqual(read.failures, 1)
        XCTAssertTrue(read.stored.isEmpty)
    }
}
```

`makeTextPDF`, `makePDF` and `scratchName` live in `Tests/PaperShelfCoreTests/TestSupport.swift`. If the app test target cannot see them, copy the three helpers into a new `Tests/PaperShelfAppTests/PDFSupport.swift` rather than making the core test target a dependency; check first whether `Tests/PaperShelfAppTests` already has an equivalent.

`Runner.readText` is `private nonisolated static`. Change it to `nonisolated static` (drop `private`) so the test can call it; leave everything else about it alone.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter IndexProducerTests 2>&1 | tail -20`
Expected: FAIL, either `readText` is inaccessible or the stored tuple has no `format`.

- [ ] **Step 3: Write the implementation**

In `Sources/PaperShelf/TextIndexing.swift`, the work filter now asks about the format too:

```swift
            let work = snapshot.compactMap { item -> (id: String, url: URL)? in
                guard let row = byPath[item.key] else { return nil }
                guard needsIndexing(extractedAt: row.extractedAt,
                                    fileModified: modified[item.key] ?? nil,
                                    format: row.format) else { return nil }
                return (row.documentID, item.currentURL)
            }
```

and `readText` reads page-marked Markdown:

```swift
    /// One batch, read across every core. Extraction is the whole cost here and it is all
    /// disk and PDFKit, neither of which belongs on the main actor.
    ///
    /// `indexedMarkdown` and not `markdown(for:passwords:using:)`: the engine-choosing
    /// entry point falls through to OCR for a document with no text layer and to a spawned
    /// process per document when an external converter is installed, either of which turns
    /// a fourteen thousand book pass from minutes into days. Reading the text layer page by
    /// page is what this pass has always done and what it should keep doing; the only thing
    /// that changes is that each page now says which page it is.
    nonisolated static func readText(
        _ work: [(id: String, url: URL)], passwords: [String]
    ) async -> (stored: [(documentID: String, markdown: String, format: TextFormat)],
                failures: Int, last: String) {
        await Task.detached(priority: .utility) {
            var stored = [(documentID: String, markdown: String, format: TextFormat)]()
            var failures = 0
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: work.count) { index in
                let job = work[index]
                let read = indexedMarkdown(of: job.url, passwords: passwords)
                lock.lock()
                if let read {
                    stored.append((documentID: job.id, markdown: read.text, format: read.format))
                } else {
                    failures += 1
                }
                lock.unlock()
            }
            return (stored, failures, work.last?.url.lastPathComponent ?? "")
        }.value
    }
```

The call at line 56, `try await library.setExtractedText(read.stored)`, now resolves to the batch overload from Task 2 with no change, because `read.stored` already has the right element type.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter IndexProducerTests 2>&1 | tail -20`
Expected: PASS, 2 tests.

Run: `swift build 2>&1 | tail -20`
Expected: no errors. This is the first task where the whole package builds again.

- [ ] **Step 5: Commit**

```bash
git add Sources/PaperShelf/TextIndexing.swift Tests/PaperShelfAppTests/IndexProducerTests.swift
git commit -m "feat: indexing reads a document the way a reader would quote it"
```

---

### Task 4: Excerpts and page attribution

The pure function every search result depends on. Given page-marked Markdown and a phrase, hand back the passages that matched and the page each one is on.

**Files:**
- Create: `Sources/PaperShelfCore/Excerpt.swift`
- Test: `Tests/PaperShelfCoreTests/ExcerptTests.swift` (create)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct Excerpt: Sendable, Equatable { public var text: String; public var page: Int? }`
  - `public func pageNumber(in markdown: String, before offset: String.Index) -> Int?`
  - `public func excerpts(in markdown: String, matching phrase: String, limit: Int = 2, radius: Int = 160) -> [Excerpt]`

- [ ] **Step 1: Write the failing test**

Create `Tests/PaperShelfCoreTests/ExcerptTests.swift`:

```swift
import XCTest
@testable import PaperShelfCore

final class ExcerptTests: XCTestCase {
    /// A page with no text is skipped entirely, its marker included, so the third marker
    /// in a document is not page three. Counting markers would report page 3 here where
    /// the passage is on page 7.
    private let withAGap = """
        ## Page 1

        The opening remarks.

        ## Page 2

        Nothing of consequence.

        ## Page 7

        The categorical imperative is the only thing that binds without condition.

        """

    func testThePageComesFromTheMarkerNotFromCounting() throws {
        let offset = try XCTUnwrap(withAGap.range(of: "categorical imperative")).lowerBound
        XCTAssertEqual(pageNumber(in: withAGap, before: offset), 7)
    }

    func testTextBeforeAnyMarkerHasNoPage() throws {
        let markdown = "a preface with no marker at all"
        let offset = try XCTUnwrap(markdown.range(of: "preface")).lowerBound
        XCTAssertNil(pageNumber(in: markdown, before: offset))
    }

    func testAnExcerptCarriesItsPageAndOmitsTheMarker() {
        let found = excerpts(in: withAGap, matching: "categorical imperative")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.page, 7)
        XCTAssertTrue(found.first?.text.contains("only thing that binds") == true)
        XCTAssertFalse(found.first?.text.contains("## Page") == true,
                       "a marker is structure, not something to quote")
    }

    func testMatchingIgnoresCase() {
        XCTAssertEqual(excerpts(in: withAGap, matching: "CATEGORICAL Imperative").count, 1)
    }

    func testTheLimitIsHonoured() {
        let repeated = (1...5).map { "## Page \($0)\n\nthe same phrase here\n" }.joined()
        XCTAssertEqual(excerpts(in: repeated, matching: "same phrase", limit: 2).count, 2)
        XCTAssertEqual(excerpts(in: repeated, matching: "same phrase", limit: 5).count, 5)
    }

    /// FTS5 matches on tokens, so a phrase that ranked a document can still be absent from
    /// it verbatim. Falling back to the longest word is the difference between a hit with
    /// a quote and a hit with nothing to show.
    func testAPhraseThatIsNotVerbatimFallsBackToItsLongestWord() {
        let found = excerpts(in: withAGap, matching: "imperative binds")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.page, 7)
    }

    func testNothingMatchesGivesNothing() {
        XCTAssertTrue(excerpts(in: withAGap, matching: "phenomenology").isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ExcerptTests 2>&1 | tail -20`
Expected: FAIL, `cannot find 'pageNumber' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/PaperShelfCore/Excerpt.swift`:

```swift
import Foundation

/// A passage worth quoting back, and where it came from.
public struct Excerpt: Sendable, Equatable {
    public var text: String
    /// Nil when the stored text carries no marker before this passage, which is what text
    /// written before page markers existed looks like.
    public var page: Int?

    public init(text: String, page: Int?) {
        self.text = text
        self.page = page
    }
}

private let pageMarker = "## Page "

/// The page a position in page-marked Markdown falls on.
///
/// The marker's own number is read rather than markers counted. `indexedMarkdown` and
/// `markdownFromPDF` both skip a page with no text entirely, its marker included, so in a
/// book with one blank page the nth marker is not page n. Counting would be quietly wrong
/// on exactly the documents nobody checks.
public func pageNumber(in markdown: String, before offset: String.Index) -> Int? {
    guard let marker = markdown.range(of: pageMarker, options: .backwards,
                                      range: markdown.startIndex..<offset) else { return nil }
    let digits = markdown[marker.upperBound...].prefix { $0.isNumber }
    return Int(digits)
}

/// The passages in `markdown` that match `phrase`, each with the page it is on.
///
/// Matching is case and diacritic insensitive, which is what a reader means by a phrase.
/// When the phrase does not appear verbatim the longest word in it is tried instead: FTS5
/// ranks on tokens, so a document can legitimately match a phrase it does not contain in
/// that exact order, and a hit with no quotable passage is worse than a slightly wider one.
public func excerpts(in markdown: String, matching phrase: String,
                     limit: Int = 2, radius: Int = 160) -> [Excerpt] {
    guard limit > 0 else { return [] }
    let needles = [phrase.trimmingCharacters(in: .whitespacesAndNewlines)]
        + [longestWord(in: phrase)].compactMap { $0 }
    for needle in needles where !needle.isEmpty {
        let found = passages(in: markdown, matching: needle, limit: limit, radius: radius)
        if !found.isEmpty { return found }
    }
    return []
}

private func longestWord(in phrase: String) -> String? {
    phrase.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map(String.init)
        .filter { $0.count >= 4 }
        .max(by: { $0.count < $1.count })
}

private func passages(in markdown: String, matching needle: String,
                      limit: Int, radius: Int) -> [Excerpt] {
    var found: [Excerpt] = []
    var searchFrom = markdown.startIndex
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    while found.count < limit,
          let match = markdown.range(of: needle, options: options,
                                     range: searchFrom..<markdown.endIndex) {
        let page = pageNumber(in: markdown, before: match.lowerBound)
        let start = markdown.index(match.lowerBound, offsetBy: -radius,
                                   limitedBy: markdown.startIndex) ?? markdown.startIndex
        let end = markdown.index(match.upperBound, offsetBy: radius,
                                 limitedBy: markdown.endIndex) ?? markdown.endIndex
        found.append(Excerpt(text: cleaned(String(markdown[start..<end])), page: page))
        searchFrom = match.upperBound
    }
    return found
}

/// A marker is structure, not prose: a quote that carries one reads as though the document
/// said "## Page 7". Whitespace is collapsed for the same reason, since a PDF's own line
/// breaks are set for a page width nobody is reading this at.
private func cleaned(_ passage: String) -> String {
    passage
        .split(separator: "\n")
        .filter { !$0.hasPrefix(pageMarker) }
        .joined(separator: " ")
        .split(separator: " ", omittingEmptySubsequences: true)
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter ExcerptTests 2>&1 | tail -20`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/PaperShelfCore/Excerpt.swift Tests/PaperShelfCoreTests/ExcerptTests.swift
git commit -m "feat: a passage knows which page it was read from"
```

---

### Task 5: The server reads the whole library

`LibraryReader` can answer questions about one project and one tag. It cannot answer "what is in this library", "search all of it", or "what did I write about this document". Those are what every deepened tool needs.

**Files:**
- Modify: `Sources/PaperShelfMCP/Projects.swift`
- Test: `Tools/mcp-check.sh`, `Tools/mcp-check.py`

**Interfaces:**
- Consumes: `LibraryReader.DocumentSummary`, `describeDocument`, `openLibraryOrFail` (all already in `Projects.swift`); `TextFormat` from Task 1.
- Produces, all on `LibraryReader`:
  - `struct Totals { let documents: Int; let withText: Int; let clipped: Int; let staleText: Int; let projects: Int; let tags: Int }`
  - `func totals() throws -> Totals`
  - `func documents(limit: Int, offset: Int) throws -> [DocumentSummary]`
  - `func search(query: String, limit: Int, offset: Int) throws -> [DocumentSummary]`
  - `func search(inProject projectID: Int64, query: String, limit: Int, offset: Int) throws -> [DocumentSummary]` (the existing one gains `offset`)
  - `func extractedText(forDocument id: String) throws -> (markdown: String, format: TextFormat?)?`
  - `func notes(forDocument id: String) throws -> [(body: String, createdAt: String)]`
  - `func document(matching identifier: String) throws -> DocumentSummary?`
  - `func duplicateGroupsByHash() throws -> [(hash: String, documents: [DocumentSummary])]`

- [ ] **Step 1: Write the failing check**

`Tools/mcp-check.sh` builds its scratch database by hand. Three changes to its `sqlite3` heredoc.

First, the schema has to match what `Library.swift` produces now, so add the `notes` table, the `format` column, and the user version. Put this immediately after the `CREATE TABLE extracted_text (...)` statement and before the FTS table:

```sql
CREATE TABLE notes (
    id          INTEGER PRIMARY KEY,
    document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    body        TEXT NOT NULL,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);
```

and change the `extracted_text` table itself to carry the column added by schemaV7:

```sql
CREATE TABLE extracted_text (
    document_id  TEXT PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE,
    markdown     TEXT NOT NULL,
    extracted_at TEXT NOT NULL,
    format       TEXT
);
```

Second, the seeded text becomes page-marked, so the excerpt and page checks have something real to find. Replace the single `INSERT INTO extracted_text` line with:

```sql
INSERT INTO extracted_text(document_id, markdown, extracted_at, format)
VALUES ('doc-1',
        '## Page 1' || char(10) || char(10) || 'A preface.' || char(10) || char(10) ||
        '## Page 7' || char(10) || char(10) || 'the categorical imperative is a concept',
        '2026-01-01T00:00:00Z', 'markdown-v1');
INSERT INTO notes(document_id, body, created_at, updated_at)
VALUES ('doc-1', 'compare against Korsgaard', '2026-01-03T00:00:00Z', '2026-01-03T00:00:00Z');
```

Third, add a second document sharing `doc-1`'s content hash, so library-wide duplicate detection has a pair, and set the user version last so anything opening this file read-write does not try to migrate it:

```sql
INSERT INTO documents(id, first_seen_at, last_seen_at, content_hash, byte_count, page_count, title, author, document_info)
VALUES ('doc-2', '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', 'abc', 1234, 42, 'Groundwork (copy)', 'Kant', '{}');
INSERT INTO locations(path, document_id, first_seen_at, last_seen_at)
VALUES ('/tmp/groundwork-copy.pdf', 'doc-2', '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z');

PRAGMA user_version = 7;
```

Then add the requests. In the third block, the one with `PAPERSHELF_LIBRARY_PATH="$LIBRARY_DB"`, append these lines before the closing `|`:

```bash
  '{"jsonrpc":"2.0","id":"51","method":"tools/call","params":{"name":"list_documents","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":"52","method":"tools/call","params":{"name":"search_documents","arguments":{"query":"categorical imperative"}}}' \
  '{"jsonrpc":"2.0","id":"53","method":"tools/call","params":{"name":"find_duplicates","arguments":{}}}' \
```

and in `Tools/mcp-check.py`, after the existing scratch-library checks, add:

```python
o = result("51")
check(
    "list_documents with no folder reports the library's totals",
    o.get("structuredContent", {}).get("totals", {}).get("documents") == 2,
)
check(
    "list_documents with no folder lists documents",
    len(o.get("structuredContent", {}).get("documents", [])) == 2,
)

s = result("52")
hits = s.get("structuredContent", {}).get("documents", [])
check("a library-wide search finds the indexed document", len(hits) == 1)
check(
    "a hit quotes the passage it matched",
    "categorical imperative" in (hits[0].get("excerpts", [{}])[0].get("text", "") if hits else ""),
)
check(
    "a hit says which page it came from",
    (hits[0].get("excerpts", [{}])[0].get("page") if hits else None) == 7,
)

dupes = result("53").get("structuredContent", {}).get("groups", [])
check(
    "duplicates are found library-wide by content hash",
    len(dupes) == 1 and len(dupes[0].get("paths", [])) == 2,
)
```

Update the reply-count check at the top of `mcp-check.py` from `7 + 5 + 11` to `7 + 5 + 14`.

- [ ] **Step 2: Run the check to verify it fails**

Run: `swift build && Tools/mcp-check.sh 2>&1 | tail -20`
Expected: FAIL lines for the four new checks, because `list_documents` still requires a folder.

- [ ] **Step 3: Write the implementation**

In `Sources/PaperShelfMCP/Projects.swift`, add to `LibraryReader`. The existing `search(inProject:query:limit:)` gains an `offset` parameter with the same `LIMIT ? OFFSET ?` tail as the new one; keep its comment about joining `project_members` into the query rather than filtering afterward.

```swift
    // MARK: - The library as a whole

    struct Totals {
        let documents: Int
        let withText: Int
        let clipped: Int
        /// Rows written before page markers existed. Worth reporting, because a search
        /// over them cannot say a page and cannot see past the old cap.
        let staleText: Int
        let projects: Int
        let tags: Int
    }

    func totals() throws -> Totals {
        try withStatement("""
            SELECT (SELECT COUNT(*) FROM documents),
                   (SELECT COUNT(*) FROM extracted_text),
                   (SELECT COUNT(*) FROM extracted_text WHERE format = ?),
                   (SELECT COUNT(*) FROM extracted_text WHERE format IS NULL),
                   (SELECT COUNT(*) FROM projects),
                   (SELECT COUNT(*) FROM tags);
            """, bind: { statement in
            bindText(statement, 1, TextFormat.clipped.rawValue)
        }) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return Totals(documents: 0, withText: 0, clipped: 0, staleText: 0,
                              projects: 0, tags: 0)
            }
            return Totals(documents: Int(sqlite3_column_int64(statement, 0)),
                          withText: Int(sqlite3_column_int64(statement, 1)),
                          clipped: Int(sqlite3_column_int64(statement, 2)),
                          staleText: Int(sqlite3_column_int64(statement, 3)),
                          projects: Int(sqlite3_column_int64(statement, 4)),
                          tags: Int(sqlite3_column_int64(statement, 5)))
        }
    }

    func documents(limit: Int, offset: Int) throws -> [DocumentSummary] {
        try withStatement("""
            SELECT \(Self.documentColumns)
            FROM documents d
            ORDER BY d.last_seen_at DESC
            LIMIT ? OFFSET ?;
            """, bind: { statement in
            sqlite3_bind_int64(statement, 1, Int64(limit))
            sqlite3_bind_int64(statement, 2, Int64(offset))
        }) { statement in
            var results: [DocumentSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(documentSummary(from: statement))
            }
            return results
        }
    }

    /// The whole library, ranked by bm25. The same one-phrase wrapping `Library.fullTextSearch`
    /// uses: FTS5 gives `-`, `:`, `"` and bareword operators special meaning, and a
    /// researcher's question is not the place to make anyone escape them.
    func search(query: String, limit: Int, offset: Int) throws -> [DocumentSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let phrase = "\"\(trimmed.replacingOccurrences(of: "\"", with: "\"\""))\""
        return try withStatement("""
            SELECT \(Self.documentColumns)
            FROM extracted_text_fts
            JOIN extracted_text e ON e.rowid = extracted_text_fts.rowid
            JOIN documents d ON d.id = e.document_id
            WHERE extracted_text_fts MATCH ?
            ORDER BY bm25(extracted_text_fts)
            LIMIT ? OFFSET ?;
            """, bind: { statement in
            bindText(statement, 1, phrase)
            sqlite3_bind_int64(statement, 2, Int64(limit))
            sqlite3_bind_int64(statement, 3, Int64(offset))
        }) { statement in
            var results: [DocumentSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(documentSummary(from: statement))
            }
            return results
        }
    }

    func extractedText(forDocument id: String) throws -> (markdown: String, format: TextFormat?)? {
        try withStatement("SELECT markdown, format FROM extracted_text WHERE document_id = ?;",
                          bind: { statement in bindText(statement, 1, id) }) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return (columnText(statement, 0) ?? "",
                    columnText(statement, 1).flatMap(TextFormat.init(rawValue:)))
        }
    }

    func notes(forDocument id: String) throws -> [(body: String, createdAt: String)] {
        try withStatement("""
            SELECT body, created_at FROM notes WHERE document_id = ? ORDER BY created_at;
            """, bind: { statement in bindText(statement, 1, id) }) { statement in
            var results: [(body: String, createdAt: String)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append((columnText(statement, 0) ?? "", columnText(statement, 1) ?? ""))
            }
            return results
        }
    }

    /// Resolves whatever a caller has in hand to one document: the id a previous result
    /// handed back, a path on disk, or a title. Tried in that order, because an id is
    /// exact, a path is nearly exact, and a title is a guess.
    func document(matching identifier: String) throws -> DocumentSummary? {
        let byID = try withStatement(
            "SELECT \(Self.documentColumns) FROM documents d WHERE d.id = ?;",
            bind: { statement in bindText(statement, 1, identifier) }
        ) { statement -> DocumentSummary? in
            sqlite3_step(statement) == SQLITE_ROW ? documentSummary(from: statement) : nil
        }
        if let byID { return byID }

        let resolved = URL(fileURLWithPath: identifier).resolvingSymlinksInPath().path
        let byPath = try withStatement("""
            SELECT \(Self.documentColumns) FROM documents d
            JOIN locations l ON l.document_id = d.id
            WHERE l.path = ? OR l.path = ? LIMIT 1;
            """, bind: { statement in
            bindText(statement, 1, identifier)
            bindText(statement, 2, resolved)
        }) { statement -> DocumentSummary? in
            sqlite3_step(statement) == SQLITE_ROW ? documentSummary(from: statement) : nil
        }
        if let byPath { return byPath }

        return try withStatement("""
            SELECT \(Self.documentColumns) FROM documents d
            WHERE d.title = ? COLLATE NOCASE LIMIT 1;
            """, bind: { statement in bindText(statement, 1, identifier) }) { statement in
            sqlite3_step(statement) == SQLITE_ROW ? documentSummary(from: statement) : nil
        }
    }

    /// Documents that are byte-for-byte the same file under more than one name. Only a
    /// hash the library already computed is used; nothing here opens a PDF.
    func duplicateGroupsByHash() throws -> [(hash: String, documents: [DocumentSummary])] {
        let hashes = try withStatement("""
            SELECT content_hash FROM documents
            WHERE content_hash IS NOT NULL
            GROUP BY content_hash HAVING COUNT(*) > 1;
            """) { statement -> [String] in
            var results: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let hash = columnText(statement, 0) { results.append(hash) }
            }
            return results
        }
        return try hashes.map { hash in
            let documents = try withStatement("""
                SELECT \(Self.documentColumns) FROM documents d WHERE d.content_hash = ?;
                """, bind: { statement in bindText(statement, 1, hash) }) { statement -> [DocumentSummary] in
                var results: [DocumentSummary] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    results.append(documentSummary(from: statement))
                }
                return results
            }
            return (hash, documents)
        }
    }
```

`Projects.swift` needs `import PaperShelfCore` for `TextFormat`; it already has it.

Task 6 wires these into tools, so `Tools/mcp-check.sh` still fails at the end of this task. That is expected: this task's deliverable is the reader, and its own verification is Step 4 below.

- [ ] **Step 4: Verify the reader compiles and the existing checks still pass**

Run: `swift build 2>&1 | tail -20`
Expected: no errors.

Run: `Tools/mcp-check.sh 2>&1 | grep -c "^ok"`
Expected: the same count as before this task, with the four new checks failing. Confirm with `Tools/mcp-check.sh 2>&1 | grep FAIL`, which must list only the four new lines.

- [ ] **Step 5: Commit**

```bash
git add Sources/PaperShelfMCP/Projects.swift Tools/mcp-check.sh Tools/mcp-check.py
git commit -m "feat: the server can ask about the whole shelf, not one project"
```

---

### Task 6: `list_documents` and `search_documents` without a folder

**Files:**
- Create: `Sources/PaperShelfMCP/LibraryTools.swift`
- Modify: `Sources/PaperShelfMCP/Tools.swift`, `Sources/PaperShelfMCP/main.swift`
- Test: `Tools/mcp-check.sh`, `Tools/mcp-check.py` (already written in Task 5)

**Interfaces:**
- Consumes: everything from Task 5; `excerpts(in:matching:limit:radius:)` from Task 4.
- Produces:
  - `func encodeCursor(_ offset: Int) -> String`
  - `func decodeCursor(_ value: Any?) throws -> Int`
  - `func hit(_ document: LibraryReader.DocumentSummary, query: String, reader: LibraryReader) -> [String: Any]`
  - `let libraryTools: [Tool]` moves to `LibraryTools.swift`; `Tools.swift` keeps `let folderTools: [Tool]`; `main.swift` passes `folderTools + libraryTools`.

- [ ] **Step 1: The check is already written**

Task 5 added ids 51 and 52 to `Tools/mcp-check.sh`. Run them to see where they stand.

Run: `Tools/mcp-check.sh 2>&1 | grep FAIL`
Expected: the four lines added in Task 5.

- [ ] **Step 2: Split the tool list**

Move the six library-backed tools (`list_projects`, `list_project_documents`, `search_project`, `list_tags`, `documents_by_tag`, and the new library paths) into a new `Sources/PaperShelfMCP/LibraryTools.swift`, and rename the array in `Tools.swift` from `libraryTools` to `folderTools`. `Tools.swift` is 430 lines and this task alone adds several hundred; splitting on the line the file already draws in its own comment ("The tools above scan a folder fresh on every call... The ones below read the library") keeps both halves readable.

`Sources/PaperShelfMCP/main.swift` then reads:

```swift
let server = Server(
    tools: folderTools + libraryTools,
    ...
)
```

- [ ] **Step 3: Write the cursor and hit helpers**

At the top of `Sources/PaperShelfMCP/LibraryTools.swift`:

```swift
import Foundation
import PaperShelfCore

/// A cursor is an offset and nothing else, wrapped so nobody builds a query out of it.
/// Opaque to the client by construction: it is handed back exactly as it was given.
func encodeCursor(_ offset: Int) -> String {
    Data("offset:\(offset)".utf8).base64EncodedString()
}

func decodeCursor(_ value: Any?) throws -> Int {
    guard let text = value as? String, !text.isEmpty else { return 0 }
    guard let data = Data(base64Encoded: text),
          let decoded = String(data: data, encoding: .utf8),
          decoded.hasPrefix("offset:"),
          let offset = Int(decoded.dropFirst("offset:".count)),
          offset >= 0 else {
        throw ToolFailure("that cursor is not one this server handed out; call again without it")
    }
    return offset
}

/// One search result: what the document is, and the passages that matched with the page
/// each is on. A researcher asking a question wants the quote, not a second round trip.
func hit(_ document: LibraryReader.DocumentSummary, query: String,
         reader: LibraryReader) -> [String: Any] {
    var row = describeDocument(document)
    guard let stored = try? reader.extractedText(forDocument: document.id),
          let stored else { return row }
    let found = excerpts(in: stored.markdown, matching: query)
    if !found.isEmpty {
        row["excerpts"] = found.map { excerpt -> [String: Any] in
            var out: [String: Any] = ["text": excerpt.text]
            if let page = excerpt.page { out["page"] = page }
            return out
        }
    }
    // Said plainly rather than left out, so a document whose text was cut short is never
    // read as a document that does not mention the thing.
    if stored.format == .clipped { row["text_truncated"] = true }
    if stored.format == nil { row["text_predates_page_markers"] = true }
    return row
}
```

- [ ] **Step 4: Make `folder` optional on `list_documents`**

In `Tools.swift`, replace the `list_documents` tool with:

```swift
    Tool(
        name: "list_documents",
        title: "List documents",
        description: "With no folder, the library as a whole: how many documents it holds, "
            + "how many have had their text read, and the most recently seen of them. This "
            + "is the place to start when the researcher has not named a folder. With a "
            + "folder, the PDFs in it with their page count, size, embedded metadata, and "
            + "the name PaperShelf would give each one.",
        inputSchema: [
            "type": "object",
            "properties": [
                "folder": ["type": "string",
                           "description": "Absolute path to a folder or a single PDF. Omit to read the library."],
                "recursive": ["type": "boolean", "description": "Include subfolders. Default true. Folder only."],
                "limit": ["type": "integer", "description": "Maximum documents. Default 100. Library only."],
                "cursor": ["type": "string", "description": "From a previous result's next_cursor. Library only."],
            ],
        ],
        run: { arguments in
            if let folder = arguments["folder"] as? String, !folder.isEmpty {
                let items = try scan(root: folder,
                                     recursive: optionalBool(arguments, "recursive", default: true))
                let rows = items.map(describe)
                let text = items.isEmpty
                    ? "No PDFs found."
                    : items.map { "\($0.currentURL.path)  (\($0.pageCount ?? 0) pages)" }
                        .joined(separator: "\n")
                return ToolOutput(text: text, structured: ["count": rows.count, "documents": rows])
            }
            return try libraryOverview(arguments)
        }
    ),
```

and in `LibraryTools.swift` add the function it calls:

```swift
/// The library as it stands, plus a page of its documents. This doubles as the tool that
/// orients a model that has been given no path at all, which is why it is `list_documents`
/// with no folder rather than a separate tool nobody would think to call first.
func libraryOverview(_ arguments: [String: Any]) throws -> ToolOutput {
    let reader = try openLibraryOrFail()
    let totals = try reader.totals()
    let limit = max(0, min(arguments["limit"] as? Int ?? 100, 500))
    let offset = try decodeCursor(arguments["cursor"])
    let documents = try reader.documents(limit: limit, offset: offset)
    let rows = documents.map(describeDocument)

    var structured: [String: Any] = [
        "totals": ["documents": totals.documents, "with_text": totals.withText,
                   "text_truncated": totals.clipped, "text_predates_page_markers": totals.staleText,
                   "projects": totals.projects, "tags": totals.tags],
        "count": rows.count,
        "documents": rows,
    ]
    if documents.count == limit && limit > 0 {
        structured["next_cursor"] = encodeCursor(offset + limit)
    }
    var text = "\(totals.documents) documents, \(totals.withText) with text read, "
        + "\(totals.projects) projects, \(totals.tags) tags."
    if totals.staleText > 0 {
        text += "\n\(totals.staleText) were read before page markers existed, so a search "
            + "of those cannot say a page. Indexing again in PaperShelf fixes that."
    }
    text += documents.isEmpty ? "" : "\n\n" + documents.map { $0.path ?? $0.id }
        .joined(separator: "\n")
    return ToolOutput(text: text, structured: structured)
}
```

- [ ] **Step 5: Make `folder` optional on `search_documents`**

In `Tools.swift`, change `search_documents` so a missing folder searches the library. Keep the entire existing folder branch as it is; only the schema and the top of `run` change:

```swift
        inputSchema: [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "For example: kant text:\"categorical imperative\". With no folder, the whole query is matched as a phrase against the text of every document in the library."],
                "folder": ["type": "string", "description": "Absolute path to search under. Omit to search the library, which is faster and finds passages."],
                "recursive": ["type": "boolean", "description": "Folder only."],
                "limit": ["type": "integer", "description": "Maximum results. Default 20 for the library, 50 for a folder."],
                "cursor": ["type": "string", "description": "From a previous result's next_cursor. Library only."],
                "pages_per_document": ["type": "integer",
                                       "description": "How many opening pages a text: term reads. Folder only. Default 6."],
            ],
            "required": ["query"],
        ],
        run: { arguments in
            let raw = try requireString(arguments, "query")
            guard let folder = arguments["folder"] as? String, !folder.isEmpty else {
                return try searchLibrary(raw, arguments)
            }
            // ... the existing folder-scanning body, unchanged, using `folder` where it
            // previously called requireString(arguments, "folder")
        }
```

and in `LibraryTools.swift`:

```swift
/// The indexed library, ranked by bm25, with the passages that matched.
///
/// This never indexes anything. A library with no text in it is a state to report, not one
/// to fix inside a single tool call: reading fourteen thousand files is minutes of work
/// that the client will abandon long before it finishes.
func searchLibrary(_ query: String, _ arguments: [String: Any]) throws -> ToolOutput {
    let reader = try openLibraryOrFail()
    let totals = try reader.totals()
    guard totals.withText > 0 else {
        throw ToolFailure("No document in the library has had its text read yet, so there "
            + "is nothing to search. Open PaperShelf and index the library, or call this "
            + "again with a 'folder' to scan one directly.")
    }
    let limit = max(0, min(arguments["limit"] as? Int ?? 20, 100))
    let offset = try decodeCursor(arguments["cursor"])
    let documents = try reader.search(query: query, limit: limit, offset: offset)
    let rows = documents.map { hit($0, query: query, reader: reader) }

    var structured: [String: Any] = ["matched": rows.count, "documents": rows]
    if documents.count == limit && limit > 0 {
        structured["next_cursor"] = encodeCursor(offset + limit)
    }
    let text = documents.isEmpty
        ? "Nothing in the library matched."
        : rows.map { row -> String in
            let head = (row["path"] as? String) ?? (row["id"] as? String) ?? ""
            let quotes = (row["excerpts"] as? [[String: Any]] ?? []).map { excerpt -> String in
                let page = excerpt["page"].map { "p.\($0) " } ?? ""
                return "    \(page)\"\(excerpt["text"] as? String ?? "")\""
            }
            return ([head] + quotes).joined(separator: "\n")
        }.joined(separator: "\n\n")
    return ToolOutput(text: text, structured: structured)
}
```

- [ ] **Step 6: Run the checks to verify they pass**

Run: `swift build && Tools/mcp-check.sh 2>&1 | grep FAIL`
Expected: only the `find_duplicates` check (id 53) still fails, which Task 8 fixes. If ids 51 and 52 still fail, read the failing line before changing anything.

- [ ] **Step 7: Commit**

```bash
git add Sources/PaperShelfMCP/Tools.swift Sources/PaperShelfMCP/LibraryTools.swift \
        Sources/PaperShelfMCP/main.swift
git commit -m "feat: asking about the shelf no longer starts with a file path"
```

---

### Task 7: Reading by document id, and reading what is not indexed yet

**Files:**
- Modify: `Sources/PaperShelfMCP/Tools.swift`, `Sources/PaperShelfMCP/LibraryTools.swift`
- Create: `Sources/PaperShelfMCP/Writes.swift`, `Sources/PaperShelfMCP/Prefs.swift`
- Test: `Tools/mcp-check.sh`, `Tools/mcp-check.py`

**Interfaces:**
- Consumes: `LibraryReader.document(matching:)`, `extractedText(forDocument:)`, `notes(forDocument:)` from Task 5; `indexedMarkdown` from Task 1; `PasswordList.active(_:)` (`Sources/PaperShelfCore/Hammer.swift:490`).
- Produces:
  - `enum Prefs { static var passwords: [String]; static var fileOperationsEnabled: Bool; static var backup: BackupSettings }`
  - `func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T`
  - `func openLibraryForWriting() throws -> Library`
  - `func resolveDocument(_ arguments: [String: Any]) throws -> (path: String?, id: String?)`
  - `func storedOrExtracted(path: String, documentID: String?) throws -> (markdown: String, extracted: Bool)`
  - `func pageSlice(_ markdown: String, range: String) throws -> String`

- [ ] **Step 1: Write the failing checks**

In `Tools/mcp-check.sh`, in the scratch-library block, append:

```bash
  '{"jsonrpc":"2.0","id":"54","method":"tools/call","params":{"name":"read_page","arguments":{"document_id":"doc-1","page":7}}}' \
  '{"jsonrpc":"2.0","id":"55","method":"tools/call","params":{"name":"list_highlights","arguments":{"document_id":"doc-1"}}}' \
  '{"jsonrpc":"2.0","id":"56","method":"tools/call","params":{"name":"read_document","arguments":{"document_id":"doc-1","pages":"7-7"}}}' \
  '{"jsonrpc":"2.0","id":"57","method":"tools/call","params":{"name":"read_document","arguments":{"document_id":"no-such-doc"}}}' \
```

In `Tools/mcp-check.py`:

```python
check(
    "a page is read straight out of the stored text, with no file to open",
    "categorical imperative" in " ".join(
        part.get("text", "") for part in result("54").get("content", [])
    ),
)
check(
    "highlights bring the notes written about the document",
    any(
        "Korsgaard" in note.get("body", "")
        for note in result("55").get("structuredContent", {}).get("notes", [])
    ),
)
check(
    "a page range is sliced out of the stored text",
    "A preface" not in " ".join(
        part.get("text", "") for part in result("56").get("content", [])
    ),
)
check("an unknown document id is an isError, not a crash", result("57").get("isError") is True)
```

Update the reply-count check from `7 + 5 + 14` to `7 + 5 + 18`.

- [ ] **Step 2: Run the checks to verify they fail**

Run: `swift build && Tools/mcp-check.sh 2>&1 | grep FAIL`
Expected: the four new lines plus the `find_duplicates` line from Task 5.

- [ ] **Step 3: Write the preference reader**

`storedOrExtracted` and `list_highlights` both need the app's passwords, so this lands here rather than later. Create `Sources/PaperShelfMCP/Prefs.swift`:

```swift
import Foundation
import PaperShelfCore

/// What the app has been told, read from the app's own preferences.
///
/// The suite name is spelled out rather than left to `UserDefaults.standard`. The app is a
/// bundle, so its `standard` resolves to `com.jonaprieto.pdfhammer`; this server is a bare
/// executable at `Contents/MacOS/papershelf-mcp` with no Info.plist of its own, so its
/// `standard` is a different domain and would silently read nothing at all. Reading works
/// across processes because the app is unsandboxed: this is a plain CFPreferences plist,
/// not an App-Group container.
enum Prefs {
    private static let defaults = UserDefaults(suiteName: "com.jonaprieto.pdfhammer")

    /// The passwords the reader has already given the app, so a document it can open is a
    /// document this server can open. Never placed in a tool result, an error message, or
    /// a line written to stderr.
    static var passwords: [String] {
        PasswordList.active(defaults?.string(forKey: "passwords") ?? "")
    }

    /// Off until the user turns it on. Nothing in this server moves a file until it is.
    /// Read here, used in Task 11 and Task 12.
    static var fileOperationsEnabled: Bool {
        defaults?.bool(forKey: "mcpFileOperations") ?? false
    }

    /// The same backup arrangement the app itself would use, so a rename done from here
    /// leaves originals exactly where a rename done there would.
    static var backup: BackupSettings {
        let custom = defaults?.string(forKey: "backupCustomPath") ?? ""
        return BackupSettings(
            enabled: defaults?.object(forKey: "moveOriginals") as? Bool ?? true,
            folderName: defaults?.string(forKey: "backupFolderName") ?? defaultBackupFolderName,
            customLocation: custom.isEmpty ? nil : URL(fileURLWithPath: custom))
    }
}
```

- [ ] **Step 4: Write the write connection and the blocking bridge**

Create `Sources/PaperShelfMCP/Writes.swift`:

```swift
import Foundation
import PaperShelfCore

/// Runs an async body to completion and hands back its result, for the tools that have to
/// reach `Library`, which is an actor.
///
/// The server's read loop is synchronous and stays that way: reads go through
/// `LibraryReader`, which is a plain synchronous SQLite connection in the hot path of every
/// request. Only the handful of tools that write cross into the actor, and each of them
/// does a few statements. Making the whole loop async to avoid a semaphore on four tools
/// would be a large change for nothing.
///
/// ponytail: one semaphore per write call, which is fine at four write tools. If the write
/// side grows, make `Server.run` async and delete this.
func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    final class Box: @unchecked Sendable { var value: Result<T, Error>? }
    let box = Box()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do { box.value = .success(try await body()) } catch { box.value = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    guard let value = box.value else {
        throw ToolFailure("the library did not answer")
    }
    return try value.get()
}

/// A read-write connection to the library the app owns.
///
/// `Library.init` opens with `SQLITE_OPEN_CREATE`, which would conjure an empty library on
/// a machine where nobody has indexed one. That is not this process's call to make, so the
/// file has to exist first. WAL, which is the file's own journal mode, is what makes this
/// safe beside a running app: a reader never blocks a writer and a writer never blocks a
/// reader.
func openLibraryForWriting() throws -> Library {
    let url: URL
    if let overridden = ProcessInfo.processInfo.environment["PAPERSHELF_LIBRARY_PATH"] {
        url = URL(fileURLWithPath: overridden)
    } else if let standard = libraryDatabaseURL() {
        url = standard
    } else {
        throw ToolFailure("there is no Application Support directory to hold a library")
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw ToolFailure("No library has been indexed yet. Open PaperShelf and add a "
            + "folder to the library first.")
    }
    do {
        return try Library(url: url)
    } catch {
        throw ToolFailure("could not open the library for writing: \(error)")
    }
}
```

- [ ] **Step 5: Write the document resolution and page slicing helpers**

Add to `Sources/PaperShelfMCP/LibraryTools.swift`:

```swift
/// Either identifier, from either half of the tool surface. The library-backed tools hand
/// back an id and the folder-backed ones a path; without this, a researcher cannot read a
/// document a search just found them.
func resolveDocument(_ arguments: [String: Any]) throws -> (path: String?, id: String?) {
    if let path = arguments["path"] as? String, !path.isEmpty {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ToolFailure("no such file: \(path)")
        }
        let id = (try? LibraryReader.open())
            .flatMap { try? $0?.document(matching: path) }?.id
        return (path, id)
    }
    guard let identifier = arguments["document_id"] as? String, !identifier.isEmpty else {
        throw ToolFailure("give either 'path' or 'document_id'")
    }
    let reader = try openLibraryOrFail()
    guard let document = try reader.document(matching: identifier) else {
        throw ToolFailure("the library has no document with id, path or title "
            + "'\(identifier)'; call search_documents or list_documents first")
    }
    return (document.path, document.id)
}

/// The document's text, read from the library when it is there and read from the file and
/// stored when it is not.
///
/// Extracting here is bounded to the one document a researcher asked for, which is the
/// difference between this and indexing: it is worth doing inside a tool call because it
/// is one file, and the next question about the same document is then free.
func storedOrExtracted(path: String, documentID: String?) throws -> (markdown: String, extracted: Bool) {
    if let documentID,
       let reader = try? LibraryReader.open(), let reader,
       let stored = try reader.extractedText(forDocument: documentID),
       stored.format != nil, !stored.markdown.isEmpty {
        return (stored.markdown, false)
    }
    guard let read = indexedMarkdown(of: URL(fileURLWithPath: path),
                                     passwords: Prefs.passwords) else {
        throw ToolFailure("nothing could be read from that file; it may be locked, or it "
            + "may be a scan with no text layer")
    }
    if let documentID, !read.text.isEmpty {
        let library = try openLibraryForWriting()
        try? blocking { try await library.setExtractedText(read.text, forDocument: documentID,
                                                           format: read.format) }
    }
    return (read.text, true)
}

/// One page range out of page-marked Markdown, as "12" or "12-20".
func pageSlice(_ markdown: String, range: String) throws -> String {
    let parts = range.split(separator: "-", maxSplits: 1).map(String.init)
    guard let first = Int(parts.first ?? ""), first > 0 else {
        throw ToolFailure("'pages' looks like \"12\" or \"12-20\"")
    }
    let last = parts.count > 1 ? Int(parts[1]) : first
    guard let last, last >= first else {
        throw ToolFailure("'pages' looks like \"12\" or \"12-20\", with the second number "
            + "no smaller than the first")
    }
    var kept: [String] = []
    var current: Int?
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("## Page ") {
            current = Int(line.dropFirst("## Page ".count).prefix { $0.isNumber })
        }
        if let current, current >= first, current <= last { kept.append(String(line)) }
    }
    guard !kept.isEmpty else {
        throw ToolFailure("that document has no text on pages \(first) to \(last)")
    }
    return kept.joined(separator: "\n")
}
```

- [ ] **Step 6: Rewrite `read_document`, `read_page` and `list_highlights`**

In `Tools.swift`:

```swift
    Tool(
        name: "read_document",
        title: "Read a document as Markdown",
        description: "A document's text, page by page. Give it either a path or the "
            + "document_id a search handed back. A document the library has already read "
            + "is served from the library; one it has not is read from the file now and "
            + "kept, so the next question about it is free.",
        inputSchema: [
            "type": "object",
            "properties": [
                "document_id": ["type": "string", "description": "From a search or listing. Also accepts a title."],
                "path": ["type": "string", "description": "Absolute path to a PDF, if there is no id."],
                "pages": ["type": "string", "description": "One page or a range, as \"12\" or \"12-20\". Omit for the whole document."],
                "max_characters": ["type": "integer", "description": "Truncate. Default 200000."],
            ],
        ],
        run: { arguments in
            let (path, id) = try resolveDocument(arguments)
            guard let path else {
                throw ToolFailure("the library knows that document but not where it is now; "
                    + "call it again with 'path'")
            }
            let read = try storedOrExtracted(path: path, documentID: id)
            var markdown = read.markdown
            if let range = arguments["pages"] as? String, !range.isEmpty {
                markdown = try pageSlice(markdown, range: range)
            }
            guard !markdown.isEmpty else {
                throw ToolFailure("that document has no text layer to read")
            }
            let cap = arguments["max_characters"] as? Int ?? 200_000
            let clipped = markdown.count > cap
                ? String(markdown.prefix(cap)) + "\n\n[truncated at \(cap) characters]"
                : markdown
            return ToolOutput(text: clipped,
                              structured: ["extracted_now": read.extracted,
                                           "truncated": markdown.count > cap])
        }
    ),

    Tool(
        name: "read_page",
        title: "Read one page",
        description: "The text of a single page, for reading around a highlight rather "
            + "than pulling in the whole document. Give it either a path or a document_id.",
        inputSchema: [
            "type": "object",
            "properties": [
                "document_id": ["type": "string"],
                "path": ["type": "string"],
                "page": ["type": "integer", "description": "1-based, as the app shows it"],
            ],
            "required": ["page"],
        ],
        run: { arguments in
            guard let page = arguments["page"] as? Int, page > 0 else {
                throw ToolFailure("'page' is required and starts at 1")
            }
            let (path, id) = try resolveDocument(arguments)
            guard let path else {
                throw ToolFailure("the library knows that document but not where it is now; "
                    + "call it again with 'path'")
            }
            let read = try storedOrExtracted(path: path, documentID: id)
            let text = try pageSlice(read.markdown, range: "\(page)")
            return ToolOutput(text: text, structured: ["page": page])
        }
    ),
```

and `list_highlights` gains the same resolution plus the library's notes:

```swift
        run: { arguments in
            let (path, id) = try resolveDocument(arguments)
            guard let path else {
                throw ToolFailure("the library knows that document but not where it is now; "
                    + "call it again with 'path'")
            }
            let marks = pdfMarks(in: URL(fileURLWithPath: path), passwords: Prefs.passwords)
            let notes = id.flatMap { documentID -> [(body: String, createdAt: String)]? in
                guard let reader = try? LibraryReader.open(), let reader else { return nil }
                return try? reader.notes(forDocument: documentID)
            } ?? []
            guard !marks.isEmpty || !notes.isEmpty else {
                return ToolOutput(text: "Nothing is marked in that document, and nothing "
                                        + "has been written about it.", structured: nil)
            }
            let rows = marks.map { mark -> [String: Any] in
                var row: [String: Any] = ["page": mark.page, "kind": mark.kind]
                if !mark.quoted.isEmpty { row["quoted"] = mark.quoted }
                if !mark.note.isEmpty { row["note"] = mark.note }
                return row
            }
            let noteRows = notes.map { ["body": $0.body, "created_at": $0.createdAt] }
            var text = marks.map { mark in
                var line = "p.\(mark.page) [\(mark.kind)]"
                if !mark.quoted.isEmpty { line += " \"\(mark.quoted)\"" }
                if !mark.note.isEmpty { line += "\n    note: \(mark.note)" }
                return line
            }.joined(separator: "\n")
            if !notes.isEmpty {
                text += (text.isEmpty ? "" : "\n\n") + "About the document:\n"
                    + notes.map { "  " + $0.body }.joined(separator: "\n")
            }
            return ToolOutput(text: text,
                              structured: ["count": rows.count, "marks": rows, "notes": noteRows])
        }
```

Its `inputSchema` drops `required` and becomes `document_id` plus `path`, matching `read_page`.

The three tools keep their `password` argument for now; Task 9 removes it, once every call site is on `Prefs.passwords`.

- [ ] **Step 7: Run the checks to verify they pass**

Run: `swift build && Tools/mcp-check.sh 2>&1 | grep FAIL`
Expected: only the `find_duplicates` line from Task 5.

- [ ] **Step 8: Commit**

```bash
git add Sources/PaperShelfMCP/Tools.swift Sources/PaperShelfMCP/LibraryTools.swift \
        Sources/PaperShelfMCP/Writes.swift Sources/PaperShelfMCP/Prefs.swift \
        Tools/mcp-check.sh Tools/mcp-check.py
git commit -m "feat: a document a search found can be read without a path"
```

---

### Task 8: Scoped bibliography, library-wide duplicates, project search with passages

**Files:**
- Modify: `Sources/PaperShelfMCP/Tools.swift`, `Sources/PaperShelfMCP/LibraryTools.swift`
- Test: `Tools/mcp-check.sh`, `Tools/mcp-check.py`

**Interfaces:**
- Consumes: `duplicateGroupsByHash()`, `search(inProject:query:limit:offset:)` from Task 5; `hit(_:query:reader:)` from Task 6.
- Produces: nothing new.

- [ ] **Step 1: Write the failing checks**

Id 53 already exists from Task 5. Add two more to the scratch-library block of `Tools/mcp-check.sh`:

```bash
  '{"jsonrpc":"2.0","id":"58","method":"tools/call","params":{"name":"bibliography","arguments":{"project":"Dissertation","folder":"/tmp"}}}' \
  '{"jsonrpc":"2.0","id":"59","method":"tools/call","params":{"name":"search_project","arguments":{"project":"1","query":"categorical imperative"}}}' \
```

and to `Tools/mcp-check.py`:

```python
check(
    "bibliography refuses two scopes rather than picking one",
    result("58").get("isError") is True,
)
p = result("59").get("structuredContent", {}).get("documents", [])
check(
    "a project search quotes the passage and its page",
    bool(p) and p[0].get("excerpts", [{}])[0].get("page") == 7,
)
```

Update the reply-count check from `7 + 5 + 18` to `7 + 5 + 20`.

- [ ] **Step 2: Run the checks to verify they fail**

Run: `swift build && Tools/mcp-check.sh 2>&1 | grep FAIL`
Expected: ids 53, 58 and 59.

- [ ] **Step 3: Scope the bibliography**

In `Tools.swift`, replace the `bibliography` tool:

```swift
    Tool(
        name: "bibliography",
        title: "Build a BibTeX bibliography",
        description: "BibTeX entries for a set of documents, keyed by author and year "
            + "where those can be read. Name exactly one of folder, project, tag or "
            + "document_ids: a researcher who has just been shown eight results can cite "
            + "those eight by id.",
        inputSchema: [
            "type": "object",
            "properties": [
                "folder": ["type": "string"],
                "project": ["type": "string", "description": "A project's name or id."],
                "tag": ["type": "string"],
                "document_ids": ["type": "array", "items": ["type": "string"]],
                "recursive": ["type": "boolean", "description": "Folder only."],
                "type": ["type": "string", "enum": BibType.allCases.map(\.rawValue),
                         "description": "Entry type to emit. Default book."],
            ],
        ],
        run: { arguments in
            let named = ["folder", "project", "tag", "document_ids"].filter { key in
                if let text = arguments[key] as? String { return !text.isEmpty }
                if let list = arguments[key] as? [Any] { return !list.isEmpty }
                return false
            }
            guard named.count == 1 else {
                throw ToolFailure(named.isEmpty
                    ? "name one of folder, project, tag or document_ids"
                    : "name only one of folder, project, tag or document_ids; "
                      + "you named \(named.joined(separator: " and "))")
            }
            let type = (arguments["type"] as? String).flatMap(BibType.init(rawValue:)) ?? .book
            let paths = try bibliographyPaths(arguments, scope: named[0])
            guard !paths.isEmpty else { throw ToolFailure("nothing to cite there") }
            // The entries come from the files themselves, whichever scope named them: a
            // BibTeX key is built out of what the PDF says about itself, which the library
            // does not store in the shape `bibEntries` reads.
            let jobs = paths.map { Job(root: URL(fileURLWithPath: $0).deletingLastPathComponent(),
                                       file: URL(fileURLWithPath: $0)) }
            let items = process(jobs: jobs,
                                options: Options(passwords: Prefs.passwords, recursive: false,
                                                 dryRun: true))
            let entries = bibEntries(for: items, type: type)
            return ToolOutput(text: bibtexDocument(entries),
                              structured: ["entries": entries.count, "scope": named[0]])
        }
    ),
```

and in `LibraryTools.swift`:

```swift
/// The files one bibliography scope names. Every scope resolves to paths, because a BibTeX
/// entry is built by reading the PDF, not by reading the library's row about it.
func bibliographyPaths(_ arguments: [String: Any], scope: String) throws -> [String] {
    switch scope {
    case "folder":
        let folder = try requireString(arguments, "folder")
        return try scan(root: folder,
                        recursive: optionalBool(arguments, "recursive", default: true))
            .map(\.currentURL.path)
    case "project":
        let reader = try openLibraryOrFail()
        let project = try resolveProject(try requireString(arguments, "project"), in: reader)
        return try reader.documents(inProject: project.id, limit: 1000).compactMap { $0.0.path }
    case "tag":
        let reader = try openLibraryOrFail()
        return try reader.documents(taggedWith: try requireString(arguments, "tag"), limit: 1000)
            .compactMap(\.path)
    default:
        let ids = arguments["document_ids"] as? [String] ?? []
        let reader = try openLibraryOrFail()
        return try ids.compactMap { try reader.document(matching: $0)?.path }
    }
}
```

`scan` is `private` in `Tools.swift`; drop the `private` so `LibraryTools.swift` can call it.

- [ ] **Step 4: Make `find_duplicates` work library-wide**

In `Tools.swift`, change the `find_duplicates` run body to branch on the folder, keeping the existing folder branch untouched:

```swift
        inputSchema: [
            "type": "object",
            "properties": [
                "folder": ["type": "string", "description": "Absolute path. Omit to check the whole library."],
                "recursive": ["type": "boolean", "description": "Folder only. Default true."],
            ],
        ],
        run: { arguments in
            guard let folder = arguments["folder"] as? String, !folder.isEmpty else {
                return try libraryDuplicates()
            }
            // ... the existing body, using `folder` in place of requireString
        }
```

and in `LibraryTools.swift`:

```swift
/// Duplicates across the whole library, from hashes it already computed. Nothing here
/// opens a PDF, so this answers over fourteen thousand documents as fast as over ten. It
/// finds only byte-for-byte copies; the folder scan additionally finds documents whose
/// opening pages match under different bytes, which needs the files themselves.
func libraryDuplicates() throws -> ToolOutput {
    let reader = try openLibraryOrFail()
    let groups = try reader.duplicateGroupsByHash()
    guard !groups.isEmpty else {
        return ToolOutput(text: "No duplicates in the library.", structured: nil)
    }
    let described = groups.map { group -> [String: Any] in
        ["kind": "same bytes",
         "paths": group.documents.compactMap(\.path),
         "document_ids": group.documents.map(\.id)]
    }
    let text = groups.map { group in
        "same bytes:\n" + group.documents.map { "  " + ($0.path ?? $0.id) }
            .joined(separator: "\n")
    }.joined(separator: "\n\n")
    return ToolOutput(text: text, structured: ["groups": described])
}
```

- [ ] **Step 5: Give `search_project` the same passages**

In `LibraryTools.swift`, in `search_project`'s run body, replace `let rows = documents.map(describeDocument)` with:

```swift
            let rows = documents.map { hit($0, query: query, reader: reader) }
```

and pass `offset: try decodeCursor(arguments["cursor"])` to `reader.search(inProject:query:limit:offset:)`, adding `cursor` to its schema with the same description the other two use.

Neither `search_project` nor `list_project_documents` extracts text for documents that have none: a project can hold hundreds of files and reading them inside one tool call is the same unbounded wait `search_documents` refuses. What they must not do is hide it, so both report the shortfall. In each tool's run body, after the documents are fetched:

```swift
            let unread = documents.filter { document in
                (try? reader.extractedText(forDocument: document.id)) ?? nil == nil
            }.count
```

For `list_project_documents`, `documents` is an array of pairs, so map to `$0.0` first. Put `"without_text": unread` into the structured content of both, and when it is not zero append one line to the text:

```swift
            if unread > 0 {
                text += "\n\n\(unread) of these have no text on record, so a search of this "
                    + "project cannot see inside them. Reading them once in PaperShelf, or "
                    + "asking for one of them by name, fixes that."
            }
```

- [ ] **Step 6: Run the checks to verify they pass**

Run: `swift build && Tools/mcp-check.sh 2>&1 | grep FAIL`
Expected: nothing. Every check passes.

Run: `Tools/mcp-check.sh 2>&1 | tail -3`
Expected: the script's own summary line, with no failures.

- [ ] **Step 7: Commit**

```bash
git add Sources/PaperShelfMCP/Tools.swift Sources/PaperShelfMCP/LibraryTools.swift \
        Tools/mcp-check.sh Tools/mcp-check.py
git commit -m "feat: cite a project, and find the same book twice across the shelf"
```

---

### Task 9: No tool asks the caller for a password

The server has the app's passwords as of Task 7. The tools that still take one as an argument are now asking a researcher for something the machine already knows, and every password a client sends is one more place it can end up.

**Files:**
- Modify: `Sources/PaperShelfMCP/Tools.swift`, `Sources/PaperShelfMCP/LibraryTools.swift`
- Test: `Tools/mcp-check.sh`, `Tools/mcp-check.py`

**Interfaces:**
- Consumes: `Prefs.passwords` from Task 7.
- Produces: nothing new.

- [ ] **Step 1: Write the failing check**

`Tools/mcp-check.sh` cannot write to the real preferences domain, and must not. Check the one thing that can be checked without touching it: that no tool result ever contains a password-shaped field. Add to the first block of `Tools/mcp-check.sh`:

```bash
  '{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}' \
```

and to `Tools/mcp-check.py`:

```python
check(
    "no tool asks the caller for a password any more",
    all(
        "password" not in json.dumps(tool.get("inputSchema", {}))
        for tool in result("7").get("tools", [])
    ),
)
```

Update the reply-count check from `7 + 5 + 20` to `8 + 5 + 20`.

- [ ] **Step 2: Run the check to verify it fails**

Run: `swift build && Tools/mcp-check.sh 2>&1 | grep FAIL`
Expected: the password-schema line, because `read_document` and `list_highlights` still declare one.

- [ ] **Step 3: Write the implementation**

Delete the `password` property from the `inputSchema` of `read_document`, `read_page` and `list_highlights`, and every `arguments["password"]` read that went with it. In `scan(root:recursive:)` at the top of `Tools.swift`, and in every other call site in `Sources/PaperShelfMCP/`, replace `passwords: []` with `passwords: Prefs.passwords`, so a locked document is one the server can open exactly when the app can.

Run: `grep -rn "passwords: \[\]" Sources/PaperShelfMCP/`
Expected after the change: no output.

Run: `grep -rn "password" Sources/PaperShelfMCP/`
Expected: only `Prefs.swift`'s own reader, the `passwords: Prefs.passwords` call sites, and the comment in `Prefs.swift` saying a password is never placed in a result. No `arguments["password"]` anywhere.

- [ ] **Step 4: Run the checks to verify they pass**

Run: `swift build && Tools/mcp-check.sh 2>&1 | grep FAIL`
Expected: nothing.

- [ ] **Step 5: Commit**

```bash
git add Sources/PaperShelfMCP/Tools.swift Sources/PaperShelfMCP/LibraryTools.swift \
        Tools/mcp-check.sh Tools/mcp-check.py
git commit -m "feat: a locked book opens with the password the app already has"
```

---

### Task 10: `add_to_project` and `set_tags`

**Files:**
- Create: `Sources/PaperShelfMCP/WriteTools.swift`
- Modify: `Sources/PaperShelfMCP/main.swift`
- Test: `Tools/mcp-check.sh`, `Tools/mcp-check.py`

**Interfaces:**
- Consumes: `blocking`, `openLibraryForWriting` from Task 7; `resolveDocument` from Task 7; `Library.createProject(name:createdAt:)`, `addMember(_:toProject:addedAt:)`, `addNote(_:toDocument:at:)`, `addTag(_:toDocument:)`, `removeTag(_:fromDocument:)` (all `Sources/PaperShelfCore/Library.swift`).
- Produces: `let writeTools: [Tool]`, appended in `main.swift` as `folderTools + libraryTools + writeTools`.

- [ ] **Step 1: Write the failing checks**

The scratch library is opened read-write by these tools, which is why Task 5 set `PRAGMA user_version = 7` on it. Add to the scratch-library block of `Tools/mcp-check.sh`:

```bash
  '{"jsonrpc":"2.0","id":"60","method":"tools/call","params":{"name":"add_to_project","arguments":{"project":"Reading list","document_ids":["doc-1"],"section":"to read","note":"start here"}}}' \
  '{"jsonrpc":"2.0","id":"61","method":"tools/call","params":{"name":"list_projects","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":"62","method":"tools/call","params":{"name":"set_tags","arguments":{"document_ids":["doc-1"],"add":["kant"],"remove":["ethics"]}}}' \
  '{"jsonrpc":"2.0","id":"63","method":"tools/call","params":{"name":"documents_by_tag","arguments":{"tag":"kant"}}}' \
  '{"jsonrpc":"2.0","id":"64","method":"tools/call","params":{"name":"documents_by_tag","arguments":{"tag":"ethics"}}}' \
```

and to `Tools/mcp-check.py`:

```python
check(
    "a project named for the first time is created",
    result("60").get("structuredContent", {}).get("created") is True,
)
check(
    "the new project is listed with its one document",
    any(
        project.get("name") == "Reading list" and project.get("document_count") == 1
        for project in result("61").get("structuredContent", {}).get("projects", [])
    ),
)
check(
    "tags are added and removed in one call",
    result("62").get("structuredContent", {}).get("added") == 1
    and result("62").get("structuredContent", {}).get("removed") == 1,
)
check(
    "the added tag finds the document",
    len(result("63").get("structuredContent", {}).get("documents", [])) == 1,
)
check(
    "the removed tag finds nothing",
    len(result("64").get("structuredContent", {}).get("documents", [])) == 0,
)
```

Update the reply-count check from `8 + 5 + 20` to `8 + 5 + 25`.

- [ ] **Step 2: Run the checks to verify they fail**

Run: `swift build && Tools/mcp-check.sh 2>&1 | grep FAIL`
Expected: five lines, plus `Unknown tool: add_to_project` in the raw output.

- [ ] **Step 3: Write the implementation**

Create `Sources/PaperShelfMCP/WriteTools.swift`:

```swift
import Foundation
import PaperShelfCore

/// The tools that change something. Everything else in this server reads.
///
/// Two kinds of change, kept apart on purpose. These two write rows in the library:
/// reversible, invisible on disk, and no PDF is touched. `propose_file_changes` and
/// `apply_file_changes`, below, move actual files and are gated behind a preference that
/// is off until somebody turns it on.
let writeTools: [Tool] = [
    Tool(
        name: "add_to_project",
        title: "File documents into a reading project",
        description: "Put documents into a reading project, creating the project when the "
            + "name is not already one. Optionally file them under a section and attach a "
            + "note. Documents are named by the document_id a search handed back, or by "
            + "absolute path.",
        inputSchema: [
            "type": "object",
            "properties": [
                "project": ["type": "string", "description": "A project's name, or its id. An unknown name creates it."],
                "document_ids": ["type": "array", "items": ["type": "string"]],
                "paths": ["type": "array", "items": ["type": "string"],
                          "description": "Absolute paths, for documents the library may not know yet."],
                "section": ["type": "string", "description": "Which part of the reading list these are filed under."],
                "note": ["type": "string", "description": "Attached to each document, not to the project."],
            ],
            "required": ["project"],
        ],
        run: { arguments in
            let name = try requireString(arguments, "project")
            let reader = try openLibraryOrFail()
            let existing = try reader.project(matching: name)
            let ids = try namedDocuments(arguments, reader: reader)
            guard !ids.isEmpty else {
                throw ToolFailure("name at least one document, by document_ids or paths")
            }
            let library = try openLibraryForWriting()
            let section = arguments["section"] as? String
            let note = arguments["note"] as? String

            let projectID: Int64 = try blocking {
                if let existing { return existing.id }
                return try await library.createProject(name: name).id
            }
            try blocking {
                for id in ids {
                    try await library.addMember(id, toProject: projectID)
                    if let section, !section.isEmpty {
                        try await library.setSection(section, forDocument: id, inProject: projectID)
                    }
                    if let note, !note.isEmpty {
                        _ = try await library.addNote(note, toDocument: id)
                    }
                }
            }
            let text = "Filed \(ids.count) document\(ids.count == 1 ? "" : "s") into "
                + "\(name)\(existing == nil ? ", which is new" : "")."
            return ToolOutput(text: text,
                              structured: ["project": ["id": Int(projectID), "name": name],
                                           "created": existing == nil,
                                           "filed": ids.count])
        }
    ),

    Tool(
        name: "set_tags",
        title: "Tag and untag documents",
        description: "Add and remove tags on a set of documents in one call, so \"tag "
            + "these six as read and drop the todo tag\" is one step rather than twelve.",
        inputSchema: [
            "type": "object",
            "properties": [
                "document_ids": ["type": "array", "items": ["type": "string"]],
                "paths": ["type": "array", "items": ["type": "string"]],
                "add": ["type": "array", "items": ["type": "string"]],
                "remove": ["type": "array", "items": ["type": "string"]],
            ],
        ],
        run: { arguments in
            let reader = try openLibraryOrFail()
            let ids = try namedDocuments(arguments, reader: reader)
            guard !ids.isEmpty else {
                throw ToolFailure("name at least one document, by document_ids or paths")
            }
            let adding = (arguments["add"] as? [String] ?? []).filter { !$0.isEmpty }
            let removing = (arguments["remove"] as? [String] ?? []).filter { !$0.isEmpty }
            guard !adding.isEmpty || !removing.isEmpty else {
                throw ToolFailure("give 'add', 'remove', or both")
            }
            let library = try openLibraryForWriting()
            try blocking {
                for id in ids {
                    for tag in adding { try await library.addTag(tag, toDocument: id) }
                    for tag in removing { try await library.removeTag(tag, fromDocument: id) }
                }
            }
            let text = "\(ids.count) document\(ids.count == 1 ? "" : "s"): "
                + "added \(adding.joined(separator: ", ").ifEmpty("nothing")), "
                + "removed \(removing.joined(separator: ", ").ifEmpty("nothing"))."
            return ToolOutput(text: text,
                              structured: ["documents": ids.count,
                                           "added": adding.count, "removed": removing.count])
        }
    ),
]

/// The documents a write tool was pointed at, by id or by path, in one list.
///
/// A path the library has never seen is indexed first rather than skipped: a researcher
/// who names a file by path means that file, and `Library.addMembers(paths:)` deliberately
/// skips unknown ones, which would be a silent no-op here.
func namedDocuments(_ arguments: [String: Any], reader: LibraryReader) throws -> [String] {
    var ids: [String] = []
    for identifier in arguments["document_ids"] as? [String] ?? [] {
        guard let document = try reader.document(matching: identifier) else {
            throw ToolFailure("the library has no document '\(identifier)'; "
                + "call search_documents or list_documents first")
        }
        ids.append(document.id)
    }
    let paths = (arguments["paths"] as? [String] ?? []).filter { !$0.isEmpty }
    if !paths.isEmpty {
        let library = try openLibraryForWriting()
        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else {
                throw ToolFailure("no such file: \(path)")
            }
            if let known = try reader.document(matching: path) {
                ids.append(known.id)
                continue
            }
            let records: [Library.DocumentRecord] = try blocking {
                try await library.indexDocuments([indexInput(for: URL(fileURLWithPath: path))])
            }
            guard let first = records.first else {
                throw ToolFailure("could not record \(path) in the library")
            }
            ids.append(first.id)
        }
    }
    // The same document named twice, once by id and once by path, is one document.
    var seen = Set<String>()
    return ids.filter { seen.insert($0).inserted }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
```

`indexInput(for:)` lives in `Sources/PaperShelf/LibrarySync.swift`, which is the app target and not reachable from here. Move it to `Sources/PaperShelfCore/Library.swift` as a `public func` and leave the app calling the moved version; it depends only on Foundation and PDFKit.

In `Sources/PaperShelfMCP/main.swift`:

```swift
    tools: folderTools + libraryTools + writeTools,
```

- [ ] **Step 4: Run the checks to verify they pass**

Run: `swift build && Tools/mcp-check.sh 2>&1 | grep FAIL`
Expected: nothing.

Run: `swift test 2>&1 | tail -5`
Expected: PASS. Moving `indexInput` across modules touches the app target, so the whole suite runs here.

- [ ] **Step 5: Commit**

```bash
git add Sources/PaperShelfMCP/WriteTools.swift Sources/PaperShelfMCP/main.swift \
        Sources/PaperShelfCore/Library.swift Sources/PaperShelf/LibrarySync.swift \
        Tools/mcp-check.sh Tools/mcp-check.py
git commit -m "feat: what a search turns up can be kept, not just read"
```

---

### Task 11: The file-operations gate and `propose_file_changes`

**Files:**
- Create: `Sources/PaperShelfMCP/Plan.swift`
- Modify: `Sources/PaperShelfMCP/WriteTools.swift`, `Sources/PaperShelf/Prefs.swift`, `Sources/PaperShelf/SettingsWindow.swift`
- Test: `Tests/PaperShelfCoreTests/` is the wrong target for this; the plan file's own round trip is checked through `Tools/mcp-check.sh`.

**Interfaces:**
- Consumes: `Prefs.backup`, `Prefs.passwords` from Task 9; `collectJobs(roots:recursive:)`, `process(jobs:options:)`, `Options`, `NameRules`, `Job`, `Item` from `Sources/PaperShelfCore/Hammer.swift`.
- Produces:
  - `struct RenamePlan: Codable { let token: String; let createdAt: Date; let folder: String; let recursive: Bool; let rules: StoredRules; let backupEnabled: Bool; let backupFolderName: String; let backupCustomPath: String?; let moves: [Move] }`
  - `struct Move: Codable { let from: String; let to: String; let bytes: Int; let modified: Date }`
  - `func buildPlan(folder: String, recursive: Bool, rules: NameRules) throws -> RenamePlan`
  - `func writePlan(_ plan: RenamePlan) throws -> URL`
  - `func readPlan(token: String) throws -> RenamePlan`

- [ ] **Step 1: Write the failing checks**

Add to the scratch-library block of `Tools/mcp-check.sh`:

```bash
  "{\"jsonrpc\":\"2.0\",\"id\":\"70\",\"method\":\"tools/call\",\"params\":{\"name\":\"propose_file_changes\",\"arguments\":{\"folder\":\"$FOLDER\"}}}" \
```

and to `Tools/mcp-check.py`:

```python
plan = result("70").get("structuredContent", {})
check("a proposal comes back with a token", bool(plan.get("token")))
check("a proposal changes nothing on disk", plan.get("applied") is None)
```

Update the reply-count check from `8 + 5 + 25` to `8 + 5 + 26`.

`$FOLDER` is the same scratch directory the first block scans, which has no PDFs in it, so the plan is empty. That is the point: an empty plan must still come back with a token and must not be an error.

- [ ] **Step 2: Run the checks to verify they fail**

Run: `swift build && Tools/mcp-check.sh 2>&1 | grep FAIL`
Expected: two lines.

- [ ] **Step 3: Add the preference**

In `Sources/PaperShelf/Prefs.swift`, beside `moveOriginals`:

```swift
    /// Whether the MCP server may move files. Off, because a model asking to tidy a folder
    /// is a different thing from a person deciding to.
    var mcpFileOperations: Bool = Store.flag("mcpFileOperations", false) {
        didSet { Store.put("mcpFileOperations", mcpFileOperations) }
    }
```

In `Sources/PaperShelf/SettingsWindow.swift`, inside `IntegrationSettings`, add a toggle to the "Model Context Protocol" section, immediately after the `LabeledContent("Codex")` row:

```swift
                Toggle("Let it rename and move files", isOn: $prefs.mcpFileOperations)
```

and extend that section's footer to name what the toggle does:

```swift
                Text("list_documents, search_documents, read_document, bibliography and "
                     + "find_duplicates, and the reading projects and tags this library "
                     + "keeps. A separate binary that holds no state, and nothing leaves "
                     + "the machine.\n\n"
                     + "Renaming is off by default. With it on, a proposal still comes "
                     + "first and applying it re-checks every file, keeps originals "
                     + "wherever Files & passwords says to, and sends nothing anywhere "
                     + "but the Trash.")
```

- [ ] **Step 4: Write the plan type**

Create `Sources/PaperShelfMCP/Plan.swift`:

```swift
import Foundation
import CryptoKit
import PaperShelfCore

/// A rename that has been worked out but not done.
///
/// On disk, not in memory. This revision of the protocol is stateless and the client is
/// free to restart the server between the call that proposes a rename and the call that
/// applies it, so a plan held in a variable would be gone exactly when it was needed.
struct RenamePlan: Codable {
    struct Move: Codable {
        let from: String
        let to: String
        /// What the file was when the plan was made. Both are re-checked before anything
        /// moves, so a file edited in between stops the whole plan rather than being
        /// renamed on the strength of a stale reading.
        let bytes: Int
        let modified: Date
    }

    /// The plan's own hash, which is also its name on disk. A token cannot be pointed at a
    /// different plan and a plan cannot drift out from under a token issued for it.
    let token: String
    let createdAt: Date
    let folder: String
    let recursive: Bool
    let casing: String
    let separator: String
    let stripSymbols: Bool
    let stripDiacritics: Bool
    let asciiOnly: Bool
    let dropLeadingArticles: Bool
    let maxLength: Int
    let datePosition: String
    let dateFormat: String
    let backupEnabled: Bool
    let backupFolderName: String
    let backupCustomPath: String?
    let moves: [Move]

    /// Fifteen minutes. Long enough for a person to read a list of renames and answer,
    /// short enough that a plan cannot be applied against a folder nobody has looked at
    /// since yesterday.
    static let lifetime: TimeInterval = 900

    var isExpired: Bool { Date().timeIntervalSince(createdAt) > Self.lifetime }

    var rules: NameRules {
        NameRules(casing: NameRules.Casing(rawValue: casing) ?? .lowercase,
                  separator: NameRules.Separator(rawValue: separator) ?? .keep,
                  stripSymbols: stripSymbols,
                  stripDiacritics: stripDiacritics,
                  asciiOnly: asciiOnly,
                  dropLeadingArticles: dropLeadingArticles,
                  maxLength: maxLength,
                  datePosition: NameRules.DatePosition(rawValue: datePosition) ?? .prefix,
                  dateFormat: NameRules.DateFormat(rawValue: dateFormat) ?? .dashed)
    }

    var backup: BackupSettings {
        BackupSettings(enabled: backupEnabled, folderName: backupFolderName,
                       customLocation: backupCustomPath.map { URL(fileURLWithPath: $0) })
    }

    var options: Options {
        Options(passwords: Prefs.passwords, recursive: recursive, dryRun: true,
                backup: backup, rules: rules)
    }
}

/// The moves, hashed. Order is fixed by sorting so the same plan always hashes the same
/// way regardless of what order the filesystem handed the files back in.
func planToken(_ moves: [RenamePlan.Move]) -> String {
    let canonical = moves
        .map { "\($0.from)\u{1F}\($0.to)\u{1F}\($0.bytes)\u{1F}\($0.modified.timeIntervalSince1970)" }
        .sorted()
        .joined(separator: "\u{1E}")
    return SHA256.hash(data: Data(canonical.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

private func plansDirectory() throws -> URL {
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask).first else {
        throw ToolFailure("there is no Application Support directory to hold a plan")
    }
    let folder = base.appendingPathComponent("PaperShelf", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

func planURL(token: String) throws -> URL {
    // A token is hexadecimal by construction; refusing anything else is what keeps a
    // crafted token from naming a file outside this folder.
    guard !token.isEmpty, token.allSatisfy({ $0.isHexDigit }) else {
        throw ToolFailure("that is not a token this server handed out")
    }
    return try plansDirectory().appendingPathComponent("pending-plan-\(token).json")
}

func writePlan(_ plan: RenamePlan) throws -> URL {
    let url = try planURL(token: plan.token)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(plan).write(to: url, options: .atomic)
    return url
}

func readPlan(token: String) throws -> RenamePlan {
    let url = try planURL(token: token)
    guard let data = try? Data(contentsOf: url) else {
        throw ToolFailure("no plan with that token; it may have been applied already, or "
            + "expired. Call propose_file_changes again.")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let plan = try? decoder.decode(RenamePlan.self, from: data) else {
        throw ToolFailure("that plan could not be read; call propose_file_changes again")
    }
    guard !plan.isExpired else {
        try? FileManager.default.removeItem(at: url)
        throw ToolFailure("that plan is more than fifteen minutes old; call "
            + "propose_file_changes again to see what would happen now")
    }
    return plan
}

/// Works out what a rename would do, without doing any of it. `process` with `dryRun: true`
/// never touches the filesystem: its move and trash branches both return without writing.
func buildPlan(folder: String, recursive: Bool, rules: NameRules) throws -> RenamePlan {
    var isFolder: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) else {
        throw ToolFailure("no such folder: \(folder)")
    }
    let backup = Prefs.backup
    let options = Options(passwords: Prefs.passwords, recursive: recursive, dryRun: true,
                          backup: backup, rules: rules)
    let jobs = collectJobs(roots: [URL(fileURLWithPath: folder)], recursive: recursive)
    let items = process(jobs: jobs, options: options)
    let moves: [RenamePlan.Move] = items.filter(\.isRenamed).map { item in
        let attributes = try? FileManager.default.attributesOfItem(atPath: item.source.path)
        return RenamePlan.Move(
            from: item.source.path,
            to: item.destination.path,
            bytes: (attributes?[.size] as? Int) ?? 0,
            modified: (attributes?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0))
    }
    return RenamePlan(
        token: planToken(moves),
        createdAt: Date(),
        folder: folder,
        recursive: recursive,
        casing: rules.casing.rawValue,
        separator: rules.separator.rawValue,
        stripSymbols: rules.stripSymbols,
        stripDiacritics: rules.stripDiacritics,
        asciiOnly: rules.asciiOnly,
        dropLeadingArticles: rules.dropLeadingArticles,
        maxLength: rules.maxLength,
        datePosition: rules.datePosition.rawValue,
        dateFormat: rules.dateFormat.rawValue,
        backupEnabled: backup.enabled,
        backupFolderName: backup.safeFolderName,
        backupCustomPath: backup.customLocation?.path,
        moves: moves)
}
```

- [ ] **Step 5: Write `propose_file_changes`**

Append to `writeTools` in `Sources/PaperShelfMCP/WriteTools.swift`:

```swift
    Tool(
        name: "propose_file_changes",
        title: "Work out what renaming a folder would do",
        description: "The renames PaperShelf's own naming rules would make in a folder, "
            + "worked out without touching a single file. Comes back with a token. Show "
            + "the researcher the list and, if they say yes, pass the token to "
            + "apply_file_changes. The token stops being good after fifteen minutes.",
        inputSchema: [
            "type": "object",
            "properties": [
                "folder": ["type": "string", "description": "Absolute path."],
                "recursive": ["type": "boolean", "description": "Include subfolders. Default true."],
                "casing": ["type": "string", "enum": NameRules.Casing.allCases.map(\.rawValue)],
                "separator": ["type": "string", "enum": NameRules.Separator.allCases.map(\.rawValue)],
                "strip_symbols": ["type": "boolean"],
                "strip_diacritics": ["type": "boolean"],
                "ascii_only": ["type": "boolean"],
                "drop_leading_articles": ["type": "boolean"],
                "max_length": ["type": "integer", "description": "Cut names back to this. Zero leaves them."],
                "date_position": ["type": "string", "enum": NameRules.DatePosition.allCases.map(\.rawValue)],
                "date_format": ["type": "string", "enum": NameRules.DateFormat.allCases.map(\.rawValue)],
            ],
            "required": ["folder"],
        ],
        run: { arguments in
            let rules = NameRules(
                casing: (arguments["casing"] as? String).flatMap(NameRules.Casing.init(rawValue:)) ?? .lowercase,
                separator: (arguments["separator"] as? String).flatMap(NameRules.Separator.init(rawValue:)) ?? .keep,
                stripSymbols: optionalBool(arguments, "strip_symbols", default: false),
                stripDiacritics: optionalBool(arguments, "strip_diacritics", default: false),
                asciiOnly: optionalBool(arguments, "ascii_only", default: false),
                dropLeadingArticles: optionalBool(arguments, "drop_leading_articles", default: false),
                maxLength: arguments["max_length"] as? Int ?? 0,
                datePosition: (arguments["date_position"] as? String).flatMap(NameRules.DatePosition.init(rawValue:)) ?? .prefix,
                dateFormat: (arguments["date_format"] as? String).flatMap(NameRules.DateFormat.init(rawValue:)) ?? .dashed)

            let plan = try buildPlan(folder: try requireString(arguments, "folder"),
                                     recursive: optionalBool(arguments, "recursive", default: true),
                                     rules: rules)
            _ = try writePlan(plan)

            var text = plan.moves.isEmpty
                ? "Nothing in that folder would be renamed."
                : plan.moves.map { move in
                    (move.from as NSString).lastPathComponent + "\n    -> "
                        + (move.to as NSString).lastPathComponent
                }.joined(separator: "\n")
            if !Prefs.fileOperationsEnabled {
                text += "\n\nNothing can be applied: PaperShelf has file operations turned "
                    + "off. Settings, Integrations, \"Let it rename and move files\"."
            }
            return ToolOutput(text: text,
                              structured: ["token": plan.token,
                                           "count": plan.moves.count,
                                           "enabled": Prefs.fileOperationsEnabled,
                                           "moves": plan.moves.map { ["from": $0.from, "to": $0.to] }])
        }
    ),
```

- [ ] **Step 6: Run the checks to verify they pass**

Run: `swift build && Tools/mcp-check.sh 2>&1 | grep FAIL`
Expected: nothing.

Run: `swift test 2>&1 | tail -5`
Expected: PASS. `Prefs.swift` and `SettingsWindow.swift` are covered by the existing app tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/PaperShelfMCP/Plan.swift Sources/PaperShelfMCP/WriteTools.swift \
        Sources/PaperShelf/Prefs.swift Sources/PaperShelf/SettingsWindow.swift \
        Tools/mcp-check.sh Tools/mcp-check.py
git commit -m "feat: a rename can be shown before anyone agrees to it"
```

---

### Task 12: `apply_file_changes`

The only tool in the server that moves a file. Its whole job is to refuse when anything is not exactly as it was when the plan was made.

**Files:**
- Modify: `Sources/PaperShelfMCP/WriteTools.swift`, `Sources/PaperShelfMCP/Plan.swift`
- Test: `Tools/mcp-check.sh`, `Tools/mcp-check.py`

**Interfaces:**
- Consumes: everything from Task 11.
- Produces: `func verify(_ plan: RenamePlan) throws`

- [ ] **Step 1: Write the failing checks**

The gate is off in any environment the check script runs in, since it never writes preferences, so the check that matters most is that applying is refused.

A plan needs a real PDF to have anything in it. `process(job:options:)` returns `.failed` with `destination == source` for a file PDFKit cannot open, so a file with `.pdf` on the end and nothing inside plans zero moves and proves nothing. Add a fixture to `Tools/mcp-check.sh` just after the existing `trap` line. This is a hand-written 580-byte one-page PDF with a text layer, verified to open under PDFKit as one page reading "hello":

```bash
# A real, minimal PDF, so a rename plan has something in it. Its own folder, because the
# first block asserts that scanning $FOLDER finds nothing.
RENAMES="$FOLDER/renames"
mkdir -p "$RENAMES"
base64 -d > "$RENAMES/Some Paper (2024).pdf" <<'PDF'
JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2Jq
CjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2Jq
CjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCAyMDAg
MjAwXSAvUmVzb3VyY2VzIDw8IC9Gb250IDw8IC9GMSA1IDAgUiA+PiA+PiAvQ29udGVudHMgNCAw
IFIgPj4KZW5kb2JqCjQgMCBvYmoKPDwgL0xlbmd0aCAzNiA+PgpzdHJlYW0KQlQgL0YxIDEyIFRm
IDIwIDEwMCBUZCAoaGVsbG8pIFRqIEVUCmVuZHN0cmVhbQplbmRvYmoKNSAwIG9iago8PCAvVHlw
ZSAvRm9udCAvU3VidHlwZSAvVHlwZTEgL0Jhc2VGb250IC9IZWx2ZXRpY2EgPj4KZW5kb2JqCnhy
ZWYKMCA2CjAwMDAwMDAwMDAgNjU1MzUgZiAKMDAwMDAwMDAwOSAwMDAwMCBuIAowMDAwMDAwMDU4
IDAwMDAwIG4gCjAwMDAwMDAxMTUgMDAwMDAgbiAKMDAwMDAwMDI0MSAwMDAwMCBuIAowMDAwMDAw
MzI3IDAwMDAwIG4gCnRyYWlsZXIKPDwgL1NpemUgNiAvUm9vdCAxIDAgUiA+PgpzdGFydHhyZWYK
Mzk3CiUlRU9GCg==
PDF
```

Task 11's own proposal check (id 70) is against `$FOLDER`, which stays empty, so it keeps testing that an empty plan still comes back with a token. Everything below is against `$RENAMES`.

Then add to the scratch-library block:

```bash
  '{"jsonrpc":"2.0","id":"71","method":"tools/call","params":{"name":"apply_file_changes","arguments":{"token":"deadbeef"}}}' \
  "{\"jsonrpc\":\"2.0\",\"id\":\"72\",\"method\":\"tools/call\",\"params\":{\"name\":\"propose_file_changes\",\"arguments\":{\"folder\":\"$RENAMES\"}}}" \
```

The token has to be bound to the files, not just to the names, and the check for that is that touching a file changes it. Add a fourth block to `Tools/mcp-check.sh`, after the scratch-library one and inside the same braces:

```bash
# The same folder proposed twice with a byte written in between. A token that survives that
# would be a token that cannot tell a stale plan from a current one, which is the whole
# thing standing between apply_file_changes and a file it was never shown.
printf '%%comment\n' >> "$RENAMES/Some Paper (2024).pdf"
printf '%s\n' \
  "{\"jsonrpc\":\"2.0\",\"id\":\"73\",\"method\":\"tools/call\",\"params\":{\"name\":\"propose_file_changes\",\"arguments\":{\"folder\":\"$RENAMES\"}}}" \
  | PAPERSHELF_LIBRARY_PATH="$LIBRARY_DB" "$BIN" 2>/dev/null
```

A PDF comment appended after `%%EOF` is still a PDF PDFKit opens, so the second proposal still finds the same one move; only the file's size and modification date differ, which is exactly what the token has to notice.

and to `Tools/mcp-check.py`:

```python
check(
    "an unknown token is refused",
    result("71").get("isError") is True,
)
check(
    "applying is refused while the preference is off, and says so",
    result("71").get("isError") is True
    and "turned off" in " ".join(
        part.get("text", "") for part in result("71").get("content", [])
    ),
)
check(
    "a proposal over a folder with a file in it names a move",
    result("72").get("structuredContent", {}).get("count", 0) == 1,
)
check(
    "touching a file invalidates the token that described it",
    result("73").get("structuredContent", {}).get("token")
    != result("72").get("structuredContent", {}).get("token"),
)
```

Update the reply-count check from `8 + 5 + 26` to `8 + 5 + 28 + 1`.

- [ ] **Step 2: Run the checks to verify they fail**

Run: `swift build && Tools/mcp-check.sh 2>&1 | grep FAIL`
Expected: the three new lines, and `Unknown tool: apply_file_changes` in the raw output.

- [ ] **Step 3: Write the verification**

Append to `Sources/PaperShelfMCP/Plan.swift`:

```swift
/// Every file in the plan, exactly as it was when the plan was made.
///
/// Whole-plan, not per-file: renaming eleven of twelve files and reporting the twelfth as
/// skipped leaves a folder half-organised, which is harder to reason about than a folder
/// nobody touched. One changed file means propose again.
func verify(_ plan: RenamePlan) throws {
    for move in plan.moves {
        let attributes = try? FileManager.default.attributesOfItem(atPath: move.from)
        guard let attributes else {
            throw ToolFailure("\(move.from) is not where it was when this plan was made. "
                + "Nothing has been moved. Call propose_file_changes again.")
        }
        let bytes = (attributes[.size] as? Int) ?? -1
        let modified = (attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        guard bytes == move.bytes,
              abs(modified.timeIntervalSince(move.modified)) < 1 else {
            throw ToolFailure("\(move.from) has changed since this plan was made. Nothing "
                + "has been moved. Call propose_file_changes again.")
        }
        guard !FileManager.default.fileExists(atPath: move.to) else {
            throw ToolFailure("something is already at \(move.to). Nothing has been moved. "
                + "Call propose_file_changes again.")
        }
    }
}
```

- [ ] **Step 4: Write the tool**

Append to `writeTools`:

```swift
    Tool(
        name: "apply_file_changes",
        title: "Carry out a proposed rename",
        description: "Carries out the renames a propose_file_changes token stands for. "
            + "Only after the researcher has seen the list and agreed. Refuses if "
            + "PaperShelf has file operations turned off, if the token is unknown or more "
            + "than fifteen minutes old, or if any file in the plan has moved or changed "
            + "since. Originals are kept wherever the app's own backup setting says, and "
            + "nothing is ever deleted.",
        inputSchema: [
            "type": "object",
            "properties": [
                "token": ["type": "string", "description": "From propose_file_changes."],
            ],
            "required": ["token"],
        ],
        run: { arguments in
            guard Prefs.fileOperationsEnabled else {
                throw ToolFailure("PaperShelf has file operations turned off, so nothing "
                    + "here can move a file. The setting is in Settings, Integrations, "
                    + "\"Let it rename and move files\". Nothing has been moved.")
            }
            let plan = try readPlan(token: try requireString(arguments, "token"))
            guard !plan.moves.isEmpty else {
                return ToolOutput(text: "That plan renames nothing.",
                                  structured: ["applied": 0])
            }
            try verify(plan)

            // Worked out a second time and compared before anything is written. The plan
            // records what the rules said fifteen minutes ago; if a folder's contents have
            // shifted enough that the same rules now produce different names, applying the
            // old list would rename files to names nobody was shown.
            let planned = Set(plan.moves.map { "\($0.from)\u{1F}\($0.to)" })
            let jobs = collectJobs(roots: [URL(fileURLWithPath: plan.folder)],
                                   recursive: plan.recursive)
                .filter { job in plan.moves.contains { $0.from == job.file.path } }
            let rehearsed = process(jobs: jobs, options: plan.options)
            let now = Set(rehearsed.filter(\.isRenamed)
                .map { "\($0.source.path)\u{1F}\($0.destination.path)" })
            guard now == planned else {
                throw ToolFailure("the same rules now produce different names than this "
                    + "plan records. Nothing has been moved. Call propose_file_changes "
                    + "again to see what would happen now.")
            }

            var options = plan.options
            options.dryRun = false
            let done = process(jobs: jobs, options: options)
            let moved = done.filter(\.carriedOut)
            let failed = done.filter { $0.status == .failed }
            try? FileManager.default.removeItem(at: try planURL(token: plan.token))

            var text = "Renamed \(moved.count) of \(plan.moves.count)."
            if !failed.isEmpty {
                text += "\n" + failed.map { "  \($0.source.lastPathComponent): \($0.message)" }
                    .joined(separator: "\n")
            }
            return ToolOutput(
                text: text,
                structured: ["applied": moved.count,
                             "failed": failed.count,
                             "moves": moved.map { ["from": $0.source.path,
                                                   "to": $0.destination.path] }],
                isError: !failed.isEmpty)
        }
    ),
```

`Options.dryRun` is a `var`, so `options.dryRun = false` compiles. If it is not, add a `dryRun:` argument to the `Options` initialiser call in `RenamePlan.options` and build the second one separately rather than making the property mutable.

- [ ] **Step 5: Run the checks to verify they pass**

Run: `swift build && Tools/mcp-check.sh 2>&1 | grep FAIL`
Expected: nothing.

- [ ] **Step 6: Check the gate by hand, once**

This is the one behaviour no automated check in this repo covers, because covering it means writing to the real preferences domain.

```bash
mkdir -p /tmp/papershelf-gate
cp <any real PDF on this machine> "/tmp/papershelf-gate/Some Paper (2024).pdf"
defaults write com.jonaprieto.pdfhammer mcpFileOperations -bool false
BIN="$(swift build --show-bin-path)/PaperShelfMCP"
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"propose_file_changes","arguments":{"folder":"/tmp/papershelf-gate"}}}' \
  | "$BIN" 2>/dev/null
```

Expected: a result carrying a token, `"enabled": false`, and text ending in the sentence about the setting being off. Take the token, call `apply_file_changes` with it, and confirm `isError` is true and the file is still named `Some Paper (2024).pdf`. Then:

```bash
defaults write com.jonaprieto.pdfhammer mcpFileOperations -bool true
```

Propose and apply again, and confirm the file is renamed and the original is where `backupFolderName` says. Then clean up:

```bash
defaults delete com.jonaprieto.pdfhammer mcpFileOperations
rm -rf /tmp/papershelf-gate
```

- [ ] **Step 7: Commit**

```bash
git add Sources/PaperShelfMCP/Plan.swift Sources/PaperShelfMCP/WriteTools.swift \
        Tools/mcp-check.sh Tools/mcp-check.py
git commit -m "feat: a rename happens only when the folder is still what was shown"
```

---

### Task 13: One version, and the plugin listing that describes all of this

**Files:**
- Modify: `Sources/PaperShelfCore/Support.swift`, `Sources/PaperShelfMCP/main.swift`, `Plugin/papershelf/.codex-plugin/plugin.json`, `Sources/PaperShelf/PluginInstall.swift`, `README.md`
- Test: `Tools/mcp-check.sh`, `Tools/mcp-check.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `public let paperShelfVersion = "1.3.0"` in `Sources/PaperShelfCore/Support.swift`.

- [ ] **Step 1: Write the failing check**

`Tools/mcp-check.py` already reads `server/discover`'s `serverInfo`. Add beside it:

```python
check(
    "the server reports the version the plugin listing claims",
    d.get("_meta", {}).get("io.modelcontextprotocol/serverInfo", {}).get("version")
    == json.load(open("Plugin/papershelf/.codex-plugin/plugin.json"))["version"],
)
```

Run: `Tools/mcp-check.sh 2>&1 | grep FAIL`
Expected: this line, because `main.swift` says `1.1.0` and the manifest says `1.2.3`.

- [ ] **Step 2: Add the constant and use it**

In `Sources/PaperShelfCore/Support.swift`:

```swift
/// The one place a version number is written. The MCP server reports it as its
/// `serverInfo`, the plugin listing declares it, and `Tools/mcp-check.sh` checks the two
/// against each other, which is how they drifted to 1.1.0 and 1.2.3 without anyone
/// noticing.
public let paperShelfVersion = "1.3.0"
```

In `Sources/PaperShelfMCP/main.swift`:

```swift
import Foundation
import PaperShelfCore

if CommandLine.arguments.contains("--version") {
    print(paperShelfVersion)
    exit(0)
}

let server = Server(
    tools: folderTools + libraryTools + writeTools,
    name: "papershelf",
    version: paperShelfVersion,
    instructions: "Read, search and organise a local PDF library. Start with "
        + "list_documents with no arguments, which reports what the library holds; "
        + "search_documents with no folder searches all of it and quotes the passages it "
        + "matched with their page numbers. Every result carries a document_id that "
        + "read_document, read_page, list_highlights, add_to_project and set_tags all "
        + "accept, so nothing needs a file path. Paths, where they appear, are absolute "
        + "paths on this machine, and nothing leaves it."
)

note("papershelf \(paperShelfVersion) ready, speaking \(Revision.current) and the initialize handshake")
server.run()
```

`print` here is safe and correct: `--version` exits before the JSON-RPC stream begins.

In `Plugin/papershelf/.codex-plugin/plugin.json`, set `"version": "1.3.0"` and rewrite `interface.longDescription` and `defaultPrompt` to describe what the server can now do:

```json
  "longDescription": "PaperShelf keeps an index of the papers and books on your Mac. This plugin lets ChatGPT read it: search every document's text and get the passages back with their page numbers, open a document or a single page, list what you highlighted and the notes you left, pull a BibTeX entry for one paper or a whole reading project, find duplicate copies of the same work, and file what you find into projects and tags. It can also propose renaming a folder, which never happens without your say-so and is switched off until you turn it on. Everything runs against the app's own server on your machine, so the files never leave it and nothing is uploaded. Requires PaperShelf to be installed.",
  "defaultPrompt": [
    "What do I have on session types, and quote the relevant bits",
    "What did I highlight in the Milner paper?",
    "Put those four papers in a project called Reading list"
  ],
```

`Sources/PaperShelf/PluginInstall.swift` reproduces the manifest's content in Swift, because a built `.app` has no source checkout. Update the reproduced copy to match byte for byte, and run its tests.

- [ ] **Step 3: Update the README**

`README.md:427` onwards is the ChatGPT section. Rewrite it to say what the plugin can do now, mention that renaming is off by default and where the switch is, and drop any claim that every call names a folder. The Integrations settings footer written in Task 11 is the shorter version of the same text; keep the two saying the same thing.

- [ ] **Step 4: Run everything**

Run: `swift test 2>&1 | tail -5`
Expected: PASS. `PluginInstallTests` covers the reproduced manifest.

Run: `swift build && Tools/mcp-check.sh 2>&1 | grep FAIL`
Expected: nothing.

Run: `"$(swift build --show-bin-path)/PaperShelfMCP" --version`
Expected: `1.3.0`.

- [ ] **Step 5: Commit**

```bash
git add Sources/PaperShelfCore/Support.swift Sources/PaperShelfMCP/main.swift \
        Plugin/papershelf/.codex-plugin/plugin.json Sources/PaperShelf/PluginInstall.swift \
        README.md Tools/mcp-check.py
git commit -m "docs: the plugin listing says what it can actually do now"
```

---

### Task 14: End to end against a real library

Everything above is checked against a scratch database and scratch folders. This is the one task that runs the finished thing the way a researcher will.

**Files:** none modified unless something is found.

- [ ] **Step 1: Build and install**

Run: `./build.sh --install`
Expected: `Installed /Applications/PaperShelf.app`.

- [ ] **Step 2: Reindex**

Open PaperShelf, add a folder with at least a few PDFs to the library, and run the text indexing pass. Every row it writes now carries `format = "markdown-v1"`.

Check what landed:

```bash
sqlite3 ~/Library/Application\ Support/PaperShelf/library.sqlite \
  "SELECT format, COUNT(*) FROM extracted_text GROUP BY format;"
```

Expected: rows under `markdown-v1`, possibly some under `markdown-v1-clipped`. Any row still showing an empty format is one the pass has not reached yet; run it again and confirm the count falls to zero.

- [ ] **Step 3: Drive the installed server**

```bash
BIN=/Applications/PaperShelf.app/Contents/MacOS/papershelf-mcp
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_documents","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_documents","arguments":{"query":"<a phrase you know is in one of your PDFs>"}}}' \
  | "$BIN" 2>/dev/null | python3 -m json.tool --json-lines
```

Expected: the totals match what the app shows, and the search hit carries an `excerpts` array whose first entry has a `page` matching where that phrase actually is in the PDF. Open the document in PaperShelf and check the page by eye. This is the only check that the marker-parsing and the real converter output agree.

- [ ] **Step 4: Restart the ChatGPT desktop app and ask it something**

Install the plugin from PaperShelf's settings if it is not already there, restart ChatGPT, and ask it a question that needs the library, with no path in the question. Confirm it calls `list_documents` or `search_documents` with no folder rather than guessing a path.

- [ ] **Step 5: Commit anything the run turned up**

If Steps 2 to 4 surfaced a problem, fix it and amend it into the task that introduced it rather than adding a fix commit on top. If they did not, there is nothing to commit and this task ends here.

---

## Deviations from the spec

Three places where this plan does not do what `docs/superpowers/specs/2026-08-31-mcp-for-researchers-design.md` says. Each is a deliberate call, not an oversight, and each is small enough to reverse.

**The cap is a constant, not a preference.** The spec says `textIndexCharacterLimit` "becomes a preference". Task 1 raises it to 2,000,000 and leaves it a constant. The reason the spec gave for the cap was bounding a pathological document, which the constant already does; a setting nobody would ever move is a setting to maintain for nothing. Say so and it becomes three lines in `Prefs.swift` and one argument at the `indexedMarkdown` call site.

**`search_project` and `list_project_documents` do not extract on demand.** The spec has all four reading tools extracting text for documents that have none. Tasks 7 and 8 give that to `read_document` and `read_page` only, where it is one file that the researcher explicitly asked for. A project can hold hundreds, and extracting them inside one tool call is the same unbounded wait the spec itself refuses for `search_documents`. Both tools instead report how many of the project's documents have no text yet, so the gap is visible rather than silent.

**The migration is `schemaV7`, not `schemaV3`.** The spec calls it `schemaV3`; `Sources/PaperShelfCore/Library.swift:121` already lists six migrations, so the next one is the seventh. Naming only.

## Notes for whoever runs this

**Order matters between Tasks 1 and 3.** Task 1 deletes `documentText` while `Sources/PaperShelf/TextIndexing.swift:90` still calls it, so the package does not build at the end of Task 1 or Task 2. That is deliberate: the Core change and the app change are separate reviewable units and the alternative is one enormous commit. Task 3 Step 4 is where `swift build` must be green again. If you are running tasks in isolated worktrees, run 1, 2 and 3 in the same one.

**`Tools/mcp-check.sh` gets a new case in almost every task,** and the reply-count assertion at the top of `Tools/mcp-check.py` has to be bumped each time or every check after it reads from the wrong id. The running total: 7 + 5 + 11 at the start, 7 + 5 + 14 after Task 5, 7 + 5 + 18 after Task 7, 7 + 5 + 20 after Task 8, 8 + 5 + 20 after Task 9, 8 + 5 + 25 after Task 10, 8 + 5 + 26 after Task 11, and 8 + 5 + 28 + 1 after Task 12, where the trailing 1 is the fourth server run that Task 12 adds.

**The file-operations gate is not covered by any automated check** and cannot be without writing to the user's real preferences domain. Task 12 Step 6 is a manual pass, and it is the most important verification in this plan. Do not skip it.
