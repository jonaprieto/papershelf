import XCTest
import SQLite3
@testable import PaperShelfCore

final class LibraryTests: XCTestCase {

    // MARK: - Fixtures

    /// A database file under a throwaway directory, never the real Application Support one.
    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName("library-tests"), isDirectory: true)
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

    func testAPartialRescanDoesNotEraseKnownMetadata() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)

        let original = try await library.indexDocument(
            path: "/shelf/known.pdf", contentHash: "hash", byteCount: 100,
            pageCount: 12, title: "Known title", author: "Known author",
            documentInfo: ["Producer": "Quartz"]
        )
        let rescanned = try await library.indexDocument(
            path: "/shelf/known.pdf", contentHash: nil, byteCount: 120
        )

        XCTAssertEqual(rescanned.id, original.id)
        XCTAssertEqual(rescanned.byteCount, 120)
        XCTAssertEqual(rescanned.pageCount, 12)
        XCTAssertEqual(rescanned.title, "Known title")
        XCTAssertEqual(rescanned.author, "Known author")
        XCTAssertEqual(rescanned.documentInfo, ["Producer": "Quartz"])
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

    func testProjectQueriesAnswerMembershipAndCountsInOneResult() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)
        let first = try await library.createProject(name: "First")
        let second = try await library.createProject(name: "Second")
        let book = try await library.indexDocument(path: "/shelf/a.pdf", contentHash: "a")

        try await library.addMember(book.id, toProject: first.id)
        try await library.addMember(book.id, toProject: second.id)

        let memberships = try await library.projects(containingDocument: book.id)
        let counts = try await library.projectMemberCounts()
        XCTAssertEqual(memberships.map(\.name), ["First", "Second"])
        XCTAssertEqual(counts, [first.id: 1, second.id: 1])
    }

    /// What the indexer asks before it starts: every path, the document it belongs to,
    /// and whether its text has been read. One query, because the alternative is one per
    /// file across fourteen thousand of them.
    func testTheIndexReportsWhatStillHasNoText() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)
        let read = try await library.indexDocument(path: "/shelf/read.pdf", contentHash: "a")
        _ = try await library.indexDocument(path: "/shelf/unread.pdf", contentHash: "b")

        try await library.setExtractedText([(documentID: read.id, markdown: "a theorem here")])

        let rows = try await library.textIndexRows().sorted { $0.path < $1.path }
        XCTAssertEqual(rows.map(\.path), ["/shelf/read.pdf", "/shelf/unread.pdf"])
        XCTAssertNotNil(rows.first?.extractedAt)
        XCTAssertNil(rows.last?.extractedAt, "nothing has read this one yet")
        let indexed = try await library.indexedTextCount()
        XCTAssertEqual(indexed, 1)

        // The batch write goes through the same triggers a single write does, so what it
        // stores is searchable immediately.
        let found = try await library.fullTextSearch("theorem")
        XCTAssertEqual(found.map(\.id), [read.id])
    }

    /// The two questions the shelf asks the store once a query mentions the inside of a
    /// document: which documents say this anywhere, and which say it where a paper puts
    /// its abstract.
    func testTextAndAbstractSearchesAnswerWithDocumentIDs() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)
        let paper = try await library.indexDocument(path: "/shelf/paper.pdf", contentHash: "a")
        let book = try await library.indexDocument(path: "/shelf/book.pdf", contentHash: "b")

        let opening = "A survey of stochastic epidemic models. "
        try await library.setExtractedText([
            (documentID: paper.id, markdown: opening + String(repeating: "body ", count: 900) + "hapax"),
            (documentID: book.id, markdown: "An introduction to choreographies."),
        ])

        let hapax = try await library.documentIDsMatchingText("hapax")
        let choreographies = try await library.documentIDsMatchingText("choreographies")
        let stochastic = try await library.documentIDsMatchingAbstract("stochastic")
        XCTAssertEqual(hapax, [paper.id])
        XCTAssertEqual(choreographies, [book.id])
        XCTAssertEqual(stochastic, [paper.id])
        let deepInAbstract = try await library.documentIDsMatchingAbstract("hapax")
        XCTAssertTrue(deepInAbstract.isEmpty, "past the opening is not the abstract")
        // A search box is not a place to escape SQL: a wildcard is a character to find.
        let wildcard = try await library.documentIDsMatchingAbstract("%")
        XCTAssertTrue(wildcard.isEmpty)
    }

    /// What a search needs about a file the shelf listed but never opened.
    func testTotalsCountWhatTheLibraryHolds() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)
        _ = try await library.indexDocument(path: "/shelf/a.pdf", contentHash: "a", byteCount: 1_000)
        _ = try await library.indexDocument(path: "/shelf/b.pdf", contentHash: "b", byteCount: 2_500)
        // A document whose size nothing has read counts as a document and as no bytes,
        // rather than as a guess.
        _ = try await library.indexDocument(path: "/shelf/c.pdf", contentHash: "c")

        let totals = try await library.totals()

        XCTAssertEqual(totals, LibraryTotals(documents: 3, bytes: 3_500))
    }

    func testDocumentFactsComeBackByPath() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)
        _ = try await library.indexDocument(path: "/shelf/known.pdf", contentHash: "a",
                                            pageCount: 240, title: "Causality",
                                            author: "Judea Pearl")
        _ = try await library.indexDocument(path: "/shelf/bare.pdf", contentHash: "b")

        let facts = try await library.documentFactsByPath()
        XCTAssertEqual(facts["/shelf/known.pdf"],
                       DocumentFacts(pageCount: 240, title: "Causality", author: "Judea Pearl"))
        XCTAssertEqual(facts["/shelf/bare.pdf"],
                       DocumentFacts(pageCount: nil, title: nil, author: nil))
    }

    func testDroppingPathsOnAProjectAddsOnlyTheOnesTheLibraryKnows() async throws {
        let url = try makeDatabaseURL()
        defer { tearDownDatabase(url) }
        let library = try Library(url: url)
        let project = try await library.createProject(name: "Reading list")
        let book = try await library.indexDocument(path: "/shelf/a.pdf", contentHash: "a")

        let added = try await library.addMembers(paths: ["/shelf/a.pdf", "/shelf/gone.pdf"],
                                                 toProject: project.id)

        XCTAssertEqual(added, 1)
        let members = try await library.members(ofProject: project.id)
        XCTAssertEqual(members.map(\.id), [book.id])
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
            .appendingPathComponent(scratchName("library-blocker"))
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
    ///
    /// The database is built by hand at version 2 rather than by opening a Library, since
    /// opening one migrates it straight to the current schema and the test would then be
    /// checking nothing: it passed identically with the migration deleted.
    func testAVersionTwoDatabaseGainsTheTable() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bib-v2-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle,
                                       SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        let older = """
            CREATE TABLE documents (
                id TEXT PRIMARY KEY, first_seen_at TEXT NOT NULL, last_seen_at TEXT NOT NULL,
                content_hash TEXT, byte_count INTEGER, page_count INTEGER, title TEXT,
                author TEXT, document_info TEXT NOT NULL DEFAULT '{}'
            );
            CREATE TABLE locations (
                path TEXT PRIMARY KEY,
                document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                first_seen_at TEXT NOT NULL, last_seen_at TEXT NOT NULL
            );
            -- A real version 2 database has all of version 1's tables, and later
            -- migrations alter them. A fixture holding only the two tables this test
            -- reads is not a version 2 database, it is a fiction that migrates
            -- differently, which is how this test caught itself.
            CREATE TABLE projects (
                id INTEGER PRIMARY KEY, name TEXT NOT NULL, created_at TEXT NOT NULL
            );
            CREATE TABLE project_members (
                project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                added_at TEXT NOT NULL,
                PRIMARY KEY (project_id, document_id)
            );
            PRAGMA user_version = 2;
            """
        XCTAssertEqual(sqlite3_exec(handle, older, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        // Opening it must bring it forward rather than leaving the feature missing.
        let library = try Library(url: url)
        let id = try await library.indexDocument(path: "/tmp/x.pdf", contentHash: nil).id
        try await library.storeBibtex("@book{x}", forDocument: id, origin: "you")
        let kept = try await library.storedBibtex()
        XCTAssertEqual(kept.count, 1)
    }

}

/// Tags as an organising tool, and the sections that make a reading project a reading
/// list rather than a folder with extra steps.
final class LibraryTagsAndSectionsTests: XCTestCase {

    private func library() throws -> (Library, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tags-\(UUID().uuidString).sqlite")
        return (try Library(url: url), url)
    }

    private func document(_ library: Library, _ name: String) async throws -> String {
        try await library.indexDocument(path: "/tmp/\(name).pdf", contentHash: nil,
                                        title: name).id
    }

    func testTagsAreCountedByHowMuchTheyAreUsed() async throws {
        let (library, url) = try library()
        defer { try? FileManager.default.removeItem(at: url) }
        let a = try await document(library, "a")
        let b = try await document(library, "b")

        try await library.addTag("crdt", toDocument: a)
        try await library.addTag("crdt", toDocument: b)
        try await library.addTag("to-read", toDocument: a)

        let counts = try await library.tagCounts()
        XCTAssertEqual(counts.map(\.name), ["crdt", "to-read"], "most used first")
        XCTAssertEqual(counts.first?.documents, 2)
    }

    func testClickingATagFindsItsDocuments() async throws {
        let (library, url) = try library()
        defer { try? FileManager.default.removeItem(at: url) }
        let a = try await document(library, "a")
        _ = try await document(library, "b")
        try await library.addTag("crdt", toDocument: a)

        let found = try await library.documents(taggedWith: "CRDT")
        XCTAssertEqual(found.map(\.id), [a], "tags are matched whatever case they are typed in")
    }

    /// A typo otherwise splits a shelf in two, and merging is what fixes it.
    func testRenamingATagOntoAnExistingOneMergesThem() async throws {
        let (library, url) = try library()
        defer { try? FileManager.default.removeItem(at: url) }
        let a = try await document(library, "a")
        let b = try await document(library, "b")
        try await library.addTag("crdt", toDocument: a)
        try await library.addTag("crdts", toDocument: b)

        try await library.renameTag("crdts", to: "crdt")

        let counts = try await library.tagCounts()
        XCTAssertEqual(counts.map(\.name), ["crdt"])
        XCTAssertEqual(counts.first?.documents, 2)
    }

    func testDeletingATagTakesItOffEveryDocument() async throws {
        let (library, url) = try library()
        defer { try? FileManager.default.removeItem(at: url) }
        let a = try await document(library, "a")
        try await library.addTag("crdt", toDocument: a)

        try await library.deleteTag("crdt")
        let remaining = try await library.tags(forDocument: a)
        let counts = try await library.tagCounts()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(counts.isEmpty)
    }

    func testADocumentCanBeFiledUnderASectionOfAProject() async throws {
        let (library, url) = try library()
        defer { try? FileManager.default.removeItem(at: url) }
        let project = try await library.createProject(name: "Consistency")
        let a = try await document(library, "a")
        let b = try await document(library, "b")

        try await library.setSection("background", forDocument: a, inProject: project.id)
        // Filed under nothing is a real state: adding must not be a two-step decision.
        try await library.setSection(nil, forDocument: b, inProject: project.id)

        let members = try await library.sectionedMembers(ofProject: project.id)
        XCTAssertEqual(members.count, 2)
        XCTAssertEqual(members.first(where: { $0.0.id == a })?.1, "background")
        XCTAssertNil(members.first(where: { $0.0.id == b })?.1)
        let sections = try await library.sections(ofProject: project.id)
        XCTAssertEqual(sections, ["background"])
    }

    func testRefilingADocumentMovesItRatherThanAddingItTwice() async throws {
        let (library, url) = try library()
        defer { try? FileManager.default.removeItem(at: url) }
        let project = try await library.createProject(name: "P")
        let a = try await document(library, "a")

        try await library.setSection("background", forDocument: a, inProject: project.id)
        try await library.setSection("read next", forDocument: a, inProject: project.id)

        let members = try await library.sectionedMembers(ofProject: project.id)
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members.first?.1, "read next")
    }
}

