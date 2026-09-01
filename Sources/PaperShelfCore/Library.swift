import Foundation
import SQLite3
import os

/// The one durable store for everything that outlives a single scan: which documents the
/// user has seen, the paths those documents have lived at, tags, reading projects, notes,
/// and extracted text for search. Everything else in this app (`RunCache`, `Item`) is a
/// preview of the present; this is the record of it.
///
/// IDENTITY: a document's `id` is a freshly generated UUID string, stored once and never
/// recomputed. It is deliberately NOT the content hash. This app decrypts PDFs and writes
/// highlights straight into the file (`Annotations.swift`), so a document's bytes change
/// under ordinary use; keying identity on a hash would mean every highlight silently
/// orphans that document's own tags and notes. The hash, the byte count, the page count and
/// the known paths are all LOCATORS recorded on the row, updated freely as they change; the
/// row itself, and everything hung off its `id`, does not move. `indexDocument` proves this
/// by resolving identity through the path (via `locations`) first: a known path always maps
/// back to the same row, so re-indexing a changed file updates that row's locators in place
/// rather than creating a second one. A path that genuinely refers to a *different* document
/// under the same name (rare, but the length-floor problem `contentKey` already has to dodge
/// applies here too) is out of scope for this store to guess at; nothing here invents a
/// hash-matching heuristic to merge or split rows, on purpose, because a wrong guess in that
/// direction is exactly the silent-data-loss failure this design exists to avoid. When a
/// future caller *knows* a path now names a document already known under a different path
/// (the app's own decrypt-and-rename, for instance, knows both ends of that move), it says so
/// explicitly with `recordLocation`, rather than this store inferring it.
///
/// SEARCH: `fullTextSearch` mirrors the one thing in `Search.swift`'s `Query` grammar it can
/// answer, the `text:` field, which is itself already a literal run of words rather than a
/// bag of independent terms (see `matches(_:_:)`, the `"text"` case, a substring scan). It
/// does not reimplement `Query`'s other fields (`name`, `folder`, `size`, `pages`, `status`,
/// `year`): those describe filesystem and PDF metadata carried on `Item`, not on anything
/// this store persists, so a caller wanting both narrows with `Query`'s own `matches(_:_:)`
/// over `Item` and this store's `fullTextSearch` over extracted text, rather than one
/// function trying to be both.
public actor Library {

    // MARK: - Connection

    /// The one place this connection is ever touched outside actor isolation, which is to
    /// say never. The system SQLite reports
    /// `sqlite3_threadsafe() == 2` ("multi-thread"), not 3 ("serialized"): distinct
    /// connections may run on distinct threads at once, but a single connection must never
    /// be entered by two threads at the same instant. Wrapping the connection in an actor,
    /// and never storing or handing it out anywhere but here, makes that the only outcome
    /// the compiler will produce: every call funnels through this actor's serial executor,
    /// and nothing in this file ever passes `db` to a `DispatchQueue`, `Task.detached`, or
    /// anything else that would let it run outside actor isolation. Cross-process safety (a
    /// GUI connection and a separate MCP server connection, both open at once) is a
    /// different mechanism, WAL, verified separately; this actor only has to answer for
    /// what happens inside one process.
    /// Not private: `Spend.swift` and `Duplicates.swift` add their own tables' accessors
    /// as extensions on this actor, and an extension in another file is still isolated to
    /// it, so the guarantee below is unchanged. What must stay true is that nothing hands
    /// this pointer to a DispatchQueue, a Task.detached, or anything else that would run it
    /// outside this actor.
    var db: OpaquePointer?

    public init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "sqlite code \(result)"
            if let handle { sqlite3_close(handle) }
            throw LibraryError.openFailed(message)
        }
        // A second process (or, in a test, a second connection) WILL write to this file
        // while this one holds it open; five seconds of automatic retry inside SQLite beats
        // an immediate SQLITE_BUSY thrown back at every caller.
        sqlite3_busy_timeout(handle, 5000)
        // Pragmas and migration run here, against the local `handle`, rather than through
        // this actor's own isolated methods: before `self.db` is assigned below, `self`
        // is not yet a constructed actor for anything to be isolated against, and nothing
        // else can be holding a reference to it yet either way.
        do {
            try prepareConnection(handle)
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
        self.db = handle
    }

    deinit {
        // No other reference to this actor can exist by the time deinit runs, so touching
        // `db` here without `await` is exactly as safe as anywhere else in this file.
        if let db { sqlite3_close_v2(db) }
    }

    /// Opened at most once per process, at the standard location (`libraryDatabaseURL`).
    /// `nil` means the rest of the app runs exactly as it did before this file existed: tags,
    /// notes, projects, and rename-safe identity are simply unavailable for this run, while
    /// reading, renaming, and converting PDFs, none of which depend on this actor, keep
    /// working exactly as before. The failure is logged once, here, by construction, rather
    /// than surfaced every time some feature would otherwise have gone through the library.
    public static let shared: Library? = {
        guard let url = libraryDatabaseURL() else {
            Library.logUnavailable("no Application Support directory available")
            return nil
        }
        do {
            return try Library(url: url)
        } catch {
            Library.logUnavailable("\(error)")
            return nil
        }
    }()

    private static func logUnavailable(_ reason: String) {
        Logger(subsystem: "com.jonaprieto.pdfhammer", category: "library")
            .error("library unavailable, continuing without it: \(reason, privacy: .public)")
    }

    // MARK: - Schema

    /// One entry per schema version, applied in order inside its own transaction, each
    /// followed by bumping `PRAGMA user_version` to match. Adding the spend ledger or the
    /// dismissed-duplicate-pairs table later is exactly one more string appended here; the
    /// rest of this type does not change shape to make room for it.
    fileprivate static let migrations: [String] = [schemaV1, schemaV2, schemaV3, schemaV4,
                                                   schemaV5, schemaV6, schemaV7]

    fileprivate static let schemaV1 = """
        CREATE TABLE documents (
            id             TEXT PRIMARY KEY,
            first_seen_at  TEXT NOT NULL,
            last_seen_at   TEXT NOT NULL,
            content_hash   TEXT,
            byte_count     INTEGER,
            page_count     INTEGER,
            title          TEXT,
            author         TEXT,
            document_info  TEXT NOT NULL DEFAULT '{}'
        );

        CREATE TABLE locations (
            path           TEXT PRIMARY KEY,
            document_id    TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            first_seen_at  TEXT NOT NULL,
            last_seen_at   TEXT NOT NULL
        );
        CREATE INDEX locations_by_document ON locations(document_id);

        CREATE TABLE tags (
            id   INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE COLLATE NOCASE
        );

        CREATE TABLE document_tags (
            document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            tag_id      INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
            PRIMARY KEY (document_id, tag_id)
        );

        CREATE TABLE projects (
            id         INTEGER PRIMARY KEY,
            name       TEXT NOT NULL,
            created_at TEXT NOT NULL
        );

        CREATE TABLE project_members (
            project_id  INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            added_at    TEXT NOT NULL,
            PRIMARY KEY (project_id, document_id)
        );

        CREATE TABLE notes (
            id          INTEGER PRIMARY KEY,
            document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            body        TEXT NOT NULL,
            created_at  TEXT NOT NULL,
            updated_at  TEXT NOT NULL
        );

        CREATE TABLE extracted_text (
            document_id  TEXT PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE,
            markdown     TEXT NOT NULL,
            extracted_at TEXT NOT NULL
        );

        CREATE VIRTUAL TABLE extracted_text_fts USING fts5(
            markdown, content='extracted_text', content_rowid='rowid'
        );

        CREATE TRIGGER extracted_text_ai AFTER INSERT ON extracted_text BEGIN
            INSERT INTO extracted_text_fts(rowid, markdown) VALUES (new.rowid, new.markdown);
        END;
        CREATE TRIGGER extracted_text_ad AFTER DELETE ON extracted_text BEGIN
            INSERT INTO extracted_text_fts(extracted_text_fts, rowid, markdown) VALUES('delete', old.rowid, old.markdown);
        END;
        CREATE TRIGGER extracted_text_au AFTER UPDATE ON extracted_text BEGIN
            INSERT INTO extracted_text_fts(extracted_text_fts, rowid, markdown) VALUES('delete', old.rowid, old.markdown);
            INSERT INTO extracted_text_fts(rowid, markdown) VALUES (new.rowid, new.markdown);
        END;
        """

    /// Schema room for two pieces of work that need a table each and cannot touch this file:
    /// an AI-spend ledger and a set of dismissed duplicate pairs. No accessors for either are
    /// added here on purpose, whichever feature reads and writes them adds its own
    /// `extension Library` in its own file, the same way this file's own methods below are
    /// the only ones allowed to touch `documents`/`locations`/`tags`/etc.
    fileprivate static let schemaV2 = """
        -- One row per model call. `cost` is stored as TEXT, an exact decimal string, so
        -- money is never subject to floating-point error; `currency` keeps a call priced in
        -- a non-USD rate from being silently summed as if it were dollars.
        CREATE TABLE spend_ledger (
            id               INTEGER PRIMARY KEY,
            at               TEXT NOT NULL,
            model            TEXT NOT NULL,
            endpoint         TEXT NOT NULL,
            feature          TEXT NOT NULL,
            input_tokens     INTEGER NOT NULL,
            output_tokens    INTEGER NOT NULL,
            cached_tokens    INTEGER NOT NULL,
            reasoning_tokens INTEGER NOT NULL,
            -- null when no price is known for that model: an unknown cost is not a cost
            -- of zero, and recording it as zero is the exact failure this table exists to
            -- avoid.
            cost             TEXT,
            currency         TEXT,
            succeeded        INTEGER NOT NULL
        );

        -- Keyed on the match's own id rather than on a pair of documents: a duplicate
        -- group can hold three copies as easily as two, and DuplicateGroup.id is already
        -- derived from what made them match, so it survives a relaunch and a rename
        -- without needing the documents to have been indexed first.
        CREATE TABLE dismissed_duplicates (
            group_id     TEXT PRIMARY KEY,
            dismissed_at TEXT NOT NULL
        );
        """

    /// A bibliography entry the user kept, so it survives a relaunch and can be exported
    /// without being regenerated from a filename that may since have changed.
    fileprivate static let schemaV3 = """
        CREATE TABLE bibtex_entries (
            document_id TEXT PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE,
            entry       TEXT NOT NULL,
            -- where it came from: generated, a registry, or the model.
            origin      TEXT NOT NULL,
            updated_at  TEXT NOT NULL
        );
        """

    /// A section within a reading project.
    ///
    /// A project of forty papers in one flat list is a folder with extra steps. A section
    /// is what makes it a reading list: "background", "to read", "cited by chapter 3".
    /// Null means the document is in the project but not filed under anything yet, which
    /// has to stay possible or adding one would become a two-step decision.
    fileprivate static let schemaV4 = """
        ALTER TABLE project_members ADD COLUMN section TEXT;
        """

    /// How far into a document a person has read.
    ///
    /// The app knew which page was on screen and forgot it the moment the window closed,
    /// which is why "Reading Now" could not exist and the Info panel had nothing to say
    /// about progress. Keyed on the document rather than the path, like everything else
    /// here, so a book renamed halfway through is still the book you were reading.
    fileprivate static let schemaV5 = """
        CREATE TABLE reading_positions (
            document_id TEXT PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE,
            page        INTEGER NOT NULL,
            page_count  INTEGER,
            updated_at  TEXT NOT NULL
        );
        """

    /// `document_tags` and `project_members` are keyed so SQLite only indexes their
    /// leading column for free (the tag lookup and the project lookup respectively);
    /// asking "which documents carry this tag" or "which projects hold this document"
    /// walks the whole table without an index of its own.
    fileprivate static let schemaV6 = """
        CREATE INDEX IF NOT EXISTS document_tags_by_tag ON document_tags(tag_id);
        CREATE INDEX IF NOT EXISTS project_members_by_document ON project_members(document_id);
        """

    /// Which producer wrote a row's text, so text stored before page markers existed can be
    /// found and read again. Nullable and unbacked by a default on purpose: null is exactly
    /// the population that has to be re-read, and a default would hide it.
    ///
    /// `extracted_text_fts` is an external-content table over `markdown` alone, so adding a
    /// column beside it changes nothing about the index or its triggers.
    fileprivate static let schemaV7 = """
        ALTER TABLE extracted_text ADD COLUMN format TEXT;
        """

    /// FTS5's external-content triggers only fire on row-level writes; a migration that
    /// loads rows in bulk, bypassing them, would desync the index silently. Nothing in this
    /// file does that today, but this is the escape hatch if one ever needs to.
    public func rebuildSearchIndex() throws {
        try execute("INSERT INTO extracted_text_fts(extracted_text_fts) VALUES('rebuild');")
    }

    // MARK: - Documents

    /// One file's worth of what a scan can tell the library: everything `indexDocument`
    /// itself accepts, bundled so a whole batch can go through `indexDocuments` in a single
    /// transaction instead of paying for one call, and one transaction, per file.
    public struct IndexInput: Sendable {
        public var path: String
        public var contentHash: String?
        public var byteCount: Int?
        public var pageCount: Int?
        public var title: String?
        public var author: String?
        public var documentInfo: [String: String]
        public var seenAt: Date

        public init(
            path: String, contentHash: String? = nil, byteCount: Int? = nil, pageCount: Int? = nil,
            title: String? = nil, author: String? = nil, documentInfo: [String: String] = [:],
            seenAt: Date = Date()
        ) {
            self.path = path
            self.contentHash = contentHash
            self.byteCount = byteCount
            self.pageCount = pageCount
            self.title = title
            self.author = author
            self.documentInfo = documentInfo
            self.seenAt = seenAt
        }
    }

    /// Indexes one file, called repeatedly by a filesystem watcher as it re-walks the
    /// library: identity is resolved by path, so this is idempotent both when nothing
    /// changed (a plain touch of `last_seen_at`) and when the file's bytes changed under
    /// the same path (the row's locators are updated in place, its tags/notes/projects
    /// untouched, and no second row is created).
    @discardableResult
    public func indexDocument(
        path: String,
        contentHash: String?,
        byteCount: Int? = nil,
        pageCount: Int? = nil,
        title: String? = nil,
        author: String? = nil,
        documentInfo: [String: String] = [:],
        seenAt: Date = Date()
    ) throws -> DocumentRecord {
        try transaction {
            try indexOne(IndexInput(path: path, contentHash: contentHash, byteCount: byteCount,
                                    pageCount: pageCount, title: title, author: author,
                                    documentInfo: documentInfo, seenAt: seenAt))
        }
    }

    /// The batched form of `indexDocument`: every file in `files` is indexed inside one
    /// transaction, so a watcher re-walking a folder of ten thousand files commits once, not
    /// ten thousand times, which is the difference between a tick that finishes and one that
    /// stalls behind disk I/O. `indexDocument` itself is written in terms of this (a batch of
    /// one), so the two can never drift apart.
    ///
    /// Never deletes: a path that used to resolve to a document and is absent from `files`
    /// is left exactly as it is. A file this scan did not find might be on a drive that is
    /// not mounted right now, not one that has stopped existing; only `recordLocation` (an
    /// explicit "this path is now that document") or a future, separately-decided cleanup
    /// pass ever removes or re-points a row.
    @discardableResult
    public func indexDocuments(_ files: [IndexInput]) throws -> [DocumentRecord] {
        guard !files.isEmpty else { return [] }
        return try transaction { try files.map(indexOne) }
    }

    private func indexOne(_ file: IndexInput) throws -> DocumentRecord {
        let info = try Library.encodeDocumentInfo(file.documentInfo)
        let seenAtText = Library.isoString(file.seenAt)
        let id: String
        if let existingID = try documentID(atPath: file.path) {
            id = existingID
            try run("""
                UPDATE documents
                SET content_hash = COALESCE(?, content_hash),
                    byte_count = COALESCE(?, byte_count),
                    page_count = COALESCE(?, page_count),
                    title = COALESCE(?, title),
                    author = COALESCE(?, author),
                    document_info = CASE WHEN ? = '{}' THEN document_info ELSE ? END,
                    last_seen_at = ?
                WHERE id = ?;
                """) { statement in
                bindText(statement, 1, file.contentHash)
                bindInt(statement, 2, file.byteCount)
                bindInt(statement, 3, file.pageCount)
                bindText(statement, 4, file.title)
                bindText(statement, 5, file.author)
                bindText(statement, 6, info)
                bindText(statement, 7, info)
                bindText(statement, 8, seenAtText)
                bindText(statement, 9, id)
            }
        } else {
            id = UUID().uuidString
            try run("""
                INSERT INTO documents(id, first_seen_at, last_seen_at, content_hash, byte_count,
                                      page_count, title, author, document_info)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """) { statement in
                bindText(statement, 1, id)
                bindText(statement, 2, seenAtText)
                bindText(statement, 3, seenAtText)
                bindText(statement, 4, file.contentHash)
                bindInt(statement, 5, file.byteCount)
                bindInt(statement, 6, file.pageCount)
                bindText(statement, 7, file.title)
                bindText(statement, 8, file.author)
                bindText(statement, 9, info)
            }
        }
        try touchLocation(path: file.path, documentID: id, seenAt: seenAtText)
        guard let record = try document(id: id) else {
            throw LibraryError.invariantViolated("document \(id) vanished inside its own indexing transaction")
        }
        return record
    }

    /// Associates an additional path with a document that already exists, without touching
    /// its locators. This is the explicit primitive for "this path now names that document":
    /// a caller with real knowledge of a rename or a decrypt-in-place (the app's own
    /// `process(job:options:)`, by way of `Runner.syncLibrary`) calls this instead of
    /// `indexDocument` inventing the connection from a hash match, which is a guess this
    /// store deliberately does not make on its own.
    public func recordLocation(_ path: String, forDocument documentID: String, seenAt: Date = Date()) throws {
        try touchLocation(path: path, documentID: documentID, seenAt: Library.isoString(seenAt))
    }

    private func touchLocation(path: String, documentID: String, seenAt: String) throws {
        try run("""
            INSERT INTO locations(path, document_id, first_seen_at, last_seen_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET document_id = excluded.document_id, last_seen_at = excluded.last_seen_at;
            """) { statement in
            bindText(statement, 1, path)
            bindText(statement, 2, documentID)
            bindText(statement, 3, seenAt)
            bindText(statement, 4, seenAt)
        }
    }

    private func documentID(atPath path: String) throws -> String? {
        try withStatement("SELECT document_id FROM locations WHERE path = ?;", bind: { statement in
            bindText(statement, 1, path)
        }) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return columnText(statement, 0)
        }
    }

    /// Every path the library knows, and the document each one belongs to, in one query.
    ///
    /// For resolving a whole shelf at once. Asking file by file meant two statements and a
    /// round trip through this actor per file, a thousand times over on a thousand-file
    /// shelf, to end up with nothing but the ids.
    /// How much the library holds, for a bar that has to say so in one line. Counted in
    /// SQL rather than by reading every row back out: the answer is two numbers.
    public func totals() throws -> LibraryTotals {
        try withStatement("SELECT COUNT(*), COALESCE(SUM(byte_count), 0) FROM documents;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return LibraryTotals(documents: 0, bytes: 0) }
            return LibraryTotals(documents: Int(sqlite3_column_int64(statement, 0)),
                                 bytes: Int(sqlite3_column_int64(statement, 1)))
        }
    }

    /// What an earlier pass read out of the PDFs, by path: enough for a search over a
    /// shelf that listed its files without opening any of them. A `pages:`, `title:` or
    /// `author:` term would otherwise be dead on a source added the cheap way.
    public func documentFactsByPath() throws -> [String: DocumentFacts] {
        try withStatement("""
            SELECT l.path, d.page_count, d.title, d.author
            FROM locations l
            JOIN documents d ON d.id = l.document_id;
            """) { statement in
            var facts: [String: DocumentFacts] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let path = columnText(statement, 0) else { continue }
                let pages = sqlite3_column_type(statement, 1) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int64(statement, 1))
                facts[path] = DocumentFacts(pageCount: pages,
                                            title: columnText(statement, 2),
                                            author: columnText(statement, 3))
            }
            return facts
        }
    }

    public func documentIDsByPath() throws -> [String: String] {
        try withStatement("SELECT path, document_id FROM locations;", bind: { _ in }) { statement in
            var found: [String: String] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let path = columnText(statement, 0),
                      let id = columnText(statement, 1) else { continue }
                found[path] = id
            }
            return found
        }
    }

    public func document(id: String) throws -> DocumentRecord? {
        try withStatement("""
            SELECT id, first_seen_at, last_seen_at, content_hash, byte_count, page_count, title, author, document_info
            FROM documents WHERE id = ?;
            """, bind: { statement in
            bindText(statement, 1, id)
        }) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return Library.documentRecord(from: statement)
        }
    }

    public func document(atPath path: String) throws -> DocumentRecord? {
        guard let id = try documentID(atPath: path) else { return nil }
        return try document(id: id)
    }

    public func locations(forDocument documentID: String) throws -> [LocationRecord] {
        try withStatement("""
            SELECT path, document_id, first_seen_at, last_seen_at FROM locations
            WHERE document_id = ? ORDER BY first_seen_at;
            """, bind: { statement in
            bindText(statement, 1, documentID)
        }) { statement in
            var results: [LocationRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(LocationRecord(
                    path: columnText(statement, 0) ?? "",
                    documentID: columnText(statement, 1) ?? documentID,
                    firstSeenAt: columnText(statement, 2).flatMap(Library.isoDate) ?? .distantPast,
                    lastSeenAt: columnText(statement, 3).flatMap(Library.isoDate) ?? .distantPast
                ))
            }
            return results
        }
    }

    private static func documentRecord(from statement: OpaquePointer) -> DocumentRecord {
        DocumentRecord(
            id: columnText(statement, 0) ?? "",
            firstSeenAt: columnText(statement, 1).flatMap(isoDate) ?? .distantPast,
            lastSeenAt: columnText(statement, 2).flatMap(isoDate) ?? .distantPast,
            contentHash: columnText(statement, 3),
            byteCount: columnInt(statement, 4),
            pageCount: columnInt(statement, 5),
            title: columnText(statement, 6),
            author: columnText(statement, 7),
            documentInfo: columnText(statement, 8).flatMap(decodeDocumentInfo) ?? [:]
        )
    }

    private static func encodeDocumentInfo(_ info: [String: String]) throws -> String {
        let data = try JSONEncoder().encode(info)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func decodeDocumentInfo(_ text: String) -> [String: String]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    // MARK: - Tags

    public func addTag(_ name: String, toDocument documentID: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.invalidTagName }
        try transaction {
            try run("INSERT INTO tags(name) VALUES (?) ON CONFLICT(name) DO NOTHING;") { statement in
                bindText(statement, 1, trimmed)
            }
            try run("""
                INSERT INTO document_tags(document_id, tag_id)
                SELECT ?, id FROM tags WHERE name = ?
                ON CONFLICT(document_id, tag_id) DO NOTHING;
                """) { statement in
                bindText(statement, 1, documentID)
                bindText(statement, 2, trimmed)
            }
        }
    }

    /// Removes the association, not the tag itself: an unused tag with zero documents left
    /// costs nothing to keep, and keeping it means it is still there to pick again later.
    public func removeTag(_ name: String, fromDocument documentID: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try run("""
            DELETE FROM document_tags
            WHERE document_id = ? AND tag_id = (SELECT id FROM tags WHERE name = ?);
            """) { statement in
            bindText(statement, 1, documentID)
            bindText(statement, 2, trimmed)
        }
    }

    public func tags(forDocument documentID: String) throws -> [Tag] {
        try withStatement("""
            SELECT t.id, t.name FROM tags t
            JOIN document_tags dt ON dt.tag_id = t.id
            WHERE dt.document_id = ?
            ORDER BY t.name;
            """, bind: { statement in
            bindText(statement, 1, documentID)
        }) { statement in
            var results: [Tag] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(Tag(id: sqlite3_column_int64(statement, 0), name: columnText(statement, 1) ?? ""))
            }
            return results
        }
    }

    // MARK: - Projects

    @discardableResult
    public func createProject(name: String, createdAt: Date = Date()) throws -> Project {
        try run("INSERT INTO projects(name, created_at) VALUES (?, ?);") { statement in
            bindText(statement, 1, name)
            bindText(statement, 2, Library.isoString(createdAt))
        }
        return Project(id: sqlite3_last_insert_rowid(db), name: name, createdAt: createdAt)
    }

    public func projects() throws -> [Project] {
        try withStatement("SELECT id, name, created_at FROM projects ORDER BY created_at;") { statement in
            var results: [Project] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(Project(
                    id: sqlite3_column_int64(statement, 0),
                    name: columnText(statement, 1) ?? "",
                    createdAt: columnText(statement, 2).flatMap(Library.isoDate) ?? .distantPast
                ))
            }
            return results
        }
    }

    /// Projects containing one document, in one query. The details panel used to load
    /// every project and then fetch every project's members just to answer this question.
    public func projects(containingDocument documentID: String) throws -> [Project] {
        try withStatement("""
            SELECT p.id, p.name, p.created_at
            FROM projects p
            JOIN project_members m ON m.project_id = p.id
            WHERE m.document_id = ?
            ORDER BY p.created_at;
            """, bind: { statement in
            bindText(statement, 1, documentID)
        }) { statement in
            var results: [Project] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(Project(
                    id: sqlite3_column_int64(statement, 0),
                    name: columnText(statement, 1) ?? "",
                    createdAt: columnText(statement, 2).flatMap(Library.isoDate) ?? .distantPast
                ))
            }
            return results
        }
    }

    /// Counts all project memberships in one query, including only projects that have
    /// members. Callers use a zero default for an empty project.
    public func projectMemberCounts() throws -> [Int64: Int] {
        try withStatement("""
            SELECT project_id, COUNT(*)
            FROM project_members
            GROUP BY project_id;
            """) { statement in
            var counts: [Int64: Int] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                counts[sqlite3_column_int64(statement, 0)] = Int(sqlite3_column_int64(statement, 1))
            }
            return counts
        }
    }

    public func addMember(_ documentID: String, toProject projectID: Int64, addedAt: Date = Date()) throws {
        try run("""
            INSERT INTO project_members(project_id, document_id, added_at) VALUES (?, ?, ?)
            ON CONFLICT(project_id, document_id) DO NOTHING;
            """) { statement in
            sqlite3_bind_int64(statement, 1, projectID)
            bindText(statement, 2, documentID)
            bindText(statement, 3, Library.isoString(addedAt))
        }
    }

    /// Adds documents to a project by file path, which is what a drag carries: from the
    /// sidebar, or from Finder. A path this library has never seen is skipped rather than
    /// indexed here, so the count is how many of them were documents.
    @discardableResult
    public func addMembers(paths: [String], toProject projectID: Int64,
                           addedAt: Date = Date()) throws -> Int {
        var added = 0
        for path in paths {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard let id = try documentID(atPath: path) ?? documentID(atPath: resolved)
            else { continue }
            try addMember(id, toProject: projectID, addedAt: addedAt)
            added += 1
        }
        return added
    }

    public func removeMember(_ documentID: String, fromProject projectID: Int64) throws {
        try run("DELETE FROM project_members WHERE project_id = ? AND document_id = ?;") { statement in
            sqlite3_bind_int64(statement, 1, projectID)
            bindText(statement, 2, documentID)
        }
    }

    public func members(ofProject projectID: Int64) throws -> [DocumentRecord] {
        try withStatement("""
            SELECT d.id, d.first_seen_at, d.last_seen_at, d.content_hash, d.byte_count, d.page_count,
                   d.title, d.author, d.document_info
            FROM documents d
            JOIN project_members m ON m.document_id = d.id
            WHERE m.project_id = ?
            ORDER BY m.added_at;
            """, bind: { statement in
            sqlite3_bind_int64(statement, 1, projectID)
        }) { statement in
            var results: [DocumentRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(Library.documentRecord(from: statement))
            }
            return results
        }
    }

    // MARK: - Notes

    @discardableResult
    public func addNote(_ body: String, toDocument documentID: String, at date: Date = Date()) throws -> Note {
        let timestamp = Library.isoString(date)
        try run("INSERT INTO notes(document_id, body, created_at, updated_at) VALUES (?, ?, ?, ?);") { statement in
            bindText(statement, 1, documentID)
            bindText(statement, 2, body)
            bindText(statement, 3, timestamp)
            bindText(statement, 4, timestamp)
        }
        return Note(id: sqlite3_last_insert_rowid(db), documentID: documentID, body: body,
                    createdAt: date, updatedAt: date)
    }

    public func notes(forDocument documentID: String) throws -> [Note] {
        try withStatement("""
            SELECT id, document_id, body, created_at, updated_at FROM notes
            WHERE document_id = ? ORDER BY created_at;
            """, bind: { statement in
            bindText(statement, 1, documentID)
        }) { statement in
            var results: [Note] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(Note(
                    id: sqlite3_column_int64(statement, 0),
                    documentID: columnText(statement, 1) ?? documentID,
                    body: columnText(statement, 2) ?? "",
                    createdAt: columnText(statement, 3).flatMap(Library.isoDate) ?? .distantPast,
                    updatedAt: columnText(statement, 4).flatMap(Library.isoDate) ?? .distantPast
                ))
            }
            return results
        }
    }

    public func removeNote(_ id: Int64) throws {
        try run("DELETE FROM notes WHERE id = ?;") { statement in
            sqlite3_bind_int64(statement, 1, id)
        }
    }

    // MARK: - Extracted text and search

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

    /// Every known path with the document it belongs to and when its text was last read.
    /// One query rather than one per file: the indexer asks this once and then knows what
    /// is left to do. A path with no text yet reports `nil`.
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

    /// Stores a batch of extracted text in one transaction. Fourteen thousand documents
    /// written one statement at a time is fourteen thousand fsyncs.
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

    /// How many documents have text on record, for a status line that has to say whether
    /// searching the text is going to answer anything.
    public func indexedTextCount() throws -> Int {
        try withStatement("SELECT COUNT(*) FROM extracted_text;") { statement in
            sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
        }
    }

    public func extractedText(forDocument documentID: String) throws -> ExtractedText? {
        try withStatement("SELECT document_id, markdown, extracted_at, format FROM extracted_text WHERE document_id = ?;",
                          bind: { statement in bindText(statement, 1, documentID) }) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return ExtractedText(
                documentID: columnText(statement, 0) ?? documentID,
                markdown: columnText(statement, 1) ?? "",
                extractedAt: columnText(statement, 2).flatMap(Library.isoDate) ?? .distantPast,
                format: columnText(statement, 3).flatMap(TextFormat.init(rawValue:))
            )
        }
    }

    /// Every stored text belonging to a project's documents, in one statement.
    ///
    /// Asked per document, opening a project of a thousand papers was a thousand round
    /// trips through this actor before its list could be drawn. The whole table is read
    /// and narrowed here rather than binding a thousand parameters: the callers want most
    /// of a project at a time, and SQLite has no list parameter.
    public func extractedText(forDocuments documentIDs: [String]) throws -> [String: String] {
        guard !documentIDs.isEmpty else { return [:] }
        let wanted = Set(documentIDs)
        return try withStatement("SELECT document_id, markdown FROM extracted_text;") { statement in
            var out: [String: String] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = columnText(statement, 0), wanted.contains(id) else { continue }
                out[id] = columnText(statement, 1) ?? ""
            }
            return out
        }
    }

    /// Which documents' stored text matches, as ids, for a shelf search that then has to
    /// intersect the answer with what is on screen. Ids rather than records: the caller
    /// already holds everything it needs to draw a row, and fetching whole rows for
    /// fourteen thousand matches to throw them away is a page of SQLite for nothing.
    public func documentIDsMatchingText(_ phrase: String, limit: Int = 20_000) throws -> [String] {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let quoted = "\"\(trimmed.replacingOccurrences(of: "\"", with: "\"\""))\""
        return try withStatement("""
            SELECT e.document_id
            FROM extracted_text_fts
            JOIN extracted_text e ON e.rowid = extracted_text_fts.rowid
            WHERE extracted_text_fts MATCH ?
            ORDER BY bm25(extracted_text_fts)
            LIMIT ?;
            """, bind: { statement in
            bindText(statement, 1, quoted)
            sqlite3_bind_int64(statement, 2, Int64(limit))
        }) { statement in
            var ids: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let id = columnText(statement, 0) { ids.append(id) }
            }
            return ids
        }
    }

    /// Which documents open with this. What a paper's abstract is, the store cannot know;
    /// what it opens with, it can, and the first two thousand characters of a paper are
    /// its title, its authors and its abstract. Not FTS: a prefix is a substring question,
    /// and the index is over the whole document rather than its opening.
    public func documentIDsMatchingAbstract(_ needle: String,
                                            characters: Int = abstractCharacterLimit,
                                            limit: Int = 20_000) throws -> [String] {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let pattern = "%" + trimmed.replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
        return try withStatement("""
            SELECT document_id FROM extracted_text
            WHERE substr(markdown, 1, ?) LIKE ? ESCAPE '\\'
            LIMIT ?;
            """, bind: { statement in
            sqlite3_bind_int64(statement, 1, Int64(characters))
            bindText(statement, 2, pattern)
            sqlite3_bind_int64(statement, 3, Int64(limit))
        }) { statement in
            var ids: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let id = columnText(statement, 0) { ids.append(id) }
            }
            return ids
        }
    }

    /// Documents whose recorded metadata mentions this: title, author, or anything in the
    /// PDF's own info dictionary (keywords, subject, producer). Substring rather than FTS,
    /// because a title is short enough to scan and somebody typing three letters of an
    /// author's name means the middle of a word as often as the start of one.
    ///
    /// Nothing here depends on the text having been extracted, which is what makes it the
    /// half of search that answers before a library has been indexed.
    public func documentsMatchingMetadata(_ text: String, limit: Int = 8) throws -> [DocumentRecord] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let pattern = "%" + trimmed.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
        return try withStatement("""
            SELECT d.id, d.first_seen_at, d.last_seen_at, d.content_hash, d.byte_count, d.page_count,
                   d.title, d.author, d.document_info
            FROM documents d
            WHERE d.title LIKE ?1 ESCAPE '\\'
               OR d.author LIKE ?1 ESCAPE '\\'
               OR d.document_info LIKE ?1 ESCAPE '\\'
            ORDER BY d.last_seen_at DESC
            LIMIT ?2;
            """, bind: { statement in
            bindText(statement, 1, pattern)
            sqlite3_bind_int64(statement, 2, Int64(limit))
        }) { statement in
            var results: [DocumentRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(Library.documentRecord(from: statement))
            }
            return results
        }
    }

    public func fullTextSearch(_ text: String, limit: Int = 50) throws -> [DocumentRecord] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Wrapped as one FTS5 phrase rather than passed through raw. FTS5's MATCH syntax
        // gives special meaning to `-`, `:`, `"` and bareword operators, and a search box is
        // not the place to make someone escape SQL; a phrase (adjacent tokens, in order) is
        // also the FTS5 primitive closest to what Search.swift's own `text:"..."` term
        // already means, see the type-level comment above.
        let phrase = "\"\(trimmed.replacingOccurrences(of: "\"", with: "\"\""))\""
        return try withStatement("""
            SELECT d.id, d.first_seen_at, d.last_seen_at, d.content_hash, d.byte_count, d.page_count,
                   d.title, d.author, d.document_info
            FROM extracted_text_fts
            JOIN extracted_text e ON e.rowid = extracted_text_fts.rowid
            JOIN documents d ON d.id = e.document_id
            WHERE extracted_text_fts MATCH ?
            ORDER BY bm25(extracted_text_fts)
            LIMIT ?;
            """, bind: { statement in
            bindText(statement, 1, phrase)
            sqlite3_bind_int64(statement, 2, Int64(limit))
        }) { statement in
            var results: [DocumentRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(Library.documentRecord(from: statement))
            }
            return results
        }
    }

    // MARK: - SQLite plumbing

    private func execute(_ sql: String) throws {
        guard let db else {
            throw LibraryError.invariantViolated("execute(_:) called with no open connection")
        }
        try performExecute(db, sql)
    }

    /// Every write in this file goes through this so a real failure rolls the whole
    /// operation back instead of leaving, say, a document row with no location, or a tag
    /// insert with no document link.
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Prepares `sql`, lets `bind` attach parameters, and finalizes the statement no matter
    /// how `body` returns or throws, so a thrown error never leaks a live `sqlite3_stmt*`.
    /// Internal rather than private: `Spend.swift` and `Duplicates.swift` own the
    /// accessors for their own tables and live in their own files. An extension is still
    /// isolated to this actor, so nothing about the concurrency guarantee changes.
    func withStatement<T>(
        _ sql: String,
        bind: (OpaquePointer) throws -> Void = { _ in },
        body: (OpaquePointer) throws -> T
    ) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(db))
            throw LibraryError.sqlite(code: sqlite3_errcode(db), message: message)
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        return try body(statement)
    }

    /// For a statement whose result nobody reads: an INSERT/UPDATE/DELETE stepped to
    /// completion.
    func run(_ sql: String, bind: (OpaquePointer) throws -> Void = { _ in }) throws {
        try withStatement(sql, bind: bind) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE else {
                let message = String(cString: sqlite3_errmsg(db))
                throw LibraryError.sqlite(code: result, message: message)
            }
        }
    }

    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func isoDate(_ text: String) -> Date? {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = precise.date(from: text) { return date }
        // Whole-second fallback, in case a value predates fractional seconds being added.
        return ISO8601DateFormatter().date(from: text)
    }

    #if DEBUG
    /// Test-only introspection, compiled out of release builds: confirms the shape of a
    /// table without adding a real accessor for it. `spend_ledger` and `dismissed_duplicates`
    /// stay schema-only in this file on purpose, see the comment on `schemaV2`.
    func columnNames(ofTable table: String) throws -> [String] {
        try withStatement("PRAGMA table_info(\(table));") { statement in
            var names: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = columnText(statement, 1) { names.append(name) }
            }
            return names
        }
    }
    #endif
}

