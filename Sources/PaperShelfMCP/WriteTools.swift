import Foundation
import PaperShelfCore

/// The tools that change something. Everything else in this server reads.
///
/// Two kinds of change, kept apart on purpose. These two write rows in the library:
/// reversible, invisible on disk, and no PDF is touched. `propose_file_changes` and
/// `apply_file_changes`, below, move actual files and are gated behind a preference that
/// is off until somebody turns it on.
let writeTools: [Tool] = [
    Tool(
        name: "add_to_project",
        title: "File documents into a reading project",
        description: "Put documents into a reading project, creating the project when the "
            + "name is not already one. Optionally file them under a section and attach a "
            + "note. Documents are named by the document_id a search handed back, or by "
            + "absolute path.",
        inputSchema: [
            "type": "object",
            "properties": [
                "project": ["type": "string", "description": "A project's name, or its id. An unknown name creates it."],
                "document_ids": ["type": "array", "items": ["type": "string"]],
                "paths": ["type": "array", "items": ["type": "string"],
                          "description": "Absolute paths, for documents the library may not know yet."],
                "section": ["type": "string", "description": "Which part of the reading list these are filed under."],
                "note": ["type": "string", "description": "Attached to each document, not to the project."],
            ],
            "required": ["project"],
        ],
        run: { arguments in
            let name = try requireString(arguments, "project")
            let reader = try openLibraryOrFail()
            let existing = try reader.project(matching: name)
            let ids = try namedDocuments(arguments, reader: reader)
            guard !ids.isEmpty else {
                throw ToolFailure("name at least one document, by document_ids or paths")
            }
            let library = try openLibraryForWriting()
            let section = arguments["section"] as? String
            let note = arguments["note"] as? String

            let projectID: Int64 = try blocking {
                if let existing { return existing.id }
                return try await library.createProject(name: name).id
            }
            try blocking {
                for id in ids {
                    try await library.addMember(id, toProject: projectID)
                    if let section, !section.isEmpty {
                        try await library.setSection(section, forDocument: id, inProject: projectID)
                    }
                    if let note, !note.isEmpty {
                        _ = try await library.addNote(note, toDocument: id)
                    }
                }
            }
            let text = "Filed \(ids.count) document\(ids.count == 1 ? "" : "s") into "
                + "\(name)\(existing == nil ? ", which is new" : "")."
            return ToolOutput(text: text,
                              structured: ["project": ["id": Int(projectID), "name": name],
                                           "created": existing == nil,
                                           "filed": ids.count])
        }
    ),

    Tool(
        name: "set_tags",
        title: "Tag and untag documents",
        description: "Add and remove tags on a set of documents in one call, so \"tag "
            + "these six as read and drop the todo tag\" is one step rather than twelve.",
        inputSchema: [
            "type": "object",
            "properties": [
                "document_ids": ["type": "array", "items": ["type": "string"]],
                "paths": ["type": "array", "items": ["type": "string"]],
                "add": ["type": "array", "items": ["type": "string"]],
                "remove": ["type": "array", "items": ["type": "string"]],
            ],
        ],
        run: { arguments in
            let reader = try openLibraryOrFail()
            let ids = try namedDocuments(arguments, reader: reader)
            guard !ids.isEmpty else {
                throw ToolFailure("name at least one document, by document_ids or paths")
            }
            let adding = (arguments["add"] as? [String] ?? []).filter { !$0.isEmpty }
            let removing = (arguments["remove"] as? [String] ?? []).filter { !$0.isEmpty }
            guard !adding.isEmpty || !removing.isEmpty else {
                throw ToolFailure("give 'add', 'remove', or both")
            }
            let library = try openLibraryForWriting()
            try blocking {
                for id in ids {
                    for tag in adding { try await library.addTag(tag, toDocument: id) }
                    for tag in removing { try await library.removeTag(tag, fromDocument: id) }
                }
            }
            let text = "\(ids.count) document\(ids.count == 1 ? "" : "s"): "
                + "added \(adding.joined(separator: ", ").ifEmpty("nothing")), "
                + "removed \(removing.joined(separator: ", ").ifEmpty("nothing"))."
            return ToolOutput(text: text,
                              structured: ["documents": ids.count,
                                           "added": adding.count, "removed": removing.count])
        }
    ),
]

/// The documents a write tool was pointed at, by id or by path, in one list.
///
/// A path the library has never seen is indexed first rather than skipped: a researcher
/// who names a file by path means that file, and `Library.addMembers(paths:)` deliberately
/// skips unknown ones, which would be a silent no-op here.
func namedDocuments(_ arguments: [String: Any], reader: LibraryReader) throws -> [String] {
    var ids: [String] = []
    for identifier in arguments["document_ids"] as? [String] ?? [] {
        guard let document = try reader.document(matching: identifier) else {
            throw ToolFailure("the library has no document '\(identifier)'; "
                + "call search_documents or list_documents first")
        }
        ids.append(document.id)
    }
    let paths = (arguments["paths"] as? [String] ?? []).filter { !$0.isEmpty }
    if !paths.isEmpty {
        let library = try openLibraryForWriting()
        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else {
                throw ToolFailure("no such file: \(path)")
            }
            if let known = try reader.document(matching: path) {
                ids.append(known.id)
                continue
            }
            let records: [DocumentRecord] = try blocking {
                try await library.indexDocuments([indexInput(for: URL(fileURLWithPath: path))])
            }
            guard let first = records.first else {
                throw ToolFailure("could not record \(path) in the library")
            }
            ids.append(first.id)
        }
    }
    // The same document named twice, once by id and once by path, is one document.
    var seen = Set<String>()
    return ids.filter { seen.insert($0).inserted }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
