import Foundation
import PDFHammerCore

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

let libraryTools: [Tool] = [
    Tool(
        name: "list_documents",
        title: "List documents",
        description: "List the PDFs in a folder with their page count, size, embedded "
            + "metadata, and the name PDF Hammer would give each one.",
        inputSchema: folderSchema,
        run: { arguments in
            let items = try scan(root: try requireString(arguments, "folder"),
                                 recursive: optionalBool(arguments, "recursive", default: true))
            let rows = items.map(describe)
            let text = items.isEmpty
                ? "No PDFs found."
                : items.map { "\($0.currentURL.path)  (\($0.pageCount ?? 0) pages)" }
                    .joined(separator: "\n")
            return ToolOutput(text: text, structured: ["count": rows.count, "documents": rows])
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
                "folder": ["type": "string", "description": "Absolute path to search under"],
                "query": ["type": "string", "description": "For example: kant text:\"categorical imperative\""],
                "recursive": ["type": "boolean"],
                "limit": ["type": "integer", "description": "Maximum results. Default 50."],
                "pages_per_document": ["type": "integer",
                                       "description": "How many opening pages a text: term reads. Default 6."],
            ],
            "required": ["folder", "query"],
        ],
        run: { arguments in
            let query = Query(try requireString(arguments, "query"))
            guard !query.isEmpty else { throw ToolFailure("the query is empty") }
            let items = try scan(root: try requireString(arguments, "folder"),
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
        description: "Extract a PDF's text as Markdown, page by page. Works on a "
            + "password-protected file when the password is supplied.",
        inputSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Absolute path to a PDF"],
                "password": ["type": "string", "description": "Optional, if the file is locked"],
                "page_markers": ["type": "boolean", "description": "Write '## Page N' headings. Default true."],
                "max_characters": ["type": "integer", "description": "Truncate. Default 200000."],
            ],
            "required": ["path"],
        ],
        run: { arguments in
            let path = try requireString(arguments, "path")
            guard FileManager.default.fileExists(atPath: path) else {
                throw ToolFailure("no such file: \(path)")
            }
            let passwords = (arguments["password"] as? String).map { [$0] } ?? []
            let markdown = markdownFromPDF(
                url: URL(fileURLWithPath: path), passwords: passwords,
                pageMarkers: optionalBool(arguments, "page_markers", default: true))
            guard !markdown.isEmpty else {
                throw ToolFailure("nothing could be read from that file; it may be locked, "
                                  + "or it may be a scan with no text layer")
            }
            let cap = arguments["max_characters"] as? Int ?? 200_000
            let clipped = markdown.count > cap
                ? String(markdown.prefix(cap)) + "\n\n[truncated at \(cap) characters]"
                : markdown
            return ToolOutput(text: clipped, structured: nil)
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
    // before anything has been indexed. The ones below read the library PDF Hammer itself
    // builds while indexing (projects, tags), through a read-only connection opened in
    // Projects.swift; each one reports a missing library politely (isError, not a crash)
    // rather than assuming one exists.

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
            let limit = arguments["limit"] as? Int ?? 500
            let documents = try reader.documents(inProject: project.id, limit: limit)
            let rows = documents.map(describeDocument)
            let text = documents.isEmpty
                ? "\(project.name) has no documents."
                : documents.map { $0.path ?? "(no known path) \($0.id)" }.joined(separator: "\n")
            return ToolOutput(text: text,
                               structured: ["project": ["id": Int(project.id), "name": project.name],
                                            "count": rows.count, "documents": rows])
        }
    ),

    Tool(
        name: "search_project",
        title: "Search within a project",
        description: "Full-text search the extracted text of the documents in one reading "
            + "project. Only documents PDF Hammer has already extracted text for can match.",
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
            let limit = arguments["limit"] as? Int ?? 50
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
            let limit = arguments["limit"] as? Int ?? 200
            let documents = try reader.documents(taggedWith: tag, limit: limit)
            let rows = documents.map(describeDocument)
            let text = documents.isEmpty
                ? "No documents tagged '\(tag)'."
                : documents.map { $0.path ?? $0.id }.joined(separator: "\n")
            return ToolOutput(text: text, structured: ["tag": tag, "count": rows.count, "documents": rows])
        }
    ),
]
