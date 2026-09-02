import Foundation
import SQLite3

/// A named return point in a document. It is deliberately separate from PDF outline
/// chapters, highlights, and the reading position: each answers a different question.
public struct Bookmark: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let documentID: String
    public var page: Int
    public var label: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: Int64, documentID: String, page: Int, label: String,
                createdAt: Date, updatedAt: Date) {
        self.id = id
        self.documentID = documentID
        self.page = page
        self.label = label
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension Library {

    /// Adds one page bookmark, or returns the existing bookmark for that page. The
    /// idempotent behaviour makes an MCP retry safe and leaves toggling to the UI.
    @discardableResult
    public func addBookmark(documentID: String, page: Int, label: String? = nil,
                            at date: Date = Date()) throws -> Bookmark {
        let page = max(1, page)
        let label = normalizedBookmarkLabel(label, page: page)
        let timestamp = Library.isoString(date)
        try run("""
            INSERT INTO bookmarks(document_id, page, label, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(document_id, page) DO NOTHING;
            """) { statement in
            bindText(statement, 1, documentID)
            bindInt(statement, 2, page)
            bindText(statement, 3, label)
            bindText(statement, 4, timestamp)
            bindText(statement, 5, timestamp)
        }
        guard let bookmark = try bookmark(documentID: documentID, page: page) else {
            throw LibraryError.invariantViolated("bookmark \(documentID):\(page) vanished after insertion")
        }
        return bookmark
    }

    public func bookmarks(forDocument documentID: String) throws -> [Bookmark] {
        try withStatement("""
            SELECT id, document_id, page, label, created_at, updated_at
            FROM bookmarks WHERE document_id = ? ORDER BY page, created_at, id;
            """, bind: { statement in
            bindText(statement, 1, documentID)
        }) { statement in
            var results: [Bookmark] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(bookmark(from: statement, fallbackDocumentID: documentID))
            }
            return results
        }
    }

    public func bookmark(documentID: String, page: Int) throws -> Bookmark? {
        try withStatement("""
            SELECT id, document_id, page, label, created_at, updated_at
            FROM bookmarks WHERE document_id = ? AND page = ?;
            """, bind: { statement in
            bindText(statement, 1, documentID)
            bindInt(statement, 2, max(1, page))
        }) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return bookmark(from: statement, fallbackDocumentID: documentID)
        }
    }

    public func bookmark(id: Int64) throws -> Bookmark? {
        try withStatement("""
            SELECT id, document_id, page, label, created_at, updated_at
            FROM bookmarks WHERE id = ?;
            """, bind: { statement in
            sqlite3_bind_int64(statement, 1, id)
        }) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return bookmark(from: statement, fallbackDocumentID: "")
        }
    }

    public func renameBookmark(_ id: Int64, label: String, at date: Date = Date()) throws -> Bookmark {
        guard let existing = try bookmark(id: id) else {
            throw LibraryError.invariantViolated("bookmark (id) does not exist")
        }
        let label = normalizedBookmarkLabel(label, page: existing.page)
        try run("UPDATE bookmarks SET label = ?, updated_at = ? WHERE id = ?;") { statement in
            bindText(statement, 1, label)
            bindText(statement, 2, Library.isoString(date))
            sqlite3_bind_int64(statement, 3, id)
        }
        guard let renamed = try bookmark(id: id) else {
            throw LibraryError.invariantViolated("bookmark (id) vanished after rename")
        }
        return renamed
    }

    public func removeBookmark(_ id: Int64) throws {
        try run("DELETE FROM bookmarks WHERE id = ?;") { statement in
            sqlite3_bind_int64(statement, 1, id)
        }
    }

    private func bookmark(from statement: OpaquePointer, fallbackDocumentID: String) -> Bookmark {
        Bookmark(
            id: sqlite3_column_int64(statement, 0),
            documentID: columnText(statement, 1) ?? fallbackDocumentID,
            page: max(1, columnInt(statement, 2) ?? 1),
            label: columnText(statement, 3) ?? "",
            createdAt: columnText(statement, 4).flatMap(Library.isoDate) ?? .distantPast,
            updatedAt: columnText(statement, 5).flatMap(Library.isoDate) ?? .distantPast
        )
    }

    private func normalizedBookmarkLabel(_ label: String?, page: Int) -> String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Page \(page)" : trimmed
    }
}
