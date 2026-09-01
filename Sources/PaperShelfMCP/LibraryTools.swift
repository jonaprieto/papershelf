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
///
/// The price of that quote is a full load of the document's stored Markdown, up to two
/// million characters, scanned case and diacritic insensitively; a default search pays that
/// for up to twenty hits, a limit raised to the clamp for up to a hundred. Acceptable as it
/// stands, but nothing here would warn a later change that raises a default limit.
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

/// Either identifier, from either half of the tool surface, plus whether a file currently
/// sits at the path handed back. The library-backed tools hand back an id and the
/// folder-backed ones a path; without this, a researcher cannot read a document a search
/// just found them. When both are given, `path` wins, matching the order checked below.
///
/// `exists` is computed once, here, rather than by each of `resolveDocument`'s three
/// callers separately -- but it is left for them to act on, rather than this function
/// refusing outright, because what a missing file means differs by caller. A document_id
/// whose only location on record has moved out from under it (renamed by
/// `apply_file_changes` before this fix recorded the move, or renamed by hand outside
/// PaperShelf entirely) still has real, useful answers available for two of the three:
/// `read_document`/`read_page` can serve it from a cached extraction, and `list_highlights`
/// can still return the notes written about it. Only a caller with nothing else to fall
/// back on has to treat `exists == false` as the whole answer. What every caller must not
/// do is treat a stale path as though it still named a readable file: that is exactly how
/// a renamed document ended up reporting no highlights, as a success, rather than saying
/// its recorded location no longer holds a file.
func resolveDocument(_ arguments: [String: Any]) throws -> (path: String?, id: String?, exists: Bool) {
    if let path = arguments["path"] as? String, !path.isEmpty {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ToolFailure("no such file: \(path)")
        }
        let id = (try? LibraryReader.open())
            .flatMap { try? $0?.document(matching: path) }?.id
        return (path, id, true)
    }
    guard let identifier = arguments["document_id"] as? String, !identifier.isEmpty else {
        throw ToolFailure("give either 'path' or 'document_id'")
    }
    let reader = try openLibraryOrFail()
    guard let document = try reader.document(matching: identifier) else {
        throw ToolFailure("the library has no document with id, path or title "
            + "'\(identifier)'; call search_documents or list_documents first")
    }
    let exists = document.path.map(FileManager.default.fileExists(atPath:)) ?? false
    return (document.path, document.id, exists)
}

/// The document's text, read from the library when it is there and read from the file and
/// stored when it is not.
///
/// Extracting here is bounded to the one document a researcher asked for, which is the
/// difference between this and indexing: it is worth doing inside a tool call because it
/// is one file, and the next question about the same document is then free.
///
/// Two tool calls racing on the same unindexed document each extract independently and each
/// write; `setExtractedText` is an upsert on the document's id, so the worst outcome is
/// duplicated extraction work and a last-write-wins overwrite with equivalent text, never a
/// corrupt row. Acceptable without a lock at the volume one researcher's chat client drives.
///
/// `pathExists` comes from `resolveDocument`, which has already checked it once; it only
/// matters here on a cache miss, since a cache hit answers from the library and never
/// touches `path` at all. Without it, a document whose recorded location has moved out
/// from under it and has nothing cached yet fell into `indexedMarkdown` failing to open a
/// file that is not there, and reported "it may be locked, or it may be a scan with no
/// text layer" -- true of a file that exists and cannot be read, and false of one that
/// simply is not there any more.
func storedOrExtracted(path: String, documentID: String?, pathExists: Bool) throws -> (markdown: String, extracted: Bool) {
    // `LibraryReader.open()` is itself a throwing function returning an optional; under this
    // project's Swift 5 language mode `try?` flattens that to a single-level optional, so one
    // `let reader = try? LibraryReader.open()` already unwraps it fully. A second `let reader`
    // after that would be conditionally binding an already non-optional value, which does not
    // compile (see the identical note on `hit` above).
    //
    // The cache read is `try?` for the same reason: a transient failure reading the cached
    // row, a busy or locked connection say, is a cache concern, not the caller's problem. The
    // file is right there and readable, so that failure falls through to fresh extraction
    // rather than aborting a read that would otherwise succeed.
    if let documentID,
       let reader = try? LibraryReader.open(),
       let stored = try? reader.extractedText(forDocument: documentID),
       stored.format != nil, !stored.markdown.isEmpty {
        return (stored.markdown, false)
    }
    guard pathExists else {
        throw ToolFailure("PaperShelf's last known location for that document, \(path), "
            + "no longer has a file there, and nothing is cached for it either. It may "
            + "have been moved or renamed since the library last saw it; open PaperShelf "
            + "so it can rescan, or call this again with the file's current 'path'.")
    }
    guard let read = indexedMarkdown(of: URL(fileURLWithPath: path),
                                     passwords: Prefs.passwords) else {
        throw ToolFailure("nothing could be read from that file; it may be locked, or it "
            + "may be a scan with no text layer")
    }
    // Caching the result is best-effort end to end: opening the connection can fail (the
    // library file has vanished since the document was resolved, say) just as easily as the
    // write two lines down already does, and neither failure should cost the researcher text
    // PDFKit already successfully extracted.
    if let documentID, !read.text.isEmpty, let library = try? openLibraryForWriting() {
        try? blocking { try await library.setExtractedText(read.text, forDocument: documentID,
                                                           format: read.format) }
    }
    return (read.text, true)
}