// MARK: - Connection setup (free functions, called only from `Library.init` before `self.db`
// is assigned, and by `execute(_:)` afterwards; see the comment in `init`)

private func performExecute(_ db: OpaquePointer, _ sql: String) throws {
    var errorPointer: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)
    if result != SQLITE_OK {
        let message = errorPointer.map { String(cString: $0) } ?? "sqlite code \(result)"
        sqlite3_free(errorPointer)
        throw LibraryError.sqlite(code: result, message: message)
    }
}

private func performSchemaVersion(_ db: OpaquePointer) throws -> Int {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK, let statement else {
        throw LibraryError.sqlite(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
    return Int(sqlite3_column_int64(statement, 0))
}

private func prepareConnection(_ db: OpaquePointer) throws {
    try performExecute(db, "PRAGMA foreign_keys = ON;")
    try performExecute(db, "PRAGMA journal_mode = WAL;")
    let current = try performSchemaVersion(db)
    guard current < Library.migrations.count else { return }
    for version in current..<Library.migrations.count {
        try performExecute(db, "BEGIN IMMEDIATE;")
        do {
            try performExecute(db, Library.migrations[version])
            try performExecute(db, "PRAGMA user_version = \(version + 1);")
            try performExecute(db, "COMMIT;")
        } catch {
            try? performExecute(db, "ROLLBACK;")
            throw error
        }
    }
}

// MARK: - Binding and column helpers (free functions: they never touch `db` itself, so they
// carry no actor isolation and impose none on their callers)

/// `SQLITE_TRANSIENT` is the cast macro `((sqlite3_destructor_type)-1)`; the Clang importer
/// does not bridge `#define` cast macros, so every text bind that does not own a buffer
/// guaranteed to outlive `sqlite3_step` needs this spelled out by hand, telling SQLite to
/// copy the bytes immediately rather than assume they will still be there.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
}

func bindInt(_ statement: OpaquePointer, _ index: Int32, _ value: Int?) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_int64(statement, index, Int64(value))
}