/// Resolving a shelf of files to the documents behind them used to be one query per file.
/// This is the one that replaced them.
final class DocumentIDsByPathTests: XCTestCase {

    private func makeLibrary() throws -> (Library, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName("ids-by-path"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("library.sqlite")
        return (try Library(url: url), directory)
    }

    func testEveryKnownPathComesBackWithItsDocument() async throws {
        let (library, directory) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try await library.indexDocument(path: "/tmp/shelf/a.pdf", contentHash: "aaa")
        let second = try await library.indexDocument(path: "/tmp/shelf/b.pdf", contentHash: "bbb")

        let byPath = try await library.documentIDsByPath()
        XCTAssertEqual(byPath["/tmp/shelf/a.pdf"], first.id)
        XCTAssertEqual(byPath["/tmp/shelf/b.pdf"], second.id)
        XCTAssertNil(byPath["/tmp/shelf/never-seen.pdf"])
    }

    /// A renamed document is known at both paths, which is what lets it keep its tags.
    /// Both have to come back, or the catalogue resolves the file under its new name to
    /// nothing and shows it as untagged.
    func testARenamedDocumentIsKnownAtEveryPathItHasHad() async throws {
        let (library, directory) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = try await library.indexDocument(path: "/tmp/shelf/old.pdf", contentHash: "same")
        try await library.recordLocation("/tmp/shelf/new.pdf", forDocument: original.id)

        let byPath = try await library.documentIDsByPath()
        XCTAssertEqual(byPath["/tmp/shelf/old.pdf"], original.id)
        XCTAssertEqual(byPath["/tmp/shelf/new.pdf"], original.id,
                       "the same document, so the same id at both paths")
    }

    func testAnEmptyLibraryKnowsNoPaths() async throws {
        let (library, directory) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }

        let byPath = try await library.documentIDsByPath()
        XCTAssertTrue(byPath.isEmpty)
    }
}

