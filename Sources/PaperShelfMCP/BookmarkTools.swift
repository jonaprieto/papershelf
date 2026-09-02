import Foundation
import PaperShelfCore

private func bookmarkDocument(_ arguments: [String: Any],
                              reader: LibraryReader) throws -> LibraryReader.DocumentSummary {
    let (_, id, _) = try resolveDocument(arguments)
    guard let id, let document = try reader.document(matching: id) else {
        throw ToolFailure("the library has no indexed document for that path; "
            + "call list_documents or search_documents first")
    }
    return document
}

private func bookmarkPage(_ arguments: [String: Any]) throws -> Int {
    guard let page = arguments["page"] as? Int, page > 0 else {
        throw ToolFailure("'page' is required and must be a positive integer")
    }
    return page
}

private func bookmarkID(_ arguments: [String: Any]) throws -> Int64 {
    if let id = arguments["id"] as? Int { return Int64(id) }
    if let id = arguments["id"] as? Int64 { return id }
    if let id = arguments["id"] as? String, let value = Int64(id) { return value }
    throw ToolFailure("'id' is required and must be a bookmark id from list_bookmarks")
}

private func bookmarkRow(_ bookmark: LibraryReader.BookmarkSummary) -> [String: Any] {
    return [
        "id": Int(bookmark.id),
        "document_id": bookmark.documentID,
        "page": bookmark.page,
        "label": bookmark.label,
        "created_at": bookmark.createdAt,
        "updated_at": bookmark.updatedAt,
    ]
}

private func bookmarkRow(_ bookmark: Bookmark) -> [String: Any] {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return [
        "id": Int(bookmark.id),
        "document_id": bookmark.documentID,
        "page": bookmark.page,
        "label": bookmark.label,
        "created_at": formatter.string(from: bookmark.createdAt),
        "updated_at": formatter.string(from: bookmark.updatedAt),
    ]
}

private func verifyBookmarkScope(_ bookmark: LibraryReader.BookmarkSummary,
                                arguments: [String: Any],
                                reader: LibraryReader) throws {
    guard arguments["path"] != nil || arguments["document_id"] != nil else { return }
    let document = try bookmarkDocument(arguments, reader: reader)
    guard document.id == bookmark.documentID else {
        throw ToolFailure("bookmark \(bookmark.id) belongs to document \(bookmark.documentID), "
            + "not the document supplied")
    }
}

let bookmarkTools: [Tool] = [
    Tool(
        name: "list_bookmarks",
        title: "List document bookmarks",
        description: "List durable PaperShelf bookmarks for one document, ordered by page. "
            + "Use path or document_id. The revision changes when a bookmark is added, "
            + "renamed, or removed; pass since_revision to poll without repeating unchanged "
            + "rows.",
        inputSchema: [
            "type": "object",
            "properties": [
                "document_id": ["type": "string", "description": "A document id from a PaperShelf result."],
                "path": ["type": "string", "description": "Absolute path to a PDF."],
                "since_revision": ["type": "string", "description": "A revision from an earlier call."],
            ],
        ],
        run: { arguments in
            let reader = try openLibraryOrFail()
            let document = try bookmarkDocument(arguments, reader: reader)
            let revision = try reader.bookmarkRevision(forDocument: document.id)
            let bookmarks = try reader.bookmarks(forDocument: document.id)
            if let since = arguments["since_revision"] as? String, since == revision {
                return ToolOutput(
                    text: "No bookmark changes since revision \(revision).",
                    structured: ["changed": false, "revision": revision,
                                 "document_id": document.id, "count": bookmarks.count]
                )
            }
            let rows = bookmarks.map(bookmarkRow)
            let text = rows.isEmpty
                ? "No bookmarks in \(document.path ?? document.id)."
                : rows.map { "p. \($0["page"] ?? "")  \($0["label"] ?? "")" }
                    .joined(separator: "\n")
            return ToolOutput(
                text: text,
                structured: ["changed": true, "revision": revision,
                             "document_id": document.id, "count": rows.count,
                             "bookmarks": rows]
            )
        }
    ),
]

