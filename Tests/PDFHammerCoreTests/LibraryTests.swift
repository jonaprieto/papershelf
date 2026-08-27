import XCTest
import SQLite3
@testable import PDFHammerCore

final class LibraryTests: XCTestCase {

    // MARK: - Fixtures

    /// A database file under a throwaway directory, never the real Application Support one.
    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("library.sqlite")
    }

    private func tearDownDatabase(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Reads a row count straight off the file with its own connection, independent of
    /// whatever `Library`'s own API can answer, to check for the one thing no method on
    /// `Library` claims to report directly: how many rows a table actually holds.
    private func rawCount(_ table: String, in url: URL) throws -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            throw NSError(domain: "LibraryTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not open \(url.path) read-only"])
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM \(table);", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(domain: "LibraryTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "could not count \(table)"])
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "LibraryTests", code: 3)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - Identity and indexing

    func testIndexDocumentCreatesANewDocumentAndLocation() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)

        let record = try await library.indexDocument(
            path: "/shelf/bank/statement.pdf", contentHash: "hash-1",
            byteCount: 4096, pageCount: 3, title: "Statement", author: "Someone",
            documentInfo: ["Producer": "Acrobat"]
        )

        XCTAssertEqual(record.contentHash, "hash-1")
        XCTAssertEqual(record.byteCount, 4096)
        XCTAssertEqual(record.pageCount, 3)
        XCTAssertEqual(record.title, "Statement")
        XCTAssertEqual(record.documentInfo, ["Producer": "Acrobat"])

        let byPath = try await library.document(atPath: "/shelf/bank/statement.pdf")
        XCTAssertEqual(byPath?.id, record.id)
        let byID = try await library.document(id: record.id)
        XCTAssertEqual(byID, record)
        let missing = try await library.document(atPath: "/shelf/nowhere.pdf")
        XCTAssertNil(missing)
    }

    func testReindexingTheSamePathIsIdempotentWhenNothingChanged() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)

        let first = try await library.indexDocument(path: "/shelf/a.pdf", contentHash: "hash-1", byteCount: 10, pageCount: 1, title: nil, author: nil)
        let second = try await library.indexDocument(path: "/shelf/a.pdf", contentHash: "hash-1", byteCount: 10, pageCount: 1, title: nil, author: nil)

        XCTAssertEqual(first.id, second.id)
        XCTAssertGreaterThanOrEqual(second.lastSeenAt, first.lastSeenAt)
        XCTAssertEqual(try rawCount("documents", in: url), 1)
        XCTAssertEqual(try rawCount("locations", in: url), 1)
    }

    /// The test the whole design exists to satisfy: this app writes highlights into a PDF
    /// and decrypts files in place (Annotations.swift, Hammer.swift), which changes a
    /// document's bytes under ordinary use. If a content-hash change produced a second row,
    /// every tag attached before that edit would be silently orphaned.
    func testReindexingAChangedFileKeepsTheSameDocumentAndItsTags() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)

        let before = try await library.indexDocument(
            path: "/shelf/bank/statement.pdf", contentHash: "hash-before",
            byteCount: 1000, pageCount: 4, title: "Statement", author: nil
        )
        try await library.addTag("distributed-systems", toDocument: before.id)
        try await library.addTag("to-read", toDocument: before.id)

        // Same path, later, with different bytes: an annotation was saved, or the file was
        // decrypted in place. Neither operation changes the path.
        let after = try await library.indexDocument(
            path: "/shelf/bank/statement.pdf", contentHash: "hash-after",
            byteCount: 1200, pageCount: 4, title: "Statement", author: nil
        )

        XCTAssertEqual(after.id, before.id, "the same path must resolve back to the same document")
        XCTAssertEqual(after.contentHash, "hash-after", "the hash locator should have moved forward")
        XCTAssertEqual(try rawCount("documents", in: url), 1, "re-indexing a changed file must not create a second row")

        let survivingTags = try await library.tags(forDocument: before.id).map(\.name)
        XCTAssertEqual(survivingTags, ["distributed-systems", "to-read"], "tags must survive a content change")
    }

    func testRecordLocationAddsAPathToAnExistingDocumentWithoutDuplicating() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)

        let record = try await library.indexDocument(path: "/shelf/original.pdf", contentHash: "hash-1", byteCount: 10, pageCount: 1, title: nil, author: nil)
        try await library.recordLocation("/shelf/renamed.pdf", forDocument: record.id)

        let viaOriginal = try await library.document(atPath: "/shelf/original.pdf")
        let viaRenamed = try await library.document(atPath: "/shelf/renamed.pdf")
        XCTAssertEqual(viaOriginal?.id, record.id)
        XCTAssertEqual(viaRenamed?.id, record.id)
        XCTAssertEqual(try rawCount("documents", in: url), 1)

        let paths = Set(try await library.locations(forDocument: record.id).map(\.path))
        XCTAssertEqual(paths, ["/shelf/original.pdf", "/shelf/renamed.pdf"])
    }

    func testRecordLocationRejectsAnUnknownDocument() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)

        do {
            try await library.recordLocation("/shelf/orphan.pdf", forDocument: "does-not-exist")
            XCTFail("a path can't be recorded against a document that was never indexed")
        } catch {
            // Expected: the foreign key on locations.document_id rejects it.
        }
    }

    /// The fatal objection this task closes: the app's own decrypt-and-rename changes a
    /// file's path, so a plain path-based rescan would see an unknown path and start a new
    /// document row, silently orphaning every tag on the old one. `recordLocation` is the
    /// fix, this is the proof: the same document, found under its new path, with its tag
    /// intact, and gone from the old path.
    func testARenameThroughRecordLocationKeepsTheTag() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)

        let oldPath = "/shelf/bank/Extracto.pdf"
        let newPath = "/shelf/bank/2024-06-extracto.pdf"
        let original = try await library.indexDocument(path: oldPath, contentHash: "hash-1", byteCount: 10, pageCount: 1, title: nil, author: nil)
        try await library.addTag("bank", toDocument: original.id)

        try await library.recordLocation(newPath, forDocument: original.id)

        let atNewPath = try await library.document(atPath: newPath)
        XCTAssertEqual(atNewPath?.id, original.id, "the rename must keep the same document identity")
        let survivingTags = try await library.tags(forDocument: original.id).map(\.name)
        XCTAssertEqual(survivingTags, ["bank"], "the tag must survive the rename")
    }

    /// Mutation check for the test above, and the bug `recordLocation` exists to prevent:
    /// a rescan that only knows the new path, with no `recordLocation` call to say it is
    /// the same file, indexes it as a second document and leaves the tag behind on the
    /// first one, unreachable from the path anyone would actually look it up by.
    func testWithoutRecordLocationARenameWouldOrphanTheTag() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)

        let oldPath = "/shelf/bank/Extracto.pdf"
        let newPath = "/shelf/bank/2024-06-extracto.pdf"
        let original = try await library.indexDocument(path: oldPath, contentHash: "hash-1", byteCount: 10, pageCount: 1, title: nil, author: nil)
        try await library.addTag("bank", toDocument: original.id)

        // A naive rescan of just the new path, as if the app never told the library a
        // move happened.
        let second = try await library.indexDocument(path: newPath, contentHash: "hash-1", byteCount: 10, pageCount: 1, title: nil, author: nil)

        XCTAssertNotEqual(second.id, original.id, "without recordLocation this really is a second document")
        let orphanedTags = try await library.tags(forDocument: second.id).map(\.name)
        XCTAssertEqual(orphanedTags, [], "and the tag is left behind on the document nobody can find any more")
    }

    // MARK: - Batched indexing

    /// `indexDocuments` exists so a filesystem watcher re-walking a folder of many files
    /// can commit once instead of once per file. This proves the batch actually behaves
    /// like the sum of calling `indexDocument` for each file: new paths become documents,
    /// an already-known path updates in place, and the whole thing succeeds as one unit.
    func testIndexDocumentsBatchesMultipleFilesIntoOneCall() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)

        let existing = try await library.indexDocument(path: "/shelf/known.pdf", contentHash: "old", byteCount: 1, pageCount: 1, title: nil, author: nil)

        let records = try await library.indexDocuments([
            .init(path: "/shelf/known.pdf", contentHash: "new", byteCount: 2, pageCount: 1),
            .init(path: "/shelf/fresh-a.pdf", contentHash: "a", byteCount: 3, pageCount: 1),
            .init(path: "/shelf/fresh-b.pdf", contentHash: "b", byteCount: 4, pageCount: 1),
        ])

        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].id, existing.id, "an already-known path must update, not duplicate")
        XCTAssertEqual(records[0].contentHash, "new")
        XCTAssertEqual(try rawCount("documents", in: url), 3)
    }

    /// The whole point of batching: indexing the same new path twice within one call must
    /// see its own earlier write, updating rather than tripping the `locations` primary key
    /// or the `documents` row twice. If this failed, `indexDocuments` would not actually be
    /// safe to call with a real, possibly-messy batch from a scan.
    func testABatchSeesItsOwnEarlierInsertsRatherThanConflicting() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)

        let records = try await library.indexDocuments([
            .init(path: "/shelf/twice.pdf", contentHash: "first"),
            .init(path: "/shelf/twice.pdf", contentHash: "second"),
        ])

        XCTAssertEqual(records[0].id, records[1].id)
        XCTAssertEqual(try rawCount("documents", in: url), 1)
        let final = try await library.document(atPath: "/shelf/twice.pdf")
        XCTAssertEqual(final?.contentHash, "second", "the later entry in the same batch must win")
    }

    /// `indexDocuments` never deletes: a path missing from one batch might be on a drive
    /// that is not mounted right now, not a document that stopped existing.
    func testIndexDocumentsNeverRemovesAPathAbsentFromTheBatch() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)

        try await library.indexDocuments([.init(path: "/shelf/stays.pdf"), .init(path: "/shelf/unmounted-drive.pdf")])
        let vanished = try await library.document(atPath: "/shelf/unmounted-drive.pdf")
        XCTAssertNotNil(vanished)

        // A later watcher tick only finds one of the two files.
        try await library.indexDocuments([.init(path: "/shelf/stays.pdf")])

        let stillThere = try await library.document(atPath: "/shelf/unmounted-drive.pdf")
        XCTAssertEqual(stillThere?.id, vanished?.id, "a file absent from one scan must not be removed from the library")
    }

    func testIndexDocumentsWithNothingIsHarmless() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)
        let result = try await library.indexDocuments([])
        XCTAssertEqual(result, [])
    }

    // MARK: - Tags

    func testAddAndRemoveTags() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)
        let record = try await library.indexDocument(path: "/shelf/a.pdf", contentHash: "h", byteCount: 1, pageCount: 1, title: nil, author: nil)

        try await library.addTag("to-read", toDocument: record.id)
        try await library.addTag("distributed-systems", toDocument: record.id)
        try await library.addTag("to-read", toDocument: record.id) // adding twice must not duplicate

        let beforeRemoval = try await library.tags(forDocument: record.id)
        XCTAssertEqual(beforeRemoval.map(\.name), ["distributed-systems", "to-read"])

        try await library.removeTag("to-read", fromDocument: record.id)
        let afterRemoval = try await library.tags(forDocument: record.id)
        XCTAssertEqual(afterRemoval.map(\.name), ["distributed-systems"])
    }

    func testTagNamesAreCaseInsensitive() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)
        let record = try await library.indexDocument(path: "/shelf/a.pdf", contentHash: "h", byteCount: 1, pageCount: 1, title: nil, author: nil)

        try await library.addTag("Distributed-Systems", toDocument: record.id)
        try await library.addTag("distributed-systems", toDocument: record.id)

        let tags = try await library.tags(forDocument: record.id)
        XCTAssertEqual(tags.count, 1, "the same tag typed with different casing must collapse to one")
    }

    func testInvalidTagNameIsRejected() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)
        let record = try await library.indexDocument(path: "/shelf/a.pdf", contentHash: "h", byteCount: 1, pageCount: 1, title: nil, author: nil)

        do {
            try await library.addTag("   ", toDocument: record.id)
            XCTFail("a blank tag name should be rejected")
        } catch LibraryError.invalidTagName {
            // expected
        }
    }

    func testTaggingAnUnknownDocumentFails() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)

        do {
            try await library.addTag("to-read", toDocument: "does-not-exist")
            XCTFail("tagging a document that doesn't exist should fail")
        } catch {
            // Expected: the foreign key on document_tags.document_id rejects it, proving
            // `PRAGMA foreign_keys = ON` actually took effect on this connection.
        }
    }

    // MARK: - Projects

    func testCreateAndListProjectsInCreationOrder() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)

        let first = try await library.createProject(name: "Distributed systems", createdAt: Date(timeIntervalSince1970: 1))
        let second = try await library.createProject(name: "Compilers", createdAt: Date(timeIntervalSince1970: 2))

        let listed = try await library.projects()
        XCTAssertEqual(listed.map(\.id), [first.id, second.id])
        XCTAssertEqual(listed.map(\.name), ["Distributed systems", "Compilers"])
    }

    func testAddAndRemoveProjectMembers() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)
        let project = try await library.createProject(name: "Reading list")
        let bookA = try await library.indexDocument(path: "/shelf/a.pdf", contentHash: "a", byteCount: 1, pageCount: 1, title: "A", author: nil)
        let bookB = try await library.indexDocument(path: "/shelf/b.pdf", contentHash: "b", byteCount: 1, pageCount: 1, title: "B", author: nil)

        try await library.addMember(bookA.id, toProject: project.id, addedAt: Date(timeIntervalSince1970: 1))
        try await library.addMember(bookB.id, toProject: project.id, addedAt: Date(timeIntervalSince1970: 2))

        let members = try await library.members(ofProject: project.id)
        XCTAssertEqual(members.map(\.id), [bookA.id, bookB.id])

        try await library.removeMember(bookA.id, fromProject: project.id)
        let remaining = try await library.members(ofProject: project.id)
        XCTAssertEqual(remaining.map(\.id), [bookB.id])
    }

    func testAddingAnUnknownDocumentAsAProjectMemberFails() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)
        let project = try await library.createProject(name: "Reading list")

        do {
            try await library.addMember("does-not-exist", toProject: project.id)
            XCTFail("adding a document that was never indexed should fail")
        } catch {
            // Expected: the foreign key on project_members.document_id rejects it.
        }
    }

    // MARK: - Notes

    func testNotesRoundTrip() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)
        let record = try await library.indexDocument(path: "/shelf/a.pdf", contentHash: "h", byteCount: 1, pageCount: 1, title: nil, author: nil)

        let note = try await library.addNote("Reread chapter 4 before the meeting.", toDocument: record.id)
        let notesAfterAdd = try await library.notes(forDocument: record.id)
        XCTAssertEqual(notesAfterAdd.map(\.body), [note.body])

        try await library.removeNote(note.id)
        let notesAfterRemoval = try await library.notes(forDocument: record.id)
        XCTAssertTrue(notesAfterRemoval.isEmpty)
    }

    // MARK: - Extracted text and search

    /// Proves the FTS5 triggers actually re-sync the index on update, not merely on first
    /// insert: if the AFTER UPDATE trigger were missing its delete-then-reinsert step, the
    /// old text would keep matching after being replaced.
    func testExtractedTextAndFullTextSearchStayInSyncAcrossUpdates() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)

        let target = try await library.indexDocument(path: "/shelf/book.pdf", contentHash: "h1", byteCount: 10, pageCount: 1, title: "Book", author: nil)
        let decoy = try await library.indexDocument(path: "/shelf/other.pdf", contentHash: "h2", byteCount: 10, pageCount: 1, title: "Other", author: nil)
        try await library.setExtractedText("<!-- page:1 -->\nDistributed systems are hard to reason about.", forDocument: target.id)
        try await library.setExtractedText("<!-- page:1 -->\nA completely unrelated recipe for bread.", forDocument: decoy.id)

        let beforeReplace = try await library.fullTextSearch("distributed systems")
        XCTAssertEqual(beforeReplace.map(\.id), [target.id])

        try await library.setExtractedText("<!-- page:1 -->\nQuicksort partitions around a pivot.", forDocument: target.id)

        let staleSearch = try await library.fullTextSearch("distributed systems")
        XCTAssertTrue(staleSearch.isEmpty, "the old text must stop matching once it has been replaced")
        let freshSearch = try await library.fullTextSearch("quicksort partitions")
        XCTAssertEqual(freshSearch.map(\.id), [target.id])
        let decoySearch = try await library.fullTextSearch("bread")
        XCTAssertTrue(decoySearch.map(\.id).contains(decoy.id))
    }

    func testExtractedTextReadBack() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)
        let record = try await library.indexDocument(path: "/shelf/a.pdf", contentHash: "h", byteCount: 1, pageCount: 1, title: nil, author: nil)

        let beforeSet = try await library.extractedText(forDocument: record.id)
        XCTAssertNil(beforeSet)
        try await library.setExtractedText("<!-- page:1 -->\nHello.", forDocument: record.id)
        let afterSet = try await library.extractedText(forDocument: record.id)
        XCTAssertEqual(afterSet?.markdown, "<!-- page:1 -->\nHello.")
    }

    // MARK: - Durability and concurrency

    func testReopeningTheDatabasePreservesEverything() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let record: DocumentRecord
        do {
            let library = try Library(url: url)
            record = try await library.indexDocument(path: "/shelf/a.pdf", contentHash: "h", byteCount: 1, pageCount: 1, title: "A", author: nil)
            try await library.addTag("to-read", toDocument: record.id)
        }

        // A fresh connection, as a relaunch of the app (or the MCP server, in its own
        // process) would open. Reopening must not re-run the schema migration, which would
        // fail on `CREATE TABLE` the second time if the version guard were broken.
        let reopened = try Library(url: url)
        let reread = try await reopened.document(id: record.id)
        XCTAssertEqual(reread?.title, "A")
        let rereadTags = try await reopened.tags(forDocument: record.id)
        XCTAssertEqual(rereadTags.map(\.name), ["to-read"])
    }

    /// The situation the MCP server creates: a second, independent connection to the same
    /// file, writing at the same time as the first. WAL plus `busy_timeout` should make both
    /// sides succeed rather than one losing its write to a race.
    func testTwoConnectionsInterleaveWritesSafely() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let libraryA = try Library(url: url)
        let libraryB = try Library(url: url)
        let countEach = 25

        async let writesA: Void = writeMany(prefix: "a", count: countEach, using: libraryA)
        async let writesB: Void = writeMany(prefix: "b", count: countEach, using: libraryB)
        _ = try await (writesA, writesB)

        let verifier = try Library(url: url)
        for index in 0..<countEach {
            let recordA = try await verifier.document(atPath: "/shelf/a-\(index).pdf")
            XCTAssertNotNil(recordA, "write \(index) from connection A should have persisted")
            let recordB = try await verifier.document(atPath: "/shelf/b-\(index).pdf")
            XCTAssertNotNil(recordB, "write \(index) from connection B should have persisted")
        }
        XCTAssertEqual(try rawCount("documents", in: url), countEach * 2,
                       "every write from both connections must be present, none lost to a race")
    }

    private func writeMany(prefix: String, count: Int, using library: Library) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    try await library.indexDocument(
                        path: "/shelf/\(prefix)-\(index).pdf",
                        contentHash: "hash-\(prefix)-\(index)",
                        byteCount: index, pageCount: 1, title: nil, author: nil
                    )
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Opening the library

    func testAnUnwritableLocationThrowsInsteadOfCrashing() {
        // A plain file where a directory needs to go: creating the parent necessarily
        // fails, which is the shape "cannot be opened" actually takes in practice.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-blocker-\(UUID().uuidString)")
        try? Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }

        XCTAssertThrowsError(try Library(url: blocker.appendingPathComponent("library.sqlite")))
    }

    // MARK: - Schema room for other work

    func testTheSpendLedgerTableHasTheAgreedColumns() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)

        let columns = try await library.columnNames(ofTable: "spend_ledger")
        XCTAssertEqual(columns, [
            "id", "at", "model", "endpoint", "feature",
            "input_tokens", "output_tokens", "cached_tokens", "reasoning_tokens",
            "cost", "currency", "succeeded",
        ])
    }

    func testTheDismissedDuplicatesTableHasTheAgreedColumns() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)

        let columns = try await library.columnNames(ofTable: "dismissed_duplicates")
        XCTAssertEqual(columns, ["group_id", "dismissed_at"])
    }
}

