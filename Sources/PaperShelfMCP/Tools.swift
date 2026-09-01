import Foundation
import PaperShelfCore

/// A scan is what everything else is built on, so it is done once per call and kept for
/// the length of that call only. The server holds no state between requests: this
/// revision of the protocol has no sessions, and a tool that remembered things would give
/// two clients different answers.
private func scan(root: String, recursive: Bool) throws -> [Item] {
    var isFolder: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root, isDirectory: &isFolder) else {
        throw ToolFailure("no such folder or file: \(root)")
    }
    let url = URL(fileURLWithPath: root)
    let jobs = collectJobs(roots: [url], recursive: recursive)
    guard !jobs.isEmpty else { return [] }
    return process(jobs: jobs, options: Options(passwords: [], recursive: recursive, dryRun: true))
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

private let folderSchema: [String: Any] = [
    "type": "object",
    "properties": [
        "folder": ["type": "string", "description": "Absolute path to a folder or a single PDF"],
        "recursive": ["type": "boolean", "description": "Include subfolders. Default true."],
    ],
    "required": ["folder"],
]

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
                    let text = openingText(of: items[index].currentURL, passwords: [], pages: depth)
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
            + "document_id a search handed back. A document the library has already read "
            + "is served from the library; one it has not is read from the file now and "
            + "kept, so the next question about it is free.",
        inputSchema: [
            "type": "object",
            "properties": [
                "document_id": ["type": "string", "description": "From a search or listing. Also accepts a title."],
                "path": ["type": "string", "description": "Absolute path to a PDF, if there is no id."],
                "pages": ["type": "string", "description": "One page or a range, as \"12\" or \"12-20\". Omit for the whole document."],
                "max_characters": ["type": "integer", "description": "Truncate. Default 200000."],
                "password": ["type": "string", "description": "Optional, if the file is locked"],
            ],
        ],
        run: { arguments in
            let (path, id) = try resolveDocument(arguments)
            guard let path else {
                throw ToolFailure("the library knows that document but not where it is now; "
                    + "call it again with 'path'")
            }
            let read = try storedOrExtracted(path: path, documentID: id)
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
        description: "Produce BibTeX entries for the PDFs in a folder, keyed by author and "
            + "year where those can be read from the file.",
        inputSchema: [
            "type": "object",
            "properties": [
                "folder": ["type": "string"],
                "recursive": ["type": "boolean"],
                "type": ["type": "string", "enum": BibType.allCases.map(\.rawValue),
                         "description": "Entry type to emit. Default book."],
            ],
            "required": ["folder"],
        ],
        run: { arguments in
            let items = try scan(root: try requireString(arguments, "folder"),
                                 recursive: optionalBool(arguments, "recursive", default: true))
            guard !items.isEmpty else { throw ToolFailure("no PDFs there") }
            let type = (arguments["type"] as? String).flatMap(BibType.init(rawValue:)) ?? .book
            let entries = bibEntries(for: items, type: type)
            return ToolOutput(text: bibtexDocument(entries),
                              structured: ["entries": entries.count])
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
            + "document_id.",
        inputSchema: [
            "type": "object",
            "properties": [
                "document_id": ["type": "string"],
                "path": ["type": "string", "description": "Absolute path to a PDF"],
                "password": ["type": "string"],
            ],
        ],
        run: { arguments in
            let (path, id) = try resolveDocument(arguments)
            guard let path else {
                throw ToolFailure("the library knows that document but not where it is now; "
                    + "call it again with 'path'")
            }
            let marks = pdfMarks(in: URL(fileURLWithPath: path), passwords: Prefs.passwords)
            let notes = id.flatMap { documentID -> [(body: String, createdAt: String)]? in
                guard let reader = try? LibraryReader.open() else { return nil }
                return try? reader.notes(forDocument: documentID)
            } ?? []
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
            + "than pulling in the whole document. Give it either a path or a document_id.",
        inputSchema: [
            "type": "object",
            "properties": [
                "document_id": ["type": "string"],
                "path": ["type": "string"],
                "page": ["type": "integer", "description": "1-based, as the app shows it"],
                "password": ["type": "string"],
            ],
            "required": ["page"],
        ],
        run: { arguments in
            guard let page = arguments["page"] as? Int, page > 0 else {
                throw ToolFailure("'page' is required and starts at 1")
            }
            let (path, id) = try resolveDocument(arguments)
            guard let path else {
                throw ToolFailure("the library knows that document but not where it is now; "
                    + "call it again with 'path'")
            }
            let read = try storedOrExtracted(path: path, documentID: id)
            let text = try pageSlice(read.markdown, range: "\(page)")
            return ToolOutput(text: text, structured: ["page": page])
        }
    ),

    Tool(
        name: "find_duplicates",
        title: "Find duplicate documents",
        description: "Report documents in a folder that are the same file, the same bytes "
            + "under different names, or the same opening pages under different bytes.",
        inputSchema: folderSchema,
        run: { arguments in
            let items = try scan(root: try requireString(arguments, "folder"),
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
