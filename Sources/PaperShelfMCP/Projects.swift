import Foundation
import SQLite3
import PaperShelfCore

/// A second connection to the same database `Library` (`PaperShelfCore/Library.swift`) owns,
/// opened strictly read-only.
///
/// `Library.init` opens `SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE`, which is right for the
/// app that owns this data and wrong for a tool server that only reads it: that flag
/// combination would let a bug here turn this process into a second writer, and would
/// silently create an empty library on a machine where none has been indexed yet, which is
/// not this process's call to make. `Library.swift` belongs to another part of this app and
/// is not touched to add a read-only mode; the natural long-term home for what this type does
/// would be a `Library` initializer overload taking `readOnly: Bool` and passing
/// `SQLITE_OPEN_READONLY` in place of `SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE`. WAL mode
/// (already the file's own journal mode, set once by whichever process created it) is what
/// makes a second, independent, read-only connection safe to hold open at the same time as
/// the GUI's read-write one: a reader never blocks a writer and a writer never blocks a
/// reader.
///
/// This type also answers questions `Library`'s own public API has no room for: a global tag
/// list and a tag-to-documents lookup are library-wide, not "for one document"; a
/// project-scoped search needs to join `extracted_text_fts` against `project_members` in one
/// statement to keep bm25's ranking meaningful over just that project. None of this writes or
/// reshapes anything; it only reads the tables `Library.swift`'s own migration already made.
final class LibraryReader {
    private let db: OpaquePointer

    private init(db: OpaquePointer) {
        self.db = db
    }

    deinit {
        sqlite3_close_v2(db)
    }

    /// `PAPERSHELF_LIBRARY_PATH` overrides the location, for `Tools/mcp-check.sh`: a check
    /// script needs a scratch database it controls, not whatever real library this machine's
/// copy of PaperShelf may or may not have built. Production callers never set it, so they
    /// get exactly the path `Library.swift` itself resolves to.
    private static func databaseURL() -> URL? {
        if let overridden = ProcessInfo.processInfo.environment["PAPERSHELF_LIBRARY_PATH"] {
            return URL(fileURLWithPath: overridden)
        }
        return libraryDatabaseURL()
    }