func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard let cString = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: cString)
}

func columnInt(_ statement: OpaquePointer, _ index: Int32) -> Int? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, index))
}

// MARK: - Errors

public enum LibraryError: Error, CustomStringConvertible, Sendable {
    case openFailed(String)
    case sqlite(code: Int32, message: String)
    case invalidTagName
    /// Something this file's own logic guarantees can't happen, happened. A bug here, not
    /// a way for a caller to have used the API wrong.
    case invariantViolated(String)

    public var description: String {
        switch self {
        case .openFailed(let message): return "could not open the library database: \(message)"
        case .sqlite(let code, let message): return "sqlite error \(code): \(message)"
        case .invalidTagName: return "tag names cannot be empty"
        case .invariantViolated(let message): return message
        }
    }
}

// MARK: - Records

/// What the whole library adds up to: how many documents it knows and how many bytes
/// they are. A document whose size was never read counts as nothing rather than as a
/// guess.
public struct LibraryTotals: Sendable, Equatable {
    public let documents: Int
    public let bytes: Int

    public init(documents: Int, bytes: Int) {
        self.documents = documents
        self.bytes = bytes
    }
}

/// The little of a document a search needs to know without opening the file: how long it
/// is, what it says it is called, and who it says wrote it.
public struct DocumentFacts: Sendable, Equatable {
    public let pageCount: Int?
    public let title: String?
    public let author: String?