/// The kept-bibliography table, against a real database. A generated entry is cheap to
/// rebuild; one a person corrected is not, so losing it is the failure that matters.
final class LibraryBibtexTests: XCTestCase {

    private func library() throws -> (Library, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bib-\(UUID().uuidString).sqlite")
        return (try Library(url: url), url)
    }

    private func document(in library: Library) async throws -> String {
        try await library.indexDocument(path: "/tmp/a-book-\(UUID().uuidString).pdf",
                                        contentHash: nil, title: "A Book").id
    }

    func testAnEntryIsKeptAndReadBack() async throws {
        let (library, url) = try library()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try await document(in: library)

        let before = try await library.bibtex(forDocument: id)
        XCTAssertNil(before)
        try await library.storeBibtex("@book{a, title = {A}}", forDocument: id, origin: "you")

        let storedMaybe = try await library.bibtex(forDocument: id)
        let stored = try XCTUnwrap(storedMaybe)
        XCTAssertEqual(stored.entry, "@book{a, title = {A}}")
        XCTAssertEqual(stored.origin, "you")
    }

    /// Storing again replaces rather than failing on the primary key or making a second row.
    func testStoringAgainReplaces() async throws {
        let (library, url) = try library()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try await document(in: library)

        try await library.storeBibtex("@book{a}", forDocument: id, origin: "you")
        try await library.storeBibtex("@article{a}", forDocument: id, origin: "the model")

        let storedMaybe = try await library.bibtex(forDocument: id)
        let stored = try XCTUnwrap(storedMaybe)
        XCTAssertEqual(stored.entry, "@article{a}")
        XCTAssertEqual(stored.origin, "the model")
        let all = try await library.storedBibtex()
        XCTAssertEqual(all.count, 1)
    }