    /// Nil, without throwing, when there is nothing to open: a library nobody has indexed yet
    /// is a normal state, not a failure. `SQLITE_OPEN_READONLY` never creates a file on its
    /// own, so checking existence first is what stands between a missing library and this
    /// call quietly creating one.
    static func open() throws -> LibraryReader? {
        guard let url = databaseURL(), FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
                ?? "sqlite code \(result)"
            if let handle { sqlite3_close(handle) }
            throw ToolFailure("could not open the library database: \(message)")
        }
        sqlite3_busy_timeout(handle, 5000)
        return LibraryReader(db: handle)
    }

    // MARK: - Projects

    struct ProjectSummary {
        let id: Int64
        let name: String
        let createdAt: String
        let documentCount: Int
    }

    func projects() throws -> [ProjectSummary] {
        try withStatement("""
            SELECT p.id, p.name, p.created_at, COUNT(m.document_id)
            FROM projects p
            LEFT JOIN project_members m ON m.project_id = p.id
            GROUP BY p.id
            ORDER BY p.created_at;
            """) { statement in
            var results: [ProjectSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(ProjectSummary(
                    id: sqlite3_column_int64(statement, 0),
                    name: columnText(statement, 1) ?? "",
                    createdAt: columnText(statement, 2) ?? "",
                    documentCount: Int(sqlite3_column_int64(statement, 3))
                ))
            }
            return results
        }
    }

    /// Resolves `identifier` the way a caller would name a project back to a row: its numeric
    /// id if it parses as one (what `list_projects` hands back), otherwise an exact,
    /// case-insensitive match on its name.
    func project(matching identifier: String) throws -> (id: Int64, name: String)? {
        if let id = Int64(identifier) {
            return try withStatement("SELECT id, name FROM projects WHERE id = ?;", bind: { statement in
                sqlite3_bind_int64(statement, 1, id)
            }) { statement in
                guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                return (sqlite3_column_int64(statement, 0), columnText(statement, 1) ?? "")
            }
        }
        return try withStatement(
            "SELECT id, name FROM projects WHERE name = ? COLLATE NOCASE LIMIT 1;",
            bind: { statement in bindText(statement, 1, identifier) }
        ) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return (sqlite3_column_int64(statement, 0), columnText(statement, 1) ?? "")
        }
    }

    // MARK: - Documents (one row shape, shared by project listings, tag lookups, and search)

    struct DocumentSummary {
        let id: String
        let title: String?
        let author: String?
        let byteCount: Int?
        let pageCount: Int?
        let documentInfo: [String: String]
        /// The most recently seen of possibly several known locations: the one worth
        /// suggesting, mirroring the newest-wins choice `Library.touchLocation` itself makes
        /// when a path is re-seen.
        let path: String?
        let tags: [String]
    }

    /// `char(31)` (unit separator) joins the tag list: a tag name is free text and could
    /// itself contain a comma, but never a control character, so this is the one join
    /// character that can be split back on without ambiguity.
    private static let documentColumns = """
        d.id, d.title, d.author, d.byte_count, d.page_count, d.document_info,
        (SELECT path FROM locations WHERE document_id = d.id ORDER BY last_seen_at DESC LIMIT 1),
        (SELECT GROUP_CONCAT(t.name, char(31)) FROM tags t
         JOIN document_tags dt ON dt.tag_id = t.id WHERE dt.document_id = d.id)
        """

    private func documentSummary(from statement: OpaquePointer) -> DocumentSummary {
        let info = columnText(statement, 5).flatMap { text -> [String: String]? in
            guard let data = text.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([String: String].self, from: data)
        } ?? [:]
        let tags = columnText(statement, 7)?.split(separator: "\u{1F}").map(String.init) ?? []
        return DocumentSummary(
            id: columnText(statement, 0) ?? "",
            title: columnText(statement, 1),
            author: columnText(statement, 2),
            byteCount: columnInt(statement, 3),
            pageCount: columnInt(statement, 4),
            documentInfo: info,
            path: columnText(statement, 6),
            tags: tags
        )
    }

    /// A project's documents with the section each is filed under, nil for the ones that
    /// are in the project but filed under nothing. Ordered by section so a reader sees the
    /// list the way it was organised rather than the order things were added.
    func documents(inProject projectID: Int64, limit: Int) throws -> [(DocumentSummary, String?)] {
        try withStatement("""
            SELECT \(Self.documentColumns), m.section
            FROM documents d
            JOIN project_members m ON m.document_id = d.id
            WHERE m.project_id = ?
            ORDER BY m.section IS NULL, m.section COLLATE NOCASE, m.added_at
            LIMIT ?;
            """, bind: { statement in
            sqlite3_bind_int64(statement, 1, projectID)
            sqlite3_bind_int64(statement, 2, Int64(limit))
        }) { statement in
            var results: [(DocumentSummary, String?)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let section = columnText(statement, sqlite3_column_count(statement) - 1)
                results.append((documentSummary(from: statement), section))
            }
            return results
        }
    }

    /// A project's true membership, independent of any cap a caller elsewhere puts on how
    /// many of its documents it actually lists. `bibliography`'s "project" scope
    /// (`LibraryTools.swift`) needs this precisely because `documents(inProject:limit:)`
    /// above caps at 1000: without a count taken separately from that capped list, a
    /// project larger than the cap reported exactly as many documents as the cap allowed
    /// and nothing said the cap had even been hit.
    func memberCount(ofProject projectID: Int64) throws -> Int {
        try withStatement("SELECT COUNT(*) FROM project_members WHERE project_id = ?;",
                          bind: { statement in
            sqlite3_bind_int64(statement, 1, projectID)
        }) { statement in
            sqlite3_step(statement)
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    /// Scopes the same phrase match `Library.fullTextSearch` uses to one project's members,
    /// by joining `project_members` into the query itself rather than filtering results
    /// afterward: filtering afterward would rank against the whole library and then throw
    /// rows away, which for a broad query in a large library could drop every match this
    /// project actually has before `limit` is ever reached.
    ///
    /// `offset` defaults to zero so `search_project` (`Tools.swift`), which has no reason to
    /// page through a single project's results yet, keeps calling this with three arguments.
    func search(inProject projectID: Int64, query: String, limit: Int, offset: Int = 0) throws -> [DocumentSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let phrase = "\"\(trimmed.replacingOccurrences(of: "\"", with: "\"\""))\""
        return try withStatement("""
            SELECT \(Self.documentColumns)
            FROM extracted_text_fts
            JOIN extracted_text e ON e.rowid = extracted_text_fts.rowid
            JOIN documents d ON d.id = e.document_id
            JOIN project_members m ON m.document_id = d.id AND m.project_id = ?
            WHERE extracted_text_fts MATCH ?
            ORDER BY bm25(extracted_text_fts)
            LIMIT ? OFFSET ?;
            """, bind: { statement in
            sqlite3_bind_int64(statement, 1, projectID)
            bindText(statement, 2, phrase)
            sqlite3_bind_int64(statement, 3, Int64(limit))
            sqlite3_bind_int64(statement, 4, Int64(offset))
        }) { statement in
            var results: [DocumentSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(documentSummary(from: statement))
            }
            return results
        }
    }

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

    func noteRevision(forDocument id: String) throws -> String? {
        try withStatement("SELECT MAX(updated_at) FROM notes WHERE document_id = ?;",
                          bind: { statement in bindText(statement, 1, id) }) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return columnText(statement, 0)
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

    // MARK: - Tags

    struct TagSummary {
        let name: String
        let documentCount: Int
    }

    func tags() throws -> [TagSummary] {
        try withStatement("""
            SELECT t.name, COUNT(dt.document_id)
            FROM tags t
            LEFT JOIN document_tags dt ON dt.tag_id = t.id
            GROUP BY t.id
            ORDER BY t.name COLLATE NOCASE;
            """) { statement in
            var results: [TagSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(TagSummary(name: columnText(statement, 0) ?? "",
                                           documentCount: Int(sqlite3_column_int64(statement, 1))))
            }
            return results
        }
    }

    func documents(taggedWith tag: String, limit: Int) throws -> [DocumentSummary] {
        try withStatement("""
            SELECT \(Self.documentColumns)
            FROM documents d
            JOIN document_tags dt ON dt.document_id = d.id
            JOIN tags t ON t.id = dt.tag_id
            WHERE t.name = ? COLLATE NOCASE
            ORDER BY d.last_seen_at DESC
            LIMIT ?;
            """, bind: { statement in
            bindText(statement, 1, tag)
            sqlite3_bind_int64(statement, 2, Int64(limit))
        }) { statement in
            var results: [DocumentSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(documentSummary(from: statement))
            }
            return results
        }
    }

    /// As `memberCount(ofProject:)`, for a tag: the true count behind
    /// `documents(taggedWith:limit:)`'s own 1000-document cap.
    func documentCount(taggedWith tag: String) throws -> Int {
        try withStatement("""
            SELECT COUNT(*) FROM document_tags dt
            JOIN tags t ON t.id = dt.tag_id
            WHERE t.name = ? COLLATE NOCASE;
            """, bind: { statement in
            bindText(statement, 1, tag)
        }) { statement in
            sqlite3_step(statement)
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    // MARK: - SQLite plumbing
    //
    // Mirrors the shape of `Library.swift`'s own private statement/bind/column helpers; that
    // file's versions are `private` to it, and this is a different module besides, so nothing
    // here can reach them.

    private func withStatement<T>(
        _ sql: String,
        bind: (OpaquePointer) throws -> Void = { _ in },
        body: (OpaquePointer) throws -> T
    ) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ToolFailure("library query failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        return try body(statement)
    }
}

/// `SQLITE_TRANSIENT` is the cast macro `((sqlite3_destructor_type)-1)`; the Clang importer
/// does not bridge `#define` cast macros, so it is spelled out by hand here too (see the
/// identical comment in `Library.swift`, which cannot be reused across modules).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
}

private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard let cString = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: cString)
}