/// Where the reader got to. The app knew which page was on screen and forgot it on
/// close, which is why the shelf had no way to say which books are open.
final class ReadingPositionTests: XCTestCase {

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName("reading-position-tests"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("library.sqlite")
    }

    func testAPositionSurvivesAndUpdatesInPlace() async throws {
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let library = try Library(url: url)
        let id = try await library.indexDocument(path: "/books/pearl.pdf", contentHash: "a",
                                                 byteCount: 10, pageCount: 248).id
        try await library.rememberReadingPosition(documentID: id, page: 12, pageCount: 248)
        try await library.rememberReadingPosition(documentID: id, page: 40, pageCount: 248)
        let position = try await library.readingPosition(forDocument: id)
        XCTAssertEqual(position?.page, 40)
        XCTAssertEqual(position?.pageCount, 248)
    }

    /// A book opened and a book finished are both not "reading now".
    func testOnlyAPartReadDocumentCountsAsBeingRead() {
        let opened = ReadingPosition(documentID: "a", page: 1, pageCount: 248, updatedAt: Date())
        let midway = ReadingPosition(documentID: "b", page: 12, pageCount: 248, updatedAt: Date())
        let finished = ReadingPosition(documentID: "c", page: 248, pageCount: 248, updatedAt: Date())
        XCTAssertFalse(opened.isInProgress)
        XCTAssertTrue(midway.isInProgress)
        XCTAssertFalse(finished.isInProgress)
    }

