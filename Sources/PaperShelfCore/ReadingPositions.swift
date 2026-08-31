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

    /// Every document that has been opened, newest first, with where its file is.
    ///
    /// Opening a file is what writes a reading position, so this is the record of what has
    /// been read rather than of what has been filed. The shelf uses it for the documents
    /// that live outside every source: a paper opened from Downloads is in no folder the
    /// app scans, and without this there is nowhere it could appear.
    public func openedPaths(limit: Int = 500) throws -> [(path: String, openedAt: Date)] {
        try withStatement("""
            SELECT l.path, r.updated_at
            FROM reading_positions r
            JOIN locations l ON l.document_id = r.document_id
            ORDER BY r.updated_at DESC
            LIMIT ?;
            """, bind: { statement in
            sqlite3_bind_int64(statement, 1, Int64(limit))
        }) { statement in
            var found: [(path: String, openedAt: Date)] = []
            var seen: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let path = columnText(statement, 0), seen.insert(path).inserted else { continue }
                found.append((path, columnText(statement, 1).flatMap(Library.isoDate) ?? Date()))
            }
            return found
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

extension Library {

    /// The paths of every document carrying no tag at all.
    ///
    /// Not something the query language can ask: it searches for tags a file has, and
    /// "none of them" is the absence of a term rather than a term.
    public func pathsWithoutTags() throws -> Set<String> {
        try withStatement("""
            SELECT l.path FROM locations l
            WHERE NOT EXISTS (SELECT 1 FROM document_tags t WHERE t.document_id = l.document_id);
            """) { statement in
            var out: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let path = columnText(statement, 0) { out.insert(path) }
            }
            return out
        }
    }
}

// MARK: - Full text, with the line it was found on

/// One full-text hit, with enough of the sentence around it to recognise.
public struct TextHit: Sendable, Equatable, Identifiable {
    public let documentID: String
    public let title: String
    public let author: String?
    /// The matched run with a little of its sentence on either side, the matched words
    /// marked with the delimiters asked for.
    public let snippet: String
    /// The page the snippet came from, read back off the `<!-- page:N -->` marker the
    /// extracted text carries, or nil when the text has no markers.
    public let page: Int?

    public var id: String { documentID + "#" + (page.map(String.init) ?? "?") }

    public init(documentID: String, title: String, author: String?, snippet: String, page: Int?) {
        self.documentID = documentID
        self.title = title
        self.author = author
        self.snippet = snippet
        self.page = page
    }
}

extension Library {

    /// Full-text hits with the passage each one was found in.
    ///
    /// `fullTextSearch` answers which documents match, which is the right answer for
    /// ranking a project's documents and the wrong one for a palette: a list of titles
    /// makes a person open each of them to find out which sentence matched.
    public func fullTextHits(_ text: String, limit: Int = 5) throws -> [TextHit] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let phrase = "\"\(trimmed.replacingOccurrences(of: "\"", with: "\"\""))\""
        return try withStatement("""
            SELECT d.id, d.title, d.author,
                   snippet(extracted_text_fts, 0, '', '', '…', 14)
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
            var out: [TextHit] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let snippet = columnText(statement, 3) ?? ""
                out.append(TextHit(documentID: columnText(statement, 0) ?? "",
                                   title: columnText(statement, 1) ?? "untitled",
                                   author: columnText(statement, 2),
                                   snippet: tidySnippet(snippet),
                                   page: pageMarker(in: snippet)))
            }
            return out
        }
    }
}

/// The page a snippet came from, when the extracted text carries the marker convention
/// `<!-- page:N -->`. A snippet cut mid-page carries no marker, which is not an error --
/// it is a hit whose page is unknown, and saying so beats guessing page 1.
public func pageMarker(in snippet: String) -> Int? {
    guard let range = snippet.range(of: "<!-- page:", options: .backwards) else { return nil }
    let rest = snippet[range.upperBound...]
    let digits = rest.prefix { $0.isNumber }
    return Int(digits)
}

/// A snippet as a person reads it: the page markers taken out, the whitespace collapsed.
public func tidySnippet(_ snippet: String) -> String {
    var text = snippet
    while let start = text.range(of: "<!-- page:"), let end = text.range(of: "-->", range: start.lowerBound..<text.endIndex) {
        text.removeSubrange(start.lowerBound..<end.upperBound)
    }
    return text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)
}
