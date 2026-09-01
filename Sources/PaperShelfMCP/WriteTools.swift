import Foundation
import PaperShelfCore

/// The tools that change something. Everything else in this server reads.
///
/// Two kinds of change, kept apart on purpose. `add_to_project` and `set_tags`, above,
/// write rows in the library: reversible, invisible on disk, and no PDF is touched.
/// `propose_file_changes`, below, only ever works out what a rename would do and never
/// touches a file, so it works whether or not the file-operations preference is on;
/// `apply_file_changes`, which is the only one of the four that moves anything, is gated
/// behind that preference and off until somebody turns it on.
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
            + "are; the result names which succeeded and which did not. \"filed\" always "
            + "reflects actual project membership, so a document can appear both filed and "
            + "failed: it can be filed before a later step, like setting its section or "
            + "attaching its note, fails for it.",
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
            //
            // The "after" side of that diff is read again below, once every document has
            // been attempted, rather than derived from which documents' per-document loop
            // reported success: `addMember` auto-commits the instant it runs, independent
            // of whatever `setSection` or `addNote` does afterward for the same document,
            // so a document whose later step throws can still have left a genuine row in
            // `project_members`. Counting only the documents that reported success would
            // silently drop that document from `filed`, even though the database disagrees.
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
                        collected.append(WriteOutcome(id: id, error: readableMessage(for: error)))
                    }
                }
                return collected
            }

            let succeededIDs = outcomes.filter { $0.error == nil }.map(\.id)
            let failed = outcomes.filter { $0.error != nil }

            // The "after" membership, read fresh from the database rather than assembled
            // from `succeededIDs`: see the comment above `alreadyMember`. `filed` is which
            // of the named documents are members now that were not members before, in
            // full, regardless of what each document's own outcome says.
            let nowMember = Set(try reader.documents(inProject: projectID, limit: Int.max).map { $0.0.id })
            let filedIDs = ids.filter { nowMember.contains($0) && !alreadyMember.contains($0) }
            let filed = filedIDs.count
            let alreadyThere = ids.filter { alreadyMember.contains($0) }.count

            // A document can be both a reported failure and one of `filedIDs`: `addMember`
            // committed before `setSection` or `addNote` threw for it. That is exactly the
            // case this fix exists for, so it is named in the response rather than left for
            // a caller to notice that `filed` and `succeeded` do not add up on their own.
            let failedButFiled = failed.filter { filedIDs.contains($0.id) }
            let outrightFailed = failed.filter { !filedIDs.contains($0.id) }

            var text = "Filed \(filed) new document\(filed == 1 ? "" : "s") into \(projectName)"
            if alreadyThere > 0 {
                text += " (\(alreadyThere) already there)"
            }
            if created { text += ", which is new" }
            text += "."
            if !outrightFailed.isEmpty {
                text += " \(outrightFailed.count) document\(outrightFailed.count == 1 ? "" : "s") could not "
                    + "be filed: \(outrightFailed.map(\.id).joined(separator: ", "))."
            }
            if !failedButFiled.isEmpty {
                text += " \(failedButFiled.count) document\(failedButFiled.count == 1 ? "" : "s") "
                    + "\(failedButFiled.count == 1 ? "was" : "were") filed, but a later step "
                    + "failed for \(failedButFiled.count == 1 ? "it" : "them"): "
                    + "\(failedButFiled.map(\.id).joined(separator: ", "))."
            }

            return ToolOutput(
                text: text,
                structured: [
                    "project": ["id": Int(projectID), "name": projectName],
                    "created": created,
                    "filed": filed,
                    "succeeded": succeededIDs.count,
                    "succeeded_documents": succeededIDs,
                    "failed": failed.count,
                    "failed_documents": failed.map { ["id": $0.id, "error": $0.error ?? ""] },
                    "filed_despite_error": failedButFiled.map(\.id),
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
                        collected.append(WriteOutcome(id: id, error: readableMessage(for: error)))
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
                    "succeeded_documents": succeeded,
                    "failed": failed.count,
                    "failed_documents": failed.map { ["id": $0.id, "error": $0.error ?? ""] },
                ],
                isError: !failed.isEmpty
            )
        }
    ),

    Tool(
        name: "propose_file_changes",
        title: "Work out what renaming a folder would do",
        description: "The renames PaperShelf's own naming rules would make in a folder, "
            + "worked out without touching a single file. Comes back with a token. Show "
            + "the researcher the list and, if they say yes, pass the token to "
            + "apply_file_changes. The token stops being good after fifteen minutes. A "
            + "file that is locked, but that PaperShelf already has a working password "
            + "for, is decrypted rather than simply renamed if applied; the result marks "
            + "which files that applies to and what becomes of the original under the "
            + "app's current backup setting.",
        inputSchema: [
            "type": "object",
            "properties": [
                "folder": ["type": "string", "description": "Absolute path."],
                "recursive": ["type": "boolean", "description": "Include subfolders. Default true."],
                "casing": ["type": "string", "enum": NameRules.Casing.allCases.map(\.rawValue)],
                "separator": ["type": "string", "enum": NameRules.Separator.allCases.map(\.rawValue)],
                "strip_symbols": ["type": "boolean"],
                "strip_diacritics": ["type": "boolean"],
                "ascii_only": ["type": "boolean"],
                "drop_leading_articles": ["type": "boolean"],
                "max_length": ["type": "integer", "description": "Cut names back to this. Zero leaves them."],
                "date_position": ["type": "string", "enum": NameRules.DatePosition.allCases.map(\.rawValue)],
                "date_format": ["type": "string", "enum": NameRules.DateFormat.allCases.map(\.rawValue)],
            ],
            "required": ["folder"],
        ],
        run: { arguments in
            let rules = NameRules(
                casing: (arguments["casing"] as? String).flatMap(NameRules.Casing.init(rawValue:)) ?? .lowercase,
                separator: (arguments["separator"] as? String).flatMap(NameRules.Separator.init(rawValue:)) ?? .keep,
                stripSymbols: optionalBool(arguments, "strip_symbols", default: false),
                stripDiacritics: optionalBool(arguments, "strip_diacritics", default: false),
                asciiOnly: optionalBool(arguments, "ascii_only", default: false),
                dropLeadingArticles: optionalBool(arguments, "drop_leading_articles", default: false),
                maxLength: arguments["max_length"] as? Int ?? 0,
                datePosition: (arguments["date_position"] as? String).flatMap(NameRules.DatePosition.init(rawValue:)) ?? .prefix,
                dateFormat: (arguments["date_format"] as? String).flatMap(NameRules.DateFormat.init(rawValue:)) ?? .dashed)

            let plan = try buildPlan(folder: try requireString(arguments, "folder"),
                                     recursive: optionalBool(arguments, "recursive", default: true),
                                     rules: rules)
            _ = try writePlan(plan)

            // A move whose status is `.decrypted` is not an ordinary rename: `process`
            // rewrites the document through PDFKit rather than moving its bytes untouched,
            // because a saved password now opens it. A researcher approving "rename these"
            // has to be told "decrypt this one" as its own fact, not left to discover it
            // after the fact, and told separately what becomes of the original, since that
            // depends on a setting (`apply_file_changes` honours whatever this plan's own
            // backup settings say, not whatever they are changed to later).
            let originalFate = plan.backupEnabled
                ? "the original is kept "
                    + (plan.backupCustomPath.map { "at \($0)" }
                        ?? "in a \"\(plan.backupFolderName)\" folder alongside it") + "."
                : "the original is overwritten and is not recoverable from the Trash."
            var text = plan.moves.isEmpty
                ? "Nothing in that folder would be renamed."
                : plan.moves.map { move -> String in
                    var line = (move.from as NSString).lastPathComponent + "\n    -> "
                        + (move.to as NSString).lastPathComponent
                    if move.status == .decrypted {
                        line += "\n    this file is locked, and PaperShelf has a password "
                            + "for it: applying this plan decrypts it, rewriting the "
                            + "document rather than only renaming it, and \(originalFate)"
                    }
                    return line
                }.joined(separator: "\n")
            if !Prefs.fileOperationsEnabled {
                text += "\n\nNothing can be applied: PaperShelf has file operations turned "
                    + "off. Settings, Integrations, \"Let it rename and move files\"."
            }
            return ToolOutput(text: text,
                              structured: ["token": plan.token,
                                           "count": plan.moves.count,
                                           "enabled": Prefs.fileOperationsEnabled,
                                           "moves": plan.moves.map { ["from": $0.from, "to": $0.to,
                                                                      "decrypts": $0.status == .decrypted] }])
        }
    ),

    Tool(
        name: "apply_file_changes",
        title: "Carry out a proposed rename",
        description: "Carries out the renames a propose_file_changes token stands for. "
            + "Only after the researcher has seen the list and agreed. Refuses if "
            + "PaperShelf has file operations turned off, if the token is unknown or more "
            + "than fifteen minutes old, or if any file in the plan has moved, changed, "
            + "or would now be decrypted rather than simply renamed since the plan was "
            + "proposed. An ordinary rename never loses data: the bytes carry over under "
            + "the new name whether or not backup is on. A file that has to be decrypted "
            + "to be renamed is rewritten instead of moved; with backup on, the original "
            + "locked file is kept in the backup folder, and with backup off it is "
            + "replaced and its original bytes are not recoverable. propose_file_changes "
            + "states which files that applies to before anything here is approved.",
        inputSchema: [
            "type": "object",
            "properties": [
                "token": ["type": "string", "description": "From propose_file_changes."],
            ],
            "required": ["token"],
        ],
        run: { arguments in
            // The gate, checked first and before the token is even looked up: the
            // cheapest and most absolute of every reason this can refuse.
            guard Prefs.fileOperationsEnabled else {
                throw ToolFailure("PaperShelf has file operations turned off, so nothing "
                    + "here can move a file. The setting is in Settings, Integrations, "
                    + "\"Let it rename and move files\". Nothing has been moved.")
            }
            let plan = try readPlan(token: try requireString(arguments, "token"))
            guard !plan.moves.isEmpty else {
                // Removed here too, not just on the paths below that actually move
                // something: leaving it would make an empty plan's token replayable
                // (harmlessly, since replaying it only ever reproduces "renames nothing")
                // until it expires on its own, which is an unstated exception to every
                // other path through this tool removing the plan file it read.
                try? FileManager.default.removeItem(at: try planURL(token: plan.token))
                return ToolOutput(text: "That plan renames nothing.",
                                  structured: ["applied": 0])
            }
            try verify(plan)

            // Worked out a second time and compared before anything is written. The plan
            // records what the rules said when it was proposed; if a folder's contents
            // have shifted enough that the same rules now produce different names,
            // applying the old list would rename files to names nobody was shown. Status
            // is compared alongside the two names, not just the names themselves: a
            // locked file's destination name does not depend on whether it can be
            // decrypted (`apply_file_changes` never asks `process` to fall back to a
            // PDF's metadata date), so a password added to, or removed from, the app's
            // saved list between the proposal and this call would otherwise change what
            // this move actually does (rename, versus decrypt-and-rewrite) without
            // changing either name this comparison used to look at.
            let planned = Set(plan.moves.map { "\($0.from)\u{1F}\($0.to)\u{1F}\($0.status.rawValue)" })
            let sources = Set(plan.moves.map(\.from))
            // `backup: plan.backup`, not `Prefs.backup`: the same "honour what the plan
            // recorded, not what the preference says now" rule the apply step below
            // follows, so the scan skips wherever this plan's own backup settings put
            // originals rather than wherever the current preference happens to point.
            let jobs = collectJobs(roots: [URL(fileURLWithPath: plan.folder)],
                                   recursive: plan.recursive, backup: plan.backup)
                .filter { sources.contains($0.file.path) }
            let rehearsed = process(jobs: jobs, options: plan.options)
            let now = Set(rehearsed.filter(\.isRenamed)
                .map { "\($0.source.path)\u{1F}\($0.destination.path)\u{1F}\($0.status.rawValue)" })
            guard now == planned else {
                throw ToolFailure("the same rules now produce different names, or would "
                    + "now change a file's encryption, than this plan records. Nothing "
                    + "has been moved. Call propose_file_changes again to see what would "
                    + "happen now.")
            }

            var options = plan.options
            options.dryRun = false
            let done = process(jobs: jobs, options: options)
            let moved = done.filter(\.carriedOut)
            let failed = done.filter { $0.status == .failed }
            // `process` only ever touches files; recording what actually moved is this
            // caller's job, the same as the app's own run loop (see `recordMoves`).
            recordMoves(moved)
            try? FileManager.default.removeItem(at: try planURL(token: plan.token))

            // Precise about which files actually moved and which did not, rather than a
            // bare count: after a partial failure, a researcher needs to know the folder's
            // real state without opening Finder to check. Each failed file's own message,
            // from `process`, already says exactly what state that file was left in
            // (untouched, restored, or written but not cleaned up), so it is carried
            // through rather than replaced with a generic line.
            var lines = ["Renamed \(moved.count) of \(plan.moves.count)."]
            lines += moved.map { "  \($0.source.lastPathComponent) -> \($0.destination.lastPathComponent)" }
            lines += failed.map { "  \($0.source.lastPathComponent): \($0.message)" }

            return ToolOutput(
                text: lines.joined(separator: "\n"),
                structured: ["applied": moved.count,
                             "failed": failed.count,
                             "moves": moved.map { ["from": $0.source.path,
                                                   "to": $0.destination.path] },
                             "failed_files": failed.map { ["from": $0.source.path,
                                                           "message": $0.message] }],
                isError: !failed.isEmpty)
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

/// A sentence a researcher can read, for whatever a write step throws.
///
/// `LibraryError` already reads as one, since it conforms to `CustomStringConvertible`, and
/// `ToolFailure`'s own `message` already is one; both are named explicitly rather than
/// through `error as? CustomStringConvertible`, which Foundation's `NSError` bridging makes
/// the compiler treat as unconditionally true for any `Error` (a warning on its own, and
/// not a reliable way to tell "this type actually wrote a description" from "this is a
/// plain struct with no description of its own"). `String(describing:)` is the fallback for
/// anything else, which is what the two write tools' errors were limited to before this:
/// a case or struct dump rather than a sentence.
///
/// Not `private`: `Server.swift`'s own top-level catch, around every tool's `run`, used
/// `error.localizedDescription` for exactly the same reason this existed for the two write
/// tools, and `LibraryError` conforms to neither `LocalizedError` nor `CustomNSError`, so
/// that produced Foundation's generic "The operation couldn't be completed." there instead
/// of the real message. Internal visibility (the default once `private` is dropped) is
/// enough for `Server.swift`, in the same module, to call this instead of repeating it.
func readableMessage(for error: Error) -> String {
    if let toolFailure = error as? ToolFailure { return toolFailure.message }
    if let libraryError = error as? LibraryError { return libraryError.description }
    return String(describing: error)
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
