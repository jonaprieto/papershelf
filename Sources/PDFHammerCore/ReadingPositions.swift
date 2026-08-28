import Foundation
import SQLite3

/// Where a reader got to, and what that makes possible: a shelf that knows which books
/// are open, and an Info panel that can say "page 12 of 248" instead of nothing.
public struct ReadingPosition: Sendable, Equatable {
    public let documentID: String
    /// One-based, the way a page is numbered on the page.
    public var page: Int
    public var pageCount: Int?
    public var updatedAt: Date

    public init(documentID: String, page: Int, pageCount: Int?, updatedAt: Date) {
        self.documentID = documentID
        self.page = page
        self.pageCount = pageCount
        self.updatedAt = updatedAt
    }

    /// How far in, between 0 and 1, or nil when the document's length is unknown.
    ///
    /// Page 1 of 248 is not 0.4% read, it is a book someone has opened; the fraction is
    /// measured from the page turned to, which is what a progress bar is being asked.
    public var fraction: Double? {
        guard let pageCount, pageCount > 1 else { return nil }
        return min(1, max(0, Double(page - 1) / Double(pageCount - 1)))
    }

    /// Whether this counts as being read right now: opened past the first page and not
    /// yet at the last one. A book someone glanced at and a book someone finished are
    /// both not "reading now", and a shelf that says otherwise is a shelf nobody trusts.
    public var isInProgress: Bool {
        guard page > 1 else { return false }
        guard let pageCount else { return true }
        return page < pageCount
    }
}

extension Library {

    /// Records where the reader is. Called as a document is read, so it upserts rather
    /// than failing on a document already being tracked.
    public func rememberReadingPosition(documentID: String, page: Int, pageCount: Int?,
                                        at date: Date = Date()) throws {
        try run("""
            INSERT INTO reading_positions (document_id, page, page_count, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(document_id) DO UPDATE SET
                page = excluded.page, page_count = excluded.page_count,
                updated_at = excluded.updated_at;
            """) { statement in
            bindText(statement, 1, documentID)
            bindInt(statement, 2, max(1, page))
            bindInt(statement, 3, pageCount)
            bindText(statement, 4, Library.isoString(date))
        }
    }

    public func readingPosition(forDocument documentID: String) throws -> ReadingPosition? {
        try withStatement("""
            SELECT page, page_count, updated_at FROM reading_positions WHERE document_id = ?;
            """, bind: { statement in bindText(statement, 1, documentID) }) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return ReadingPosition(
                documentID: documentID,
                page: columnInt(statement, 0) ?? 1,
                pageCount: columnInt(statement, 1),
                updatedAt: columnText(statement, 2).flatMap(Library.isoDate) ?? Date()
            )
        }
    }

    public func forgetReadingPosition(forDocument documentID: String) throws {
        try run("DELETE FROM reading_positions WHERE document_id = ?;") { statement in
            bindText(statement, 1, documentID)
        }
    }

    /// Every path of every document that is part-read, so a shelf can pick its own files
    /// out without asking about each one.
    ///
    /// By path and not by document because the shelf holds files it has just scanned off
    /// the disk; a document renamed keeps both its paths here, which is the same bargain
    /// `storedBibtexByPath` makes and for the same reason.
    public func pathsBeingRead() throws -> Set<String> {
        try withStatement("""
            SELECT l.path, r.page, r.page_count
            FROM reading_positions r
            JOIN locations l ON l.document_id = r.document_id;
            """) { statement in
            var out: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let position = ReadingPosition(
                    documentID: "", page: columnInt(statement, 1) ?? 1,
                    pageCount: columnInt(statement, 2), updatedAt: Date())
                guard position.isInProgress, let path = columnText(statement, 0) else { continue }
                out.insert(path)
            }
            return out
        }
    }

    /// The paths of everything first seen since a date. "Recently added" is a question
    /// about when the library met a file, not about the file's own timestamps, which a
    /// copy or a download rewrites.
    public func pathsFirstSeen(since date: Date) throws -> Set<String> {
        try withStatement("SELECT path FROM locations WHERE first_seen_at >= ?;",
                          bind: { statement in
            bindText(statement, 1, Library.isoString(date))
        }) { statement in
            var out: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let path = columnText(statement, 0) { out.insert(path) }
            }
            return out
        }
    }

    /// The reading position of every part-read document, by path.
    public func readingPositionsByPath() throws -> [String: ReadingPosition] {
        try withStatement("""
            SELECT l.path, r.document_id, r.page, r.page_count, r.updated_at
            FROM reading_positions r
            JOIN locations l ON l.document_id = r.document_id;
            """) { statement in
            var out: [String: ReadingPosition] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let path = columnText(statement, 0) else { continue }
                out[path] = ReadingPosition(
                    documentID: columnText(statement, 1) ?? "",
                    page: columnInt(statement, 2) ?? 1,
                    pageCount: columnInt(statement, 3),
                    updatedAt: columnText(statement, 4).flatMap(Library.isoDate) ?? Date()
                )
            }
            return out
        }
    }
}