    public init(pageCount: Int?, title: String?, author: String?) {
        self.pageCount = pageCount
        self.title = title
        self.author = author
    }
}

public struct DocumentRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    /// The document's current sha-256, a locator, not the identity: see the type-level
    /// comment on `Library`.
    public var contentHash: String?
    public var byteCount: Int?
    public var pageCount: Int?
    public var title: String?
    public var author: String?
    public var documentInfo: [String: String]
}

public struct LocationRecord: Sendable, Equatable {
    public let path: String
    public var documentID: String
    public var firstSeenAt: Date
    public var lastSeenAt: Date
}

public struct Tag: Sendable, Equatable, Hashable, Identifiable {
    public let id: Int64
    public var name: String
}

public struct Project: Sendable, Equatable, Identifiable {
    public let id: Int64
    public var name: String
    public var createdAt: Date
}

public struct Note: Sendable, Equatable, Identifiable {
    public let id: Int64
    public var documentID: String
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date
}

public struct ExtractedText: Sendable, Equatable {
    public var documentID: String
    public var markdown: String
    public var extractedAt: Date
    /// Nil for text stored before page markers existed, which is what makes it stale.
    public var format: TextFormat?
}

/// Mirrors `runCacheURL` (`Cache.swift`) exactly, down to the same folder: the run cache is
/// a disposable preview, this file is the durable record they sit beside each other. Takes
/// an explicit override so tests never touch the real one.
/// Where the store lives.
///
/// PAPERSHELF_LIBRARY_PATH moves it, which is what keeps a test suite and the MCP server's
/// own checks off the real one. Without it a test that merely constructs something holding
/// `Library.shared` opens, and migrates, the library a person actually keeps their books
/// in, which is not a thing a test may do.
public func libraryDatabaseURL(named name: String = "library.sqlite") -> URL? {
    if let overridden = ProcessInfo.processInfo.environment["PAPERSHELF_LIBRARY_PATH"],
       !overridden.isEmpty {
        return URL(fileURLWithPath: overridden)
    }
    guard let folder = supportDirectory() else { return nil }
    return folder.appendingPathComponent(name)
}