    func testProgressIsMeasuredFromThePageTurnedTo() {
        XCTAssertEqual(ReadingPosition(documentID: "a", page: 1, pageCount: 101,
                                       updatedAt: Date()).fraction, 0)
        XCTAssertEqual(ReadingPosition(documentID: "a", page: 51, pageCount: 101,
                                       updatedAt: Date()).fraction, 0.5)
        XCTAssertNil(ReadingPosition(documentID: "a", page: 3, pageCount: nil,
                                     updatedAt: Date()).fraction)
    }

    /// A renamed book is still the book you were reading, so every path it is known at
    /// answers.
    func testEveryPathOfAPartReadDocumentAnswers() async throws {
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let library = try Library(url: url)
        let id = try await library.indexDocument(path: "/in/old.pdf", contentHash: "a",
                                                 byteCount: 10, pageCount: 100).id
        // What a rename does: the new path is attached to the document that was already
        // known under the old one, rather than a second document being invented.
        try await library.recordLocation("/in/2009-new.pdf", forDocument: id)
        try await library.rememberReadingPosition(documentID: id, page: 12, pageCount: 100)
        let paths = try await library.pathsBeingRead()
        XCTAssertTrue(paths.contains("/in/old.pdf"))
        XCTAssertTrue(paths.contains("/in/2009-new.pdf"))
    }