/// One page range out of page-marked Markdown, as "12" or "12-20".
///
/// Page-marked Markdown only ever carries a "## Page N" heading for a page that had text
/// (`indexedMarkdown` skips blank pages entirely), so a requested page missing from it is
/// ambiguous on its own: it could be a page past the end of the document, or a page inside
/// it that is a scanned image with no text layer. The highest page number seen anywhere in
/// the Markdown disambiguates the two: a request past that high-water mark is past what was
/// ever read, while a request at or before it fell on a page that has no text of its own.
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
    var highestSeen = 0
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("## Page ") {
            current = Int(line.dropFirst("## Page ".count).prefix { $0.isNumber })
            if let current { highestSeen = max(highestSeen, current) }
        }
        if let current, current >= first, current <= last { kept.append(String(line)) }
    }
    guard !kept.isEmpty else {
        if highestSeen > 0 && first > highestSeen {
            throw ToolFailure("that document's extracted text only reaches page "
                + "\(highestSeen); page \(first) is beyond it")
        }
        throw ToolFailure("pages \(first) to \(last) have no text of their own; they may "
            + "be scanned images with no text layer")
    }
    return kept.joined(separator: "\n")
}

/// What one bibliography scope resolved to. `requested` is how many documents the scope
/// considered in total (project/tag membership up to the 1000-document cap below, or the
/// length of `document_ids`); `paths` is the subset of those with a usable path to actually
/// build a citation from. The two can differ: `DocumentSummary.path` is the most recently
/// seen of possibly several known locations, and a document the library has indexed can
/// currently have none on record. `skipped` names, where a name is known, the documents
/// left out for exactly that reason, so a caller who asked for eight documents and got
/// seven back can tell why, rather than reading seven as though it had been the whole
/// answer.
///
/// `uncountedByCap` is a second, independent shortfall: how many of a project's or tag's
/// true membership were never even looked at, because `documents(inProject:limit:)` and
/// `documents(taggedWith:limit:)` cap what they gather at 1000 before `requested` or
/// `skipped` are ever computed from it. Zero for every scope with no such cap (`folder`,
/// `document_ids`), and for a `project`/`tag` scope whose true membership does not exceed
/// it. Without this, a project of 1500 documents reported a `requested` of 1000 -- the
/// post-cap count -- with nothing distinguishing that from a project that truly held 1000,
/// so the very shortfall reporting built to stop a bibliography under-reporting silently
/// compared itself against an already-truncated number.
struct BibliographyResolution {
    let paths: [String]
    let requested: Int
    let skipped: [String]
    let uncountedByCap: Int
}

/// The files one bibliography scope names. Every scope resolves to paths, because a BibTeX
/// entry is built by reading the PDF, not by reading the library's row about it -- except
/// that a document known to the library can have no location on record at all, which is why
/// this reports what it had to leave out rather than only what it found.
///
/// `project` and `tag` are capped at 1000 documents, generous for a reading project but not
/// a promise: naming a scope larger than that quietly cites only the first 1000 -- which is
/// exactly what `uncountedByCap`, on `BibliographyResolution`, exists to say out loud rather
/// than leave silent. Whichever scope is named, `bibliography`'s caller re-reads every path
/// this returns through `process(dryRun: true)`, so a scope of several hundred documents is
/// several hundred PDF opens before that tool answers. The folder scope pays for that scan
/// twice over: once here to list candidate paths, once more there to build the `Item`s
/// `bibEntries` reads, because every scope is resolved to plain paths through this one
/// function rather than the folder case keeping the `Item`s it already built. The folder
/// scope never has anything to skip: its candidates come from files found on disk, which is
/// a path by construction.
func bibliographyPaths(_ arguments: [String: Any], scope: String) throws -> BibliographyResolution {
    switch scope {
    case "folder":
        let folder = try requireString(arguments, "folder")
        let paths = try scan(root: folder,
                             recursive: optionalBool(arguments, "recursive", default: true))
            .map(\.currentURL.path)
        return BibliographyResolution(paths: paths, requested: paths.count, skipped: [], uncountedByCap: 0)
    case "project":
        let reader = try openLibraryOrFail()
        let project = try resolveProject(try requireString(arguments, "project"), in: reader)
        let documents = try reader.documents(inProject: project.id, limit: 1000).map(\.0)
        let total = try reader.memberCount(ofProject: project.id)
        return BibliographyResolution(
            paths: documents.compactMap(\.path),
            requested: documents.count,
            skipped: documents.filter { $0.path == nil }.map { $0.title ?? $0.id },
            uncountedByCap: max(0, total - documents.count))
    case "tag":
        let reader = try openLibraryOrFail()
        let tag = try requireString(arguments, "tag")
        let documents = try reader.documents(taggedWith: tag, limit: 1000)
        let total = try reader.documentCount(taggedWith: tag)
        return BibliographyResolution(
            paths: documents.compactMap(\.path),
            requested: documents.count,
            skipped: documents.filter { $0.path == nil }.map { $0.title ?? $0.id },
            uncountedByCap: max(0, total - documents.count))
    default:
        let ids = arguments["document_ids"] as? [String] ?? []
        let reader = try openLibraryOrFail()
        var paths: [String] = []
        var skipped: [String] = []
        for id in ids {
            guard let document = try reader.document(matching: id) else {
                skipped.append(id)
                continue
            }
            guard let path = document.path else {
                skipped.append(document.title ?? document.id)
                continue
            }
            paths.append(path)
        }
        return BibliographyResolution(paths: paths, requested: ids.count, skipped: skipped, uncountedByCap: 0)
    }
}

