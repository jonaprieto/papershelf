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
            + "name is not already one, matched case-insensitively even when the name is "
            + "purely numeric, so a project called \"2024\" is only ever created once. "
            + "Optionally file them under a section and attach a note; a document that "
            + "already carries the exact same note is left alone rather than getting a "
            + "second copy. Documents are named by the document_id a search handed back, "
            + "or by absolute path. If one named document cannot be filed, the rest still "
            + "are; the result names which succeeded and which did not.",
        inputSchema: [
            "type": "object",
            "properties": [
                "project": ["type": "string", "description": "A project's name, or its id. An unknown name creates it."],
                "document_ids": ["type": "array", "items": ["type": "string"]],
                "paths": ["type": "array", "items": ["type": "string"],
                          "description": "Absolute paths, for documents the library may not know yet."],
                "section": ["type": "string", "description": "Which part of the reading list these are filed under."],
                "note": ["type": "string", "description": "Attached to each document, not to the project. "
                          + "Skipped for a document that already carries this exact note, so a retried "
                          + "call cannot duplicate it."],
            ],
            "required": ["project"],
        ],
        run: { arguments in
            let name = try requireString(arguments, "project")
            let reader = try openLibraryOrFail()
            var existing = try reader.project(matching: name)
            if existing == nil {
                // `project(matching:)` looks an identifier up as an id only when it parses
                // as one, and never falls back to a name match in that case: right for a
                // caller naming a project by the id `list_projects` handed back, wrong for
                // a caller naming a project "2024", which would otherwise create a fresh
                // "2024" project on every call, since no project ever has id 2024.
                // `project(matching:)` itself is not changed, since other callers depend
                // on its id-first behaviour and a numeric name colliding with a real id is
                // genuinely ambiguous; a name match is tried here instead, only once the
                // id lookup has already come up empty. Creating a second project with the
                // same name is unrecoverable from chat, since nothing here can merge two
                // projects, so reusing one on a name match is always the safer guess.
                existing = try reader.projects()
                    .first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                    .map { (id: $0.id, name: $0.name) }
            }
            let ids = try namedDocuments(arguments, reader: reader)
            guard !ids.isEmpty else {
                throw ToolFailure("name at least one document, by document_ids or paths")
            }
            let library = try openLibraryForWriting()
            let section = arguments["section"] as? String
            let note = arguments["note"] as? String
            let created = existing == nil

            let projectID: Int64
            let projectName: String
            if let existing {
                projectID = existing.id
                // The project's own stored name, not the caller's spelling: filing into
                // "Reading List" by typing "reading list" answers with "Reading List",
                // not an echo of the request.
                projectName = existing.name
            } else {
                projectID = try blocking { try await library.createProject(name: name).id }
                projectName = name
            }

            // "Filed" and "noted" are a before/after diff, not the size of the request:
            // `addMember` and `addNote` are each their own statement, and a repeat call
            // with the same arguments should say nothing changed, not report the same
            // "success" a second time as though it were fresh work.
            let alreadyMember: Set<String> = created
                ? []
                : Set(try reader.documents(inProject: projectID, limit: Int.max).map { $0.0.id })
            let alreadyNoted: [String: Bool]
            if let note, !note.isEmpty {
                var noted: [String: Bool] = [:]
                for id in ids {
                    noted[id] = try reader.notes(forDocument: id).contains { $0.body == note }
                }
                alreadyNoted = noted
            } else {
                alreadyNoted = [:]
            }

            // Each document's writes are attempted independently: `addMember`,
            // `setSection`, and `addNote` are each their own auto-committing statement,
            // so one document throwing must not undo documents already written, nor stop
            // the ones still to come. A researcher filing fifty papers should not lose all
            // fifty because one of them could not be filed.
            let outcomes: [WriteOutcome] = try blocking {
                var collected: [WriteOutcome] = []
                for id in ids {
                    do {
                        try await library.addMember(id, toProject: projectID)
                        if let section, !section.isEmpty {
                            try await library.setSection(section, forDocument: id, inProject: projectID)
                        }
                        if let note, !note.isEmpty, alreadyNoted[id] != true {
                            _ = try await library.addNote(note, toDocument: id)
                        }
                        collected.append(WriteOutcome(id: id, error: nil))
                    } catch {
                        collected.append(WriteOutcome(id: id, error: String(describing: error)))
                    }
                }
                return collected
            }

            let succeeded = outcomes.filter { $0.error == nil }.map(\.id)
            let failed = outcomes.filter { $0.error != nil }
            let filed = succeeded.filter { !alreadyMember.contains($0) }.count
            let alreadyThere = succeeded.count - filed

            var text = "Filed \(filed) new document\(filed == 1 ? "" : "s") into \(projectName)"
            if alreadyThere > 0 {
                text += " (\(alreadyThere) already there)"
            }
            if created { text += ", which is new" }
            text += "."
            if !failed.isEmpty {
                text += " \(failed.count) document\(failed.count == 1 ? "" : "s") could not "
                    + "be filed: \(failed.map(\.id).joined(separator: ", "))."
            }

            return ToolOutput(
                text: text,
                structured: [
                    "project": ["id": Int(projectID), "name": projectName],
                    "created": created,
                    "filed": filed,
                    "succeeded": succeeded.count,
                    "failed": failed.count,
                    "failed_documents": failed.map { ["id": $0.id, "error": $0.error ?? ""] },
                ],
                isError: !failed.isEmpty
            )
        }
    ),

    Tool(
        name: "set_tags",
        title: "Tag and untag documents",
        description: "Add and remove tags on a set of documents in one call, so \"tag "
            + "these six as read and drop the todo tag\" is one step rather than twelve. "
            + "Adding a tag a document already carries, or removing one it does not have, "
            + "changes nothing and is reported as such rather than as fresh work. If one "
            + "named document cannot be updated, the rest still are; the result names "
            + "which succeeded and which did not.",
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

            // Tag names collide case-insensitively (`tags.name` is `UNIQUE COLLATE
            // NOCASE`), so both snapshots are lower-cased before diffing; otherwise
            // "Kant" already on a document and "kant" in `add` would look like a change
            // that never happened.
            func tagSet(for id: String) throws -> Set<String> {
                Set((try reader.document(matching: id)?.tags ?? []).map { $0.lowercased() })
            }
            var before: [String: Set<String>] = [:]
            for id in ids { before[id] = try tagSet(for: id) }

            // Each document is attempted independently, the same as add_to_project: one
            // document's tag write throwing must not undo the documents already tagged,
            // nor stop the ones still to come.
            let outcomes: [WriteOutcome] = try blocking {
                var collected: [WriteOutcome] = []
                for id in ids {
                    do {
                        for tag in adding { try await library.addTag(tag, toDocument: id) }
                        for tag in removing { try await library.removeTag(tag, fromDocument: id) }
                        collected.append(WriteOutcome(id: id, error: nil))
                    } catch {
                        collected.append(WriteOutcome(id: id, error: String(describing: error)))
                    }
                }
                return collected
            }

            var after: [String: Set<String>] = [:]
            for id in ids { after[id] = try tagSet(for: id) }

            // What actually changed, not the size of the request: `addTag` and
            // `removeTag` both quietly no-op on a repeat, so a model retrying after a
            // timeout cannot otherwise tell real work from a call that landed nothing.
            var added = 0
            var removed = 0
            for id in ids {
                let beforeSet = before[id] ?? []
                let afterSet = after[id] ?? []
                added += afterSet.subtracting(beforeSet).count
                removed += beforeSet.subtracting(afterSet).count
            }

            let succeeded = outcomes.filter { $0.error == nil }.map(\.id)
            let failed = outcomes.filter { $0.error != nil }

            var text = "\(ids.count) document\(ids.count == 1 ? "" : "s"): "
                + "added \(added) tag\(added == 1 ? "" : "s"), removed \(removed) "
                + "tag\(removed == 1 ? "" : "s")."
            if !failed.isEmpty {
                text += " \(failed.count) document\(failed.count == 1 ? "" : "s") could not "
                    + "be updated: \(failed.map(\.id).joined(separator: ", "))."
            }

            return ToolOutput(
                text: text,
                structured: [
                    "documents": ids.count,
                    "added": added,
                    "removed": removed,
                    "succeeded": succeeded.count,
                    "failed": failed.count,
                    "failed_documents": failed.map { ["id": $0.id, "error": $0.error ?? ""] },
                ],
                isError: !failed.isEmpty
            )
        }
    ),
]

/// One document's outcome from a write tool's per-document loop: `nil` error means every
/// step attempted for it completed; otherwise the message is what that step's own error
/// says, so a caller can see exactly why without a second call.
private struct WriteOutcome: Sendable {
    let id: String
    let error: String?
}

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