    func testAFinishedBookIsNotOfferedAsBeingRead() async throws {
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let library = try Library(url: url)
        let id = try await library.indexDocument(path: "/in/done.pdf", contentHash: "z",
                                                 byteCount: 10, pageCount: 100).id
        try await library.rememberReadingPosition(documentID: id, page: 100, pageCount: 100)
        let reading = try await library.pathsBeingRead()
        XCTAssertTrue(reading.isEmpty)
    }

    func testRecentlyAddedIsAboutWhenTheLibraryMetTheFile() async throws {
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let library = try Library(url: url)
        _ = try await library.indexDocument(path: "/in/new.pdf", contentHash: "n", byteCount: 1)
        let recent = try await library.pathsFirstSeen(since: Date().addingTimeInterval(-3600))
        XCTAssertEqual(recent, ["/in/new.pdf"])
        let future = try await library.pathsFirstSeen(since: Date().addingTimeInterval(3600))
        XCTAssertTrue(future.isEmpty)
    }
}

/// A small on-disk shelf, not synthetic database rows: catches regressions where a
/// real multi-file scan reports the wrong document or text-search counts.
final class PDFShelfFixtureTests: XCTestCase {
    func testSeveralPDFsStaySearchableAndScansStayUnindexed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName("pdf-shelf-fixtures"), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library(url: root.appendingPathComponent("library.sqlite"))

        let textFixtures = [
            ("papers/consistency.pdf", "strong eventual consistency and replication"),
            ("papers/notes.pdf", "reading notes and semantic highlights"),
            ("copies/consistency-copy.pdf", "strong eventual consistency and replication"),
        ]
        for (relative, text) in textFixtures {
            let file = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try makeTextPDF(at: file, text: text)
            let record = try await library.indexDocument(
                path: file.path, contentHash: relative,
                byteCount: try Data(contentsOf: file).count, pageCount: 1)
            try await library.setExtractedText(text, forDocument: record.id)
        }

        let scan = root.appendingPathComponent("scans/invoice.pdf")
        try FileManager.default.createDirectory(at: scan.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try makePDF(at: scan, password: nil)
        _ = try await library.indexDocument(path: scan.path, contentHash: "scan",
                                            byteCount: try Data(contentsOf: scan).count,
                                            pageCount: 1)

        let summary = try await library.summary()
        XCTAssertEqual(summary.documents, 4)
        XCTAssertEqual(summary.withText, 3)
        let consistency = try await library.fullTextSearch("eventual consistency")
        let invoices = try await library.fullTextSearch("invoice")
        XCTAssertEqual(consistency.count, 2)
        XCTAssertTrue(invoices.isEmpty)
    }
}