private func columnInt(_ statement: OpaquePointer, _ index: Int32) -> Int? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, index))
}

// MARK: - Wiring shared by the project/tag tools in Tools.swift

/// The message a project-shaped tool gives back when nobody has indexed a library yet. Not a
/// JSON-RPC error and not silence: a normal, expected state, said plainly enough that an
/// agent reading it knows what to do next.
func openLibraryOrFail() throws -> LibraryReader {
    guard let reader = try LibraryReader.open() else {
        throw ToolFailure("No library has been indexed yet. Open PaperShelf and add a folder "
            + "to the library, or use list_documents / search_documents on a folder path "
            + "directly.")
    }
    return reader
}

func resolveProject(_ identifier: String, in reader: LibraryReader) throws -> (id: Int64, name: String) {
    guard let project = try reader.project(matching: identifier) else {
        throw ToolFailure("no project named or numbered '\(identifier)'; call list_projects first")
    }
    return project
}

func describeDocument(_ document: LibraryReader.DocumentSummary) -> [String: Any] {
    var out: [String: Any] = ["id": document.id]
    if let path = document.path { out["path"] = path }
    if let title = document.title { out["title"] = title }
    if let author = document.author { out["author"] = author }
    if let pages = document.pageCount { out["pages"] = pages }
    if let bytes = document.byteCount { out["bytes"] = bytes }
    if !document.tags.isEmpty { out["tags"] = document.tags }
    if !document.documentInfo.isEmpty { out["metadata"] = document.documentInfo }
    return out
}
