import Foundation
import PaperShelfCore

/// A scan is what everything else is built on, so it is done once per call and kept for
/// the length of that call only. The server holds no state between requests: this
/// revision of the protocol has no sessions, and a tool that remembered things would give
/// two clients different answers.
func scan(root: String, recursive: Bool) throws -> [Item] {
    var isFolder: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root, isDirectory: &isFolder) else {
        throw ToolFailure("no such folder or file: \(root)")
    }
    let url = URL(fileURLWithPath: root)
    let jobs = collectJobs(roots: [url], recursive: recursive)
    guard !jobs.isEmpty else { return [] }
    return process(jobs: jobs, options: Options(passwords: Prefs.passwords, recursive: recursive, dryRun: true))
}

private func describe(_ item: Item) -> [String: Any] {
    var out: [String: Any] = [
        "path": item.currentURL.path,
        "name": item.sourceName,
        "suggested_name": item.destinationName,
        "status": item.status.rawValue,
    ]
    if let pages = item.pageCount { out["pages"] = pages }
    if let bytes = item.byteCount { out["bytes"] = bytes }
    if !item.documentInfo.isEmpty { out["metadata"] = item.documentInfo }
    return out
}

let folderTools: [Tool] = [
    Tool(
        name: "list_documents",
        title: "List documents",
        description: "With no folder, the library as a whole: how many documents it holds, "
            + "how many have had their text read, and the most recently seen of them. This "
            + "is the place to start when the researcher has not named a folder. With a "
            + "folder, the PDFs in it with their page count, size, embedded metadata, and "
            + "the name PaperShelf would give each one.",
        inputSchema: [
            "type": "object",
            "properties": [
                "folder": ["type": "string",
                           "description": "Absolute path to a folder or a single PDF. Omit to read the library."],
                "recursive": ["type": "boolean", "description": "Include subfolders. Default true. Folder only."],
                "limit": ["type": "integer", "description": "Maximum documents. Default 100. Library only."],
                "cursor": ["type": "string", "description": "From a previous result's next_cursor. Library only."],
            ],
        ],
        run: { arguments in
            if let folder = arguments["folder"] as? String, !folder.isEmpty {
                let items = try scan(root: folder,
                                     recursive: optionalBool(arguments, "recursive", default: true))
                let rows = items.map(describe)
                let text = items.isEmpty
                    ? "No PDFs found."
                    : items.map { "\($0.currentURL.path)  (\($0.pageCount ?? 0) pages)" }
                        .joined(separator: "\n")
                return ToolOutput(text: text, structured: ["count": rows.count, "documents": rows])
            }
            return try libraryOverview(arguments)
        }
    ),

    Tool(
        name: "search_documents",
        title: "Search documents",
        description: "Search a folder of PDFs. The query language is the app's own: bare "
            + "words match the filename, and field terms are supported, including "
            + "text:<words>, year:, pages:>100, size:>2mb and status:. A text: term reads "
            + "the opening pages of every document, which is slow over a large folder and "
            + "will not find a phrase buried deep in a book. Raise pages_per_document to "
            + "look further in, at proportional cost.",
        inputSchema: [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "For example: kant text:\"categorical imperative\". With no folder, the whole query is matched as a phrase against the text of every document in the library."],
                "folder": ["type": "string", "description": "Absolute path to search under. Omit to search the library, which is faster and finds passages."],
                "recursive": ["type": "boolean", "description": "Folder only."],
                "limit": ["type": "integer", "description": "Maximum results. Default 20 for the library, 50 for a folder."],
                "cursor": ["type": "string", "description": "From a previous result's next_cursor. Library only."],
                "pages_per_document": ["type": "integer",
                                       "description": "How many opening pages a text: term reads. Folder only. Default 6."],
            ],
            "required": ["query"],
        ],
        run: { arguments in
            let raw = try requireString(arguments, "query")
            guard let folder = arguments["folder"] as? String, !folder.isEmpty else {
                return try searchLibrary(raw, arguments)
            }
            let query = Query(raw)
            guard !query.isEmpty else { throw ToolFailure("the query is empty") }
            let items = try scan(root: folder,
                                 recursive: optionalBool(arguments, "recursive", default: true))
            let prepared = PreparedQuery(query)
            let limit = arguments["limit"] as? Int ?? 50

            // Reading a page of a PDF is the expensive part, so the documents are read
            // at once rather than one after another, the same as the app does it.
            var texts = [String?](repeating: nil, count: items.count)
            if query.needsText {
                let depth = arguments["pages_per_document"] as? Int ?? 6
                let lock = NSLock()
                DispatchQueue.concurrentPerform(iterations: items.count) { index in
                    let text = openingText(of: items[index].currentURL, passwords: Prefs.passwords, pages: depth)
                    lock.lock()
                    texts[index] = text
                    lock.unlock()
                }
            }
            let hits = items.indices
                .filter { matches(Searchable(item: items[$0], text: texts[$0]), prepared) }
                .map { items[$0] }
            let shown = Array(hits.prefix(limit))
            let text = shown.isEmpty
                ? "Nothing matched."
                : shown.map(\.currentURL.path).joined(separator: "\n")
                    + (hits.count > shown.count ? "\n(\(hits.count - shown.count) more)" : "")
            return ToolOutput(text: text,
                              structured: ["matched": hits.count,
                                           "documents": shown.map(describe)])
        }
    ),

    Tool(
        name: "read_document",
        title: "Read a document as Markdown",
        description: "A document's text, page by page. Give it either a path or the "
            + "document_id a search handed back; path wins if both are given. A document "
            + "the library has already read is served from the library; one it has not is "
            + "read from the file now and kept, so the next question about it is free.",
        inputSchema: [
            "type": "object",
            "properties": [
                "document_id": ["type": "string", "description": "From a search or listing. Also accepts a title."],
                "path": ["type": "string", "description": "Absolute path to a PDF, if there is no id."],
                "pages": ["type": "string", "description": "One page or a range, as \"12\" or \"12-20\". Omit for the whole document."],
                "max_characters": ["type": "integer", "description": "Truncate. Default 200000."],
            ],
        ],
        run: { arguments in
            let (path, id, exists) = try resolveDocument(arguments)
            guard let path else {
                throw ToolFailure("the library knows that document but not where it is now; "
                    + "call it again with 'path'")
            }
            let read = try storedOrExtracted(path: path, documentID: id, pathExists: exists)
            var markdown = read.markdown
            if let range = arguments["pages"] as? String, !range.isEmpty {
                markdown = try pageSlice(markdown, range: range)
            }
            guard !markdown.isEmpty else {
                throw ToolFailure("that document has no text layer to read")
            }
            let cap = arguments["max_characters"] as? Int ?? 200_000
            let clipped = markdown.count > cap
                ? String(markdown.prefix(cap)) + "\n\n[truncated at \(cap) characters]"
                : markdown
            return ToolOutput(text: clipped,
                              structured: ["extracted_now": read.extracted,
                                           "truncated": markdown.count > cap])
        }
    ),

    Tool(
        name: "bibliography",
        title: "Build a BibTeX bibliography",
        description: "BibTeX entries for a set of documents, keyed by author and year "
            + "where those can be read. Name exactly one of folder, project, tag or "
            + "document_ids: a researcher who has just been shown eight results can cite "
            + "those eight by id.",
        inputSchema: [
            "type": "object",
            "properties": [
                "folder": ["type": "string"],
                "project": ["type": "string", "description": "A project's name or id."],
                "tag": ["type": "string"],
                "document_ids": ["type": "array", "items": ["type": "string"]],
                "recursive": ["type": "boolean", "description": "Folder only."],
                "type": ["type": "string", "enum": BibType.allCases.map(\.rawValue),
                         "description": "Entry type to emit. Default book."],
            ],
        ],
        run: { arguments in
            // `presence` tells apart three states a caller can leave a scope key in: absent
            // (not worth mentioning in an error), present but empty (a mistake worth its own
            // sentence, since an empty string or array silently filtered out the same as an
            // absent key would let a typo'd scope fall through to whichever other scope was
            // validly named), and present with a value (a real vote for that scope).
            let keys = ["folder", "project", "tag", "document_ids"]
            func presence(_ key: String) -> Bool? {
                if let text = arguments[key] as? String { return text.isEmpty ? false : true }
                if let list = arguments[key] as? [Any] { return list.isEmpty ? false : true }
                return nil
            }
            let states = keys.map { ($0, presence($0)) }
            let empties = states.filter { $0.1 == false }.map(\.0)
            guard empties.isEmpty else {
                throw ToolFailure("\(empties.joined(separator: " and ")) "
                    + (empties.count == 1 ? "was given empty" : "were given empty")
                    + "; name a value, or leave it out entirely")
            }
            let named = states.filter { $0.1 == true }.map(\.0)
            guard named.count == 1 else {
                throw ToolFailure(named.isEmpty
                    ? "name one of folder, project, tag or document_ids"
                    : "name only one of folder, project, tag or document_ids; "
                      + "you named \(named.joined(separator: " and "))")
            }
            let type = (arguments["type"] as? String).flatMap(BibType.init(rawValue:)) ?? .book
            let resolution = try bibliographyPaths(arguments, scope: named[0])
            guard !resolution.paths.isEmpty else {
                if resolution.requested > 0 {
                    throw ToolFailure("nothing to cite there: none of the "
                        + "\(resolution.requested) named document"
                        + (resolution.requested == 1 ? "" : "s")
                        + " has a location on record")
                }
                throw ToolFailure("nothing to cite there")
            }
            // The entries come from the files themselves, whichever scope named them: a
            // BibTeX key is built out of what the PDF says about itself, which the library
            // does not store in the shape `bibEntries` reads. `collectJobs` (rather than
            // constructing `Job` values directly) both filters to real PDFs and dedupes, and
            // is the only way to build one from outside PaperShelfCore: `Job`'s memberwise
            // initializer is not public even though its stored properties are.
            let jobs = collectJobs(roots: resolution.paths.map { URL(fileURLWithPath: $0) },
                                   recursive: false)
            let items = process(jobs: jobs,
                                options: Options(passwords: Prefs.passwords, recursive: false,
                                                 dryRun: true))
            let entries = bibEntries(for: items, type: type)
            var structured: [String: Any] = ["entries": entries.count, "scope": named[0]]
            var text = bibtexDocument(entries)
            // A scope can resolve to more documents than it could find a location for; a
            // researcher who named eight documents and gets seven cited needs to be told
            // which one dropped out, not left to notice a short bibliography on their own.
            let shortfall = resolution.requested - resolution.paths.count
            if shortfall > 0 {
                structured["requested"] = resolution.requested
                structured["cited"] = resolution.paths.count
                structured["skipped_documents"] = resolution.skipped
                text += "\n\n\(shortfall) of \(resolution.requested) named document"
                    + (resolution.requested == 1 ? "" : "s")
                    + " could not be cited: no location is on record for "
                    + resolution.skipped.joined(separator: ", ") + "."
            }
            return ToolOutput(text: text, structured: structured)
        }
    ),

    Tool(
        name: "list_highlights",
        title: "Read what the reader marked",
        description: "Every highlight, underline, strikeout and sticky note in a PDF, with "
            + "the text each one covers, the note attached to it, and its page, plus "
            + "anything written about the document in PaperShelf's own notes. This is what "
            + "the person reading the document chose to mark, so it is the best starting "
            + "point for discussing the document with them. Give it either a path or a "
            + "document_id; path wins if both are given.",
        inputSchema: [
            "type": "object",
            "properties": [
                "document_id": ["type": "string"],
                "path": ["type": "string", "description": "Absolute path to a PDF"],
            ],
        ],
        run: { arguments in
            let (path, id, exists) = try resolveDocument(arguments)
            guard let path else {
                throw ToolFailure("the library knows that document but not where it is now; "
                    + "call it again with 'path'")
            }
            let notes = id.flatMap { documentID -> [(body: String, createdAt: String)]? in
                guard let reader = try? LibraryReader.open() else { return nil }
                return try? reader.notes(forDocument: documentID)
            } ?? []
            // A renamed or moved document reads as though nothing were marked in it if
            // this falls through to `pdfMarks`, which cannot open a file that is not
            // there and answers `[]` exactly the way it would for a document that
            // genuinely has no marks. Marks come only from the live file -- unlike
            // `read_document`/`read_page`, there is no cached copy of them to fall back
            // on -- so a missing file means marks are unknown, not empty, and has to be
            // said that way rather than folded into the ordinary empty case below.
            guard exists else {
                let noteRows = notes.map { ["body": $0.body, "created_at": $0.createdAt] }
                guard !notes.isEmpty else {
                    throw ToolFailure("PaperShelf's last known location for that document, "
                        + "\(path), no longer has a file there, so its highlights cannot "
                        + "be checked. It may have been moved or renamed since the "
                        + "library last saw it; open PaperShelf so it can rescan, or call "
                        + "this again with the file's current 'path'.")
                }
                let text = "That document's file could not be found at its last known "
                    + "location (\(path)), so its highlights could not be checked. Here "
                    + "is what has been written about it in PaperShelf:\n"
                    + notes.map { "  " + $0.body }.joined(separator: "\n")
                return ToolOutput(text: text,
                                  structured: ["count": 0, "marks": [], "notes": noteRows,
                                               "file_missing": true])
            }
            let marks = pdfMarks(in: URL(fileURLWithPath: path), passwords: Prefs.passwords)
            guard !marks.isEmpty || !notes.isEmpty else {
                return ToolOutput(text: "Nothing is marked in that document, and nothing "
                                        + "has been written about it.", structured: nil)
            }
            let rows = marks.map { mark -> [String: Any] in
                var row: [String: Any] = ["page": mark.page, "kind": mark.kind]
                if !mark.quoted.isEmpty { row["quoted"] = mark.quoted }
                if !mark.note.isEmpty { row["note"] = mark.note }
                return row
            }
            let noteRows = notes.map { ["body": $0.body, "created_at": $0.createdAt] }
            var text = marks.map { mark in
                var line = "p.\(mark.page) [\(mark.kind)]"
                if !mark.quoted.isEmpty { line += " \"\(mark.quoted)\"" }
                if !mark.note.isEmpty { line += "\n    note: \(mark.note)" }
                return line
            }.joined(separator: "\n")
            if !notes.isEmpty {
                text += (text.isEmpty ? "" : "\n\n") + "About the document:\n"
                    + notes.map { "  " + $0.body }.joined(separator: "\n")
            }
            return ToolOutput(text: text,
                              structured: ["count": rows.count, "marks": rows, "notes": noteRows])
        }
    ),

    Tool(
        name: "read_page",
        title: "Read one page",
        description: "The text of a single page, for reading around a highlight rather "
            + "than pulling in the whole document. Give it either a path or a "
            + "document_id; path wins if both are given.",
        inputSchema: [
            "type": "object",
            "properties": [
                "document_id": ["type": "string"],
                "path": ["type": "string"],
                "page": ["type": "integer", "description": "1-based, as the app shows it"],
            ],
            "required": ["page"],
        ],
        run: { arguments in
            guard let page = arguments["page"] as? Int, page > 0 else {
                throw ToolFailure("'page' is required and starts at 1")
            }
            let (path, id, exists) = try resolveDocument(arguments)
            guard let path else {
                throw ToolFailure("the library knows that document but not where it is now; "
                    + "call it again with 'path'")
            }
            let read = try storedOrExtracted(path: path, documentID: id, pathExists: exists)
            let text = try pageSlice(read.markdown, range: "\(page)")
            return ToolOutput(text: text, structured: ["page": page])
        }
    ),

    Tool(
        name: "find_duplicates",
        title: "Find duplicate documents",
        description: "Report duplicate documents. With no folder, the whole library: only "
            + "documents with identical bytes, found from a hash the library already "
            + "computed. An empty result there means no two documents in the library are "
            + "byte-for-byte the same copy, not that nothing in it is similar. With a "
            + "folder, a broader check that opens the files themselves: the same file, the "
            + "same bytes under different names, or the same opening pages under different "
            + "bytes.",
        inputSchema: [
            "type": "object",
            "properties": [
                "folder": ["type": "string", "description": "Absolute path. Omit to check the whole library."],
                "recursive": ["type": "boolean", "description": "Folder only. Default true."],
            ],
        ],
        run: { arguments in
            guard let folder = arguments["folder"] as? String, !folder.isEmpty else {
                return try libraryDuplicates()
            }
            let items = try scan(root: folder,
                                 recursive: optionalBool(arguments, "recursive", default: true))
            let groups = duplicateGroups(in: items)
            guard !groups.isEmpty else { return ToolOutput(text: "No duplicates.", structured: nil) }
            let described = groups.map { group -> [String: Any] in
                ["kind": String(describing: group.kind),
                 "paths": group.items.map(\.currentURL.path)]
            }
            let text = groups.map { group in
                "\(group.kind):\n" + group.items.map { "  " + $0.currentURL.path }
                    .joined(separator: "\n")
            }.joined(separator: "\n\n")
            return ToolOutput(text: text, structured: ["groups": described])
        }
    ),

    // The tools above scan a folder fresh on every call, which is all that is possible
    // before anything has been indexed. The library-backed tools (projects, tags, and the
    // whole-library forms of list_documents and search_documents above) live in
    // LibraryTools.swift instead.
]