    /// A kept entry has to survive the app being quit, which is the whole point of keeping it.
    func testAKeptEntrySurvivesReopening() async throws {
        let (library, url) = try library()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try await document(in: library)
        try await library.storeBibtex("@book{kept}", forDocument: id, origin: "you")

        let reopened = try Library(url: url)
        let storedMaybe = try await reopened.bibtex(forDocument: id)
        let stored = try XCTUnwrap(storedMaybe)
        XCTAssertEqual(stored.entry, "@book{kept}")
    }

    func testRemovingAnEntryLeavesTheDocumentAlone() async throws {
        let (library, url) = try library()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try await document(in: library)
        try await library.storeBibtex("@book{a}", forDocument: id, origin: "you")

        try await library.removeBibtex(forDocument: id)
        let gone = try await library.bibtex(forDocument: id)
        let document = try await library.document(id: id)
        XCTAssertNil(gone)
        XCTAssertNotNil(document, "the document itself stays")
    }

    /// The migration has to run on a database made by the previous version, not only on a
    /// fresh one, or an existing library loses the feature silently.
    func testAnOlderDatabaseGainsTheTable() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bib-old-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try Library(url: url)                      // creates it at the current version
        let reopened = try Library(url: url)           // and again, which must not re-run
        let id = try await reopened.indexDocument(path: "/tmp/x.pdf", contentHash: nil).id
        try await reopened.storeBibtex("@book{x}", forDocument: id, origin: "you")
        let kept = try await reopened.storedBibtex()
        XCTAssertEqual(kept.count, 1)
    }
}