// MARK: - What the interface needs to show the store

extension Library {

    /// A project and everything under it go together: leaving members behind would be a
    /// row pointing at a project that no longer exists.
    public func deleteProject(id: Int64) throws {
        try transaction {
            try run("DELETE FROM project_members WHERE project_id = ?;") { statement in
                sqlite3_bind_int64(statement, 1, id)
            }
            try run("DELETE FROM projects WHERE id = ?;") { statement in
                sqlite3_bind_int64(statement, 1, id)
            }
        }
    }

    /// Documents, most recently seen first, for a picker to choose from.
    public func documents(limit: Int = 500) throws -> [DocumentRecord] {
        try withStatement(
            "SELECT * FROM documents ORDER BY last_seen_at DESC LIMIT ?;",
            bind: { statement in sqlite3_bind_int(statement, 1, Int32(max(0, limit))) }
        ) { statement in
            var found: [DocumentRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                found.append(Library.documentRecord(from: statement))
            }
            return found
        }
    }

    /// What the store holds, for the panel that shows it.
    public func summary() throws -> LibrarySummary {
        func count(_ table: String) throws -> Int {
            try withStatement("SELECT COUNT(*) FROM \(table);") { statement in
                sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
            }
        }
        return LibrarySummary(
            documents: try count("documents"),
            paths: try count("locations"),
            tags: try count("tags"),
            projects: try count("projects"),
            withText: try count("extracted_text")
        )
    }
}