let bookmarkWriteTools: [Tool] = [
    Tool(
        name: "add_bookmark",
        title: "Add a document bookmark",
        description: "Add a durable bookmark to a document page. Adding the same document "
            + "page again is safe and returns the existing bookmark. Use an optional label; "
            + "otherwise PaperShelf names it Page N.",
        inputSchema: [
            "type": "object",
            "properties": [
                "document_id": ["type": "string", "description": "A document id from a PaperShelf result."],
                "path": ["type": "string", "description": "Absolute path to a PDF."],
                "page": ["type": "integer", "description": "One-based PDF page number."],
                "label": ["type": "string", "description": "Optional name shown in the bookmarks rail."],
            ],
        ],
        run: { arguments in
            let page = try bookmarkPage(arguments)
            let reader = try openLibraryOrFail()
            let document = try bookmarkDocument(arguments, reader: reader)
            let existing = try reader.bookmark(documentID: document.id, page: page)
            let label = arguments["label"] as? String
            let library = try openLibraryForWriting()
            let bookmark = try blocking {
                try await library.addBookmark(documentID: document.id, page: page, label: label)
            }
            let created = existing == nil
            return ToolOutput(
                text: "\(created ? "Added" : "Kept") bookmark “\(bookmark.label)” at page \(bookmark.page).",
                structured: ["created": created, "bookmark": bookmarkRow(bookmark)]
            )
        }
    ),

    Tool(
        name: "rename_bookmark",
        title: "Rename a document bookmark",
        description: "Rename one bookmark returned by list_bookmarks. The id is stable; "
            + "the label is trimmed and must be non-empty. Optionally include document_id "
            + "or path to verify the bookmark belongs to that document.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "integer", "description": "Bookmark id from list_bookmarks."],
                "label": ["type": "string", "description": "New non-empty bookmark name."],
                "document_id": ["type": "string"],
                "path": ["type": "string"],
            ],
            "required": ["id", "label"],
        ],
        run: { arguments in
            let id = try bookmarkID(arguments)
            let label = try requireString(arguments, "label")
            let reader = try openLibraryOrFail()
            guard let existing = try reader.bookmark(id: id) else {
                throw ToolFailure("no bookmark with id \(id); call list_bookmarks first")
            }
            try verifyBookmarkScope(existing, arguments: arguments, reader: reader)
            let library = try openLibraryForWriting()
            let bookmark = try blocking { try await library.renameBookmark(id, label: label) }
            return ToolOutput(text: "Renamed bookmark \(id) to “\(bookmark.label)”.",
                              structured: ["bookmark": bookmarkRow(bookmark)])
        }
    ),

    Tool(
        name: "remove_bookmark",
        title: "Remove a document bookmark",
        description: "Remove one bookmark returned by list_bookmarks. This only removes "
            + "the bookmark metadata; it does not alter the PDF or its highlights. "
            + "Optionally include document_id or path to verify its scope.",
        inputSchema: [
            "type": "object",
            "properties": [
                "id": ["type": "integer", "description": "Bookmark id from list_bookmarks."],
                "document_id": ["type": "string"],
                "path": ["type": "string"],
            ],
            "required": ["id"],
        ],
        run: { arguments in
            let id = try bookmarkID(arguments)
            let reader = try openLibraryOrFail()
            guard let existing = try reader.bookmark(id: id) else {
                throw ToolFailure("no bookmark with id \(id); call list_bookmarks first")
            }
            try verifyBookmarkScope(existing, arguments: arguments, reader: reader)
            let library = try openLibraryForWriting()
            try blocking { try await library.removeBookmark(id) }
            return ToolOutput(text: "Removed bookmark \(id) from page \(existing.page).",
                              structured: ["removed": true, "id": Int(id),
                                           "document_id": existing.documentID,
                                           "page": existing.page])
        }
    ),
]