/// Duplicates across the whole library, from hashes it already computed. Nothing here
/// opens a PDF, so this answers over fourteen thousand documents as fast as over ten. It
/// finds only byte-for-byte copies; the folder scan additionally finds documents whose
/// opening pages match under different bytes, which needs the files themselves.
func libraryDuplicates() throws -> ToolOutput {
    let reader = try openLibraryOrFail()
    let groups = try reader.duplicateGroupsByHash()
    guard !groups.isEmpty else {
        return ToolOutput(text: "No duplicates in the library: no two documents share "
            + "identical bytes. Documents that only match on their opening pages are not "
            + "found this way; call find_duplicates with a folder to check for those.",
                          structured: nil)
    }
    let described = groups.map { group -> [String: Any] in
        ["kind": "identical",
         "paths": group.documents.compactMap(\.path),
         "document_ids": group.documents.map(\.id)]
    }
    let text = groups.map { group in
        "identical:\n" + group.documents.map { "  " + ($0.path ?? $0.id) }
            .joined(separator: "\n")
    }.joined(separator: "\n\n")
    return ToolOutput(text: text, structured: ["groups": described])
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
            // in the project; clamping the lower bound to zero keeps this tool's own
            // "maximum" honest. The upper bound mirrors list_documents and
            // search_documents, which clamp both ends of `limit` rather than only the
            // lower one, and 1000 matches the cap bibliographyPaths already puts on a
            // project scope, so nothing in this file quietly answers past it.
            let limit = max(0, min(arguments["limit"] as? Int ?? 500, 1000))
            let documents = try reader.documents(inProject: project.id, limit: limit)
            // Neither this tool nor search_project extracts text for a document that has
            // none: a project can hold hundreds of files, and reading every one of them
            // inside a single tool call is the same unbounded wait search_documents refuses
            // for a folder. What this must not do is hide the shortfall, so it is counted
            // and said plainly instead.
            let unread = documents.filter { document, _ in
                (try? reader.extractedText(forDocument: document.id)) == nil
            }.count
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
            if unread > 0 {
                text += "\n\n\(unread) of these have no text on record, so a search of this "
                    + "project cannot see inside them. Reading them once in PaperShelf, or "
                    + "asking for one of them by name, fixes that."
            }
            return ToolOutput(text: text,
                               structured: ["project": ["id": Int(project.id), "name": project.name],
                                            "count": rows.count, "documents": rows,
                                            "without_text": unread])
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
                "cursor": ["type": "string", "description": "From a previous result's next_cursor."],
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
            // LIMIT as unlimited, not zero or an error. The upper bound of 100 matches
            // search_documents, the other full-text search tool in this file.
            let limit = max(0, min(arguments["limit"] as? Int ?? 50, 100))
            let offset = try decodeCursor(arguments["cursor"])
            let documents = try reader.search(inProject: project.id, query: query,
                                              limit: limit, offset: offset)
            let rows = documents.map { hit($0, query: query, reader: reader) }
            let text = documents.isEmpty
                ? "Nothing matched in \(project.name)."
                : documents.map { $0.path ?? $0.id }.joined(separator: "\n")
            var structured: [String: Any] = [
                "project": ["id": Int(project.id), "name": project.name],
                "matched": rows.count, "documents": rows,
            ]
            // Mirrors list_documents and search_documents: a page exactly as large as the
            // limit may not be the last one, so the client gets a cursor to ask for more
            // rather than this tool going permanently silent about matches past the first
            // page, as it did before this field existed.
            if documents.count == limit && limit > 0 {
                structured["next_cursor"] = encodeCursor(offset + limit)
            }
            return ToolOutput(text: text, structured: structured)
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
            // LIMIT as unlimited, not zero or an error, and the upper bound of 1000
            // matches the cap bibliographyPaths already puts on a tag scope.
            let limit = max(0, min(arguments["limit"] as? Int ?? 200, 1000))
            let documents = try reader.documents(taggedWith: tag, limit: limit)
            let rows = documents.map(describeDocument)
            let text = documents.isEmpty
                ? "No documents tagged '\(tag)'."
                : documents.map { $0.path ?? $0.id }.joined(separator: "\n")
            return ToolOutput(text: text, structured: ["tag": tag, "count": rows.count, "documents": rows])
        }
    ),
]