public struct LibrarySummary: Sendable, Equatable {
    public var documents: Int
    public var paths: Int
    public var tags: Int
    public var projects: Int
    /// How many have had their text extracted, which is what full-text search can reach.
    public var withText: Int
}

// MARK: - Kept bibliography entries

extension Library {

    /// The entry the user decided on, replacing whatever was there.
    public func storeBibtex(_ entry: String, forDocument documentID: String,
                            origin: String, at date: Date = Date()) throws {
        try run("""
            INSERT INTO bibtex_entries (document_id, entry, origin, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(document_id) DO UPDATE SET
                entry = excluded.entry, origin = excluded.origin, updated_at = excluded.updated_at;
            """) { statement in
            bindText(statement, 1, documentID)
            bindText(statement, 2, entry)
            bindText(statement, 3, origin)
            bindText(statement, 4, Library.isoString(date))
        }
    }

    public func bibtex(forDocument documentID: String) throws -> StoredBibtex? {
        try withStatement(
            "SELECT entry, origin, updated_at FROM bibtex_entries WHERE document_id = ?;",
            bind: { statement in bindText(statement, 1, documentID) }
        ) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return StoredBibtex(documentID: documentID,
                                entry: columnText(statement, 0) ?? "",
                                origin: columnText(statement, 1) ?? "",
                                updatedAt: columnText(statement, 2).flatMap(Library.isoDate) ?? Date())
        }
    }

    public func removeBibtex(forDocument documentID: String) throws {
        try run("DELETE FROM bibtex_entries WHERE document_id = ?;") { statement in
            bindText(statement, 1, documentID)
        }
    }

    /// Kept entries by every path their document is known at.
    ///
    /// A document has more than one path once it has been renamed, and the caller matching
    /// these against what is on screen may hold either the old one or the new one, so both
    /// answer.
    public func storedBibtexByPath() throws -> [String: String] {
        try withStatement("""
            SELECT l.path, b.entry
            FROM bibtex_entries b
            JOIN locations l ON l.document_id = b.document_id;
            """) { statement in
            var out: [String: String] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                if let path = columnText(statement, 0), let entry = columnText(statement, 1) {
                    out[path] = entry
                }
            }
            return out
        }
    }

    /// Everything kept, for an export that should prefer a decided entry over a guess.
    public func storedBibtex() throws -> [StoredBibtex] {
        try withStatement("SELECT document_id, entry, origin, updated_at FROM bibtex_entries;") {
            statement in
            var out: [StoredBibtex] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                out.append(StoredBibtex(documentID: columnText(statement, 0) ?? "",
                                        entry: columnText(statement, 1) ?? "",
                                        origin: columnText(statement, 2) ?? "",
                                        updatedAt: columnText(statement, 3)
                                            .flatMap(Library.isoDate) ?? Date()))
            }
            return out
        }
    }
}

