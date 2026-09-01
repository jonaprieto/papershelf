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
    // `extractedText` already returns an optional; Swift 5's flattening `try?` collapses a
    // throw and "no stored text" into the same single-level optional here, so one `guard let`
    // covers both.
    guard let stored = try? reader.extractedText(forDocument: document.id) else { return row }
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

// These tools read the library PaperShelf itself builds while indexing (projects, tags, and
// the library-wide search above), through the read-only connection Projects.swift opens;
// each one reports a missing library politely (isError, not a crash) rather than assuming
// one exists.

let libraryTools: [Tool] = [
    Tool(
        name: "list_projects",
        title: "List reading projects",
        description: "List the reading projects recorded in the library, with how many "
            + "documents each one holds.",
        inputSchema: ["type": "object", "properties": [String: Any]()],
        run: { _ in
            let reader = try openLibraryOrFail()
            let projects = try reader.projects()
            let rows = projects.map { project -> [String: Any] in
                ["id": Int(project.id), "name": project.name, "created_at": project.createdAt,
                 "document_count": project.documentCount]
            }
            let text = projects.isEmpty
                ? "No projects yet."
                : projects.map { "\($0.name)  (\($0.documentCount) documents)" }
                    .joined(separator: "\n")
            return ToolOutput(text: text, structured: ["count": rows.count, "projects": rows])
        }
    ),

    Tool(
        name: "list_project_documents",
        title: "List a project's documents",
        description: "List the documents in one reading project, with each document's most "
            + "recently known path, its tags, and its page count.",
        inputSchema: [
            "type": "object",
            "properties": [
                "project": ["type": "string", "description": "A project's name, or its id (as a string) from list_projects."],
                "limit": ["type": "integer", "description": "Maximum documents. Default 500."],
            ],
            "required": ["project"],
        ],
        run: { arguments in
            let identifier = try requireString(arguments, "project")
            let reader = try openLibraryOrFail()
            let project = try resolveProject(identifier, in: reader)
            // A negative LIMIT means "unlimited" to SQLite, not "none" or an error, which
            // would silently turn a client's bad input into a full dump of every document
            // in the project; clamping to zero keeps this tool's own "maximum" honest.
            let limit = max(0, arguments["limit"] as? Int ?? 500)
            let documents = try reader.documents(inProject: project.id, limit: limit)
            // The section a document is filed under is most of what a reading list says,
            // so it travels with each row and heads each run in the text.
            let rows = documents.map { document, section -> [String: Any] in
                var row = describeDocument(document)
                if let section { row["section"] = section }
                return row
            }
            var text = ""
            var heading: String??
            for (document, section) in documents {
                if heading == nil || heading! != section {
                    heading = section
                    text += (text.isEmpty ? "" : "\n") + (section ?? "Filed under nothing") + "\n"
                }
                text += "  " + (document.path ?? "(no known path) \(document.id)") + "\n"
            }
            if documents.isEmpty { text = "\(project.name) has no documents." }
            return ToolOutput(text: text,
                               structured: ["project": ["id": Int(project.id), "name": project.name],
                                            "count": rows.count, "documents": rows])
        }
    ),

    Tool(
        name: "search_project",
        title: "Search within a project",
        description: "Full-text search the extracted text of the documents in one reading "
            + "project. Only documents PaperShelf has already extracted text for can match.",
        inputSchema: [
            "type": "object",
            "properties": [
                "project": ["type": "string", "description": "A project's name, or its id (as a string) from list_projects."],
                "query": ["type": "string", "description": "Words to search for, matched as a phrase."],
                "limit": ["type": "integer", "description": "Maximum results. Default 50."],
            ],
            "required": ["project", "query"],
        ],
        run: { arguments in
            let identifier = try requireString(arguments, "project")
            let query = try requireString(arguments, "query")
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolFailure("the query is empty")
            }
            let reader = try openLibraryOrFail()
            let project = try resolveProject(identifier, in: reader)
            // See the identical clamp in list_project_documents: SQLite treats a negative
            // LIMIT as unlimited, not zero or an error.
            let limit = max(0, arguments["limit"] as? Int ?? 50)
            let documents = try reader.search(inProject: project.id, query: query, limit: limit)
            let rows = documents.map(describeDocument)
            let text = documents.isEmpty
                ? "Nothing matched in \(project.name)."
                : documents.map { $0.path ?? $0.id }.joined(separator: "\n")
            return ToolOutput(text: text,
                               structured: ["project": ["id": Int(project.id), "name": project.name],
                                            "matched": rows.count, "documents": rows])
        }
    ),

    Tool(
        name: "list_tags",
        title: "List tags",
        description: "List every tag in the library and how many documents carry it.",
        inputSchema: ["type": "object", "properties": [String: Any]()],
        run: { _ in
            let reader = try openLibraryOrFail()
            let tags = try reader.tags()
            let rows = tags.map { tag -> [String: Any] in
                ["name": tag.name, "document_count": tag.documentCount]
            }
            let text = tags.isEmpty
                ? "No tags yet."
                : tags.map { "\($0.name)  (\($0.documentCount))" }.joined(separator: "\n")
            return ToolOutput(text: text, structured: ["count": rows.count, "tags": rows])
        }
    ),

    Tool(
        name: "documents_by_tag",
        title: "Find documents by tag",
        description: "List the documents carrying a given tag.",
        inputSchema: [
            "type": "object",
            "properties": [
                "tag": ["type": "string", "description": "Tag name, matched case-insensitively."],
                "limit": ["type": "integer", "description": "Maximum documents. Default 200."],
            ],
            "required": ["tag"],
        ],
        run: { arguments in
            let tag = try requireString(arguments, "tag")
            let reader = try openLibraryOrFail()
            // See the identical clamp in list_project_documents: SQLite treats a negative
            // LIMIT as unlimited, not zero or an error.
            let limit = max(0, arguments["limit"] as? Int ?? 200)
            let documents = try reader.documents(taggedWith: tag, limit: limit)
            let rows = documents.map(describeDocument)
            let text = documents.isEmpty
                ? "No documents tagged '\(tag)'."
                : documents.map { $0.path ?? $0.id }.joined(separator: "\n")
            return ToolOutput(text: text, structured: ["tag": tag, "count": rows.count, "documents": rows])
        }
    ),
]