public struct StoredBibtex: Sendable, Equatable {
    public var documentID: String
    public var entry: String
    /// How it was arrived at, so a kept entry can say whether a person, a registry or a
    /// model produced it.
    public var origin: String
    public var updatedAt: Date
}

// MARK: - Tags, and what a reading project is made of

extension Library {

    /// Every tag with how many documents carry it, most used first.
    ///
    /// The count is what makes a tag list worth looking at: a wall of equal-looking words
    /// says nothing about which of them organise the shelf.
    public func tagCounts() throws -> [TagCount] {
        try withStatement("""
            SELECT t.id, t.name, COUNT(dt.document_id)
            FROM tags t
            LEFT JOIN document_tags dt ON dt.tag_id = t.id
            GROUP BY t.id, t.name
            ORDER BY COUNT(dt.document_id) DESC, t.name COLLATE NOCASE ASC;
            """) { statement in
            var out: [TagCount] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                out.append(TagCount(id: sqlite3_column_int64(statement, 0),
                                    name: columnText(statement, 1) ?? "",
                                    documents: Int(sqlite3_column_int64(statement, 2))))
            }
            return out
        }
    }

    /// The documents carrying a tag, for a list built by clicking one.
    public func documents(taggedWith name: String) throws -> [DocumentRecord] {
        try withStatement("""
            SELECT d.* FROM documents d
            JOIN document_tags dt ON dt.document_id = d.id
            JOIN tags t ON t.id = dt.tag_id
            WHERE t.name = ? COLLATE NOCASE
            ORDER BY d.last_seen_at DESC;
            """, bind: { statement in bindText(statement, 1, name) }) { statement in
            var out: [DocumentRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                out.append(Library.documentRecord(from: statement))
            }
            return out
        }
    }

    /// Tags by document, for showing them against a list without a query per row.
    public func tagsByDocument() throws -> [String: [String]] {
        try withStatement("""
            SELECT dt.document_id, t.name FROM document_tags dt
            JOIN tags t ON t.id = dt.tag_id
            ORDER BY t.name COLLATE NOCASE;
            """) { statement in
            var out: [String: [String]] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = columnText(statement, 0), let name = columnText(statement, 1)
                else { continue }
                out[id, default: []].append(name)
            }
            return out
        }
    }

    /// Renaming a tag everywhere it is used, since a typo otherwise splits a shelf in two.
    public func renameTag(_ name: String, to replacement: String) throws {
        let cleaned = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw LibraryError.invalidTagName }
        try transaction {
            // The new name may already exist, in which case the two become one rather than
            // colliding on the unique index.
            if let existing = try tagID(named: cleaned), let old = try tagID(named: name),
               existing != old {
                try run("""
                    UPDATE OR IGNORE document_tags SET tag_id = ? WHERE tag_id = ?;
                    """) { statement in
                    sqlite3_bind_int64(statement, 1, existing)
                    sqlite3_bind_int64(statement, 2, old)
                }
                try run("DELETE FROM document_tags WHERE tag_id = ?;") { statement in
                    sqlite3_bind_int64(statement, 1, old)
                }
                try run("DELETE FROM tags WHERE id = ?;") { statement in
                    sqlite3_bind_int64(statement, 1, old)
                }
            } else {
                try run("UPDATE tags SET name = ? WHERE name = ? COLLATE NOCASE;") { statement in
                    bindText(statement, 1, cleaned)
                    bindText(statement, 2, name)
                }
            }
        }
    }

    // MARK: Forgetting a source

    /// Every document, with every path it is known at.
    ///
    /// For the one question the store cannot answer on its own: which of these still
    /// exist. That is the filesystem's to answer, and this actor does not touch it.
    public func locationsByDocument() throws -> [String: [String]] {
        try withStatement("SELECT document_id, path FROM locations;", bind: { _ in }) { statement in
            var found: [String: [String]] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = columnText(statement, 0),
                      let path = columnText(statement, 1) else { continue }
                found[id, default: []].append(path)
            }
            return found
        }
    }


    /// The documents whose every known location is under `root`.
    ///
    /// A document that also lives under another watched folder is not one of these: the
    /// identity here is the document, not the path, and a book filed in two places is one
    /// book. It keeps its other location and stays.
    public func documentsOnly(under root: String) throws -> [String] {
        let prefix = root.hasSuffix("/") ? String(root.dropLast()) : root
        let inside = try locatedDocuments(under: prefix)
        guard !inside.isEmpty else { return [] }
        var only: [String] = []
        for id in inside where try locationCount(of: id, outside: prefix) == 0 {
            only.append(id)
        }
        return only
    }

    /// What would be lost with these documents, counted.
    ///
    /// Not everything a document carries is worth warning about. Its text can be read
    /// again and its citation regenerated; which project you filed it under, what you
    /// tagged it, and how far you had read cannot. Those are the three this counts, so a
    /// question about removing a source can say what the removal actually costs instead
    /// of listing everything it technically touches.
    public struct Curation: Equatable, Sendable {
        public let tagged: Int
        public let inProjects: Int
        public let beingRead: Int

        public var isEmpty: Bool { tagged == 0 && inProjects == 0 && beingRead == 0 }

        public init(tagged: Int, inProjects: Int, beingRead: Int) {
            self.tagged = tagged
            self.inProjects = inProjects
            self.beingRead = beingRead
        }

        /// "2 are in reading projects and 3 are tagged". Empty when none of them is.
        public var sentence: String {
            var parts: [String] = []
            if inProjects > 0 {
                parts.append("\(inProjects) \(inProjects == 1 ? "is" : "are") in a reading project")
            }
            if tagged > 0 { parts.append("\(tagged) tagged") }
            if beingRead > 0 { parts.append("\(beingRead) part-read") }
            guard parts.count > 1 else { return parts.first ?? "" }
            return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }

    public func curation(of ids: [String]) throws -> Curation {
        guard !ids.isEmpty else { return Curation(tagged: 0, inProjects: 0, beingRead: 0) }
        let wanted = Set(ids)
        return Curation(tagged: try count(wanted, in: "document_tags"),
                        inProjects: try count(wanted, in: "project_members"),
                        beingRead: try count(wanted, in: "reading_positions"))
    }

    /// How many of `ids` appear in a table keyed by document.
    ///
    /// Counted by walking the table rather than by binding a list: SQLite has a limit on
    /// how many parameters one statement may carry, and a source can hold more documents
    /// than that.
    private func count(_ ids: Set<String>, in table: String) throws -> Int {
        try withStatement("SELECT DISTINCT document_id FROM \(table);", bind: { _ in }) { statement in
            var found = 0
            while sqlite3_step(statement) == SQLITE_ROW {
                if let id = columnText(statement, 0), ids.contains(id) { found += 1 }
            }
            return found
        }
    }

    /// Forgets documents outright: the row, and everything hung off it.
    ///
    /// Every table that references a document cascades from `documents(id)` and foreign
    /// keys are on, so this one delete takes the locations, the tags, the notes, the
    /// extracted text and its search index, the reading position, the citation and the
    /// project memberships with it. Nothing on disk is touched.
    @discardableResult
    public func forget(documents ids: [String]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        try transaction {
            for id in ids {
                try run("DELETE FROM documents WHERE id = ?;") { statement in
                    bindText(statement, 1, id)
                }
            }
        }
        return ids.count
    }

    /// Every document with a location at `prefix` itself or anywhere under it.
    ///
    /// Compared as a range rather than matched with `LIKE`: a path is free to contain `%`
    /// and `_`, which `LIKE` would read as wildcards, and "/" is followed by "0" in
    /// ASCII, so everything under `prefix + "/"` sorts below `prefix + "0"`.
    private func locatedDocuments(under prefix: String) throws -> [String] {
        try withStatement("""
            SELECT DISTINCT document_id FROM locations
            WHERE path = ?1 OR (path >= ?2 AND path < ?3);
            """, bind: { statement in
                bindText(statement, 1, prefix)
                bindText(statement, 2, prefix + "/")
                bindText(statement, 3, prefix + "0")
            }) { statement in
            var found: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let id = columnText(statement, 0) { found.append(id) }
            }
            return found
        }
    }

    /// How many places this document is known at that are not under `prefix`.
    private func locationCount(of id: String, outside prefix: String) throws -> Int {
        try withStatement("""
            SELECT COUNT(*) FROM locations
            WHERE document_id = ?1 AND NOT (path = ?2 OR (path >= ?3 AND path < ?4));
            """, bind: { statement in
                bindText(statement, 1, id)
                bindText(statement, 2, prefix)
                bindText(statement, 3, prefix + "/")
                bindText(statement, 4, prefix + "0")
            }) { statement in
            sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
        }
    }

    /// Removes a tag from every document and from the list.
    public func deleteTag(_ name: String) throws {
        try transaction {
            guard let id = try tagID(named: name) else { return }
            try run("DELETE FROM document_tags WHERE tag_id = ?;") { statement in
                sqlite3_bind_int64(statement, 1, id)
            }
            try run("DELETE FROM tags WHERE id = ?;") { statement in
                sqlite3_bind_int64(statement, 1, id)
            }
        }
    }

    private func tagID(named name: String) throws -> Int64? {
        try withStatement("SELECT id FROM tags WHERE name = ? COLLATE NOCASE;",
                          bind: { statement in bindText(statement, 1, name) }) { statement in
            sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : nil
        }
    }

    // MARK: Project sections

    /// Files a document under a section of a project, adding it if it is not a member yet.
    /// A nil section means it is in the project but filed under nothing.
    public func setSection(_ section: String?, forDocument documentID: String,
                           inProject projectID: Int64, addedAt: Date = Date()) throws {
        let cleaned = section?.trimmingCharacters(in: .whitespacesAndNewlines)
        try run("""
            INSERT INTO project_members (project_id, document_id, added_at, section)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(project_id, document_id) DO UPDATE SET section = excluded.section;
            """) { statement in
            sqlite3_bind_int64(statement, 1, projectID)
            bindText(statement, 2, documentID)
            bindText(statement, 3, Library.isoString(addedAt))
            bindText(statement, 4, (cleaned?.isEmpty ?? true) ? nil : cleaned)
        }
    }

    /// A project's documents with the section each is filed under.
    public func sectionedMembers(ofProject projectID: Int64) throws -> [(DocumentRecord, String?)] {
        try withStatement("""
            SELECT d.*, m.section FROM documents d
            JOIN project_members m ON m.document_id = d.id
            WHERE m.project_id = ?
            ORDER BY m.section IS NULL, m.section COLLATE NOCASE, m.added_at;
            """, bind: { statement in sqlite3_bind_int64(statement, 1, projectID) }) { statement in
            var out: [(DocumentRecord, String?)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                // The section is the column after documents' own, which documentRecord
                // reads by index from the start.
                let section = columnText(statement, sqlite3_column_count(statement) - 1)
                out.append((Library.documentRecord(from: statement), section))
            }
            return out
        }
    }

    /// The sections in use in a project, for offering them rather than making people
    /// retype one they already invented.
    public func sections(ofProject projectID: Int64) throws -> [String] {
        try withStatement("""
            SELECT DISTINCT section FROM project_members
            WHERE project_id = ? AND section IS NOT NULL
            ORDER BY section COLLATE NOCASE;
            """, bind: { statement in sqlite3_bind_int64(statement, 1, projectID) }) { statement in
            var out: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = columnText(statement, 0) { out.append(name) }
            }
            return out
        }
    }
}

public struct TagCount: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var name: String
    public var documents: Int
}
