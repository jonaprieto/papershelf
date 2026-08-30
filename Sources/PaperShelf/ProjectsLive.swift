import SwiftUI
import AppKit
import PaperShelfCore

/// The reading-project views against the real library and the real model.
///
/// `ProjectsEnvironment` is a bag of closures rather than a protocol so the views can be
/// driven by a stub in a test without a database or a network. This is the one place that
/// fills it in for real.
@MainActor
func liveProjectsEnvironment(library: Library, client: AIClient,
                             endpoint: String, model: String = "",
                             passwords: @escaping () -> [String] = { [] }) -> ProjectsEnvironment {
    // The library's own document id, not a hash of the bytes: this app rewrites PDFs, so
    // the bytes change and the id does not. The field is named contentHash for historical
    // reasons; what travels through it is whatever identity the store uses.
    func document(_ record: DocumentRecord, markdown: String = "") -> ProjectDocument {
        ProjectDocument(contentHash: record.id,
                        title: record.title ?? "untitled",
                        markdown: markdown)
    }
    func member(_ record: DocumentRecord, section: String?, markdown: String = "") -> ProjectMember {
        ProjectMember(document: document(record, markdown: markdown),
                     author: record.author, pageCount: record.pageCount, section: section)
    }

    return ProjectsEnvironment(
        listProjects: {
            let projects = try await library.projects()
            let counts = try await library.projectMemberCounts()
            var summaries: [ProjectSummary] = []
            for project in projects {
                summaries.append(ProjectSummary(id: project.id, name: project.name,
                                                documentCount: counts[project.id] ?? 0))
            }
            return summaries
        },
        createProject: { name in
            let project = try await library.createProject(name: name)
            return ProjectSummary(id: project.id, name: project.name, documentCount: 0)
        },
        deleteProject: { id in try await library.deleteProject(id: id) },
        members: { id in
            let rows = try await library.sectionedMembers(ofProject: id)
            // The text is what a question is answered from, so it travels with the
            // document. A document with none contributes nothing but its title. Asked for
            // the whole project at once: one question per document meant a project of a
            // thousand papers waited on a thousand round trips before it could be drawn.
            let text = try await library.extractedText(forDocuments: rows.map { $0.0.id })
            return rows.map { record, section in
                member(record, section: section, markdown: text[record.id] ?? "")
            }
        },
        availableDocuments: { id in
            let already = Set(try await library.members(ofProject: id).map(\.id))
            return try await library.documents()
                .filter { !already.contains($0.id) }
                .map { member($0, section: nil) }
        },
        readDocuments: { documentIDs in
            // The paths come from the library rather than from the view: a document is
            // wherever it was last seen, which after a run is not where it was scanned.
            var work: [(id: String, url: URL)] = []
            for id in documentIDs {
                guard let path = try await library.locations(forDocument: id).last?.path else { continue }
                work.append((id, URL(fileURLWithPath: path)))
            }
            guard !work.isEmpty else { return 0 }
            let read = await readTextForProject(work, passwords: passwords())
            guard !read.isEmpty else { return 0 }
            try await library.setExtractedText(read)
            return read.count
        },
        sections: { id in try await library.sections(ofProject: id) },
        setSection: { id, documentID, section in
            try await library.setSection(section, forDocument: documentID, inProject: id)
        },
        removeMember: { id, documentID in
            try await library.removeMember(documentID, fromProject: id)
        },
        addFiles: { id, paths in try await addToProject(paths, project: id, library: library) },
        tags: { documentIDs in
            // One query for the whole project. The library can hand back every document's
            // tags in a single statement, and asking per document is what made opening a
            // large project wait on a round trip per row.
            let wanted = Set(documentIDs)
            return try await library.tagsByDocument().filter { wanted.contains($0.key) }
        },
        addTag: { documentID, name in try await library.addTag(name, toDocument: documentID) },
        removeTag: { documentID, name in
            try await library.removeTag(name, fromDocument: documentID)
        },
        rankedDocuments: { question, documentIDs in
            // The store's own index decides what is relevant, rather than a second search
            // written for this one screen. Anything the index does not rank still follows,
            // so a project with no extracted text is not silently empty.
            let wanted = Set(documentIDs)
            let ranked = try await library.fullTextSearch(question, limit: 100)
                .map(\.id)
                .filter { wanted.contains($0) }
            return ranked + documentIDs.filter { !ranked.contains($0) }
        },
        ask: { system, user in
            try await client.ask(system: system, user: user, feature: .readingProject)
        },
        endpoint: { endpoint },
        model: { model },
        openAtPage: { documentID, page in
            Task {
                guard let places = try? await library.locations(forDocument: documentID),
                      let latest = places.max(by: { $0.lastSeenAt < $1.lastSeenAt })
                else { return }
                let url = URL(fileURLWithPath: latest.path)
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                // Page numbers are 1-based everywhere in this app. Preview understands
                // this fragment; a viewer that does not simply opens at the first page.
                let atPage = URL(string: url.absoluteString + "#page=\(page)") ?? url
                NSWorkspace.shared.open(atPage)
            }
        }
    )
}

/// Reads several documents' text off the main thread, the same way the shelf's own
/// indexer does. A file that cannot be opened at all is left out rather than stored as
/// empty, since empty means "opened, and has no text layer", which is a permanent answer.
func readTextForProject(_ work: [(id: String, url: URL)],
                        passwords: [String]) async -> [(documentID: String, markdown: String)] {
    await Task.detached(priority: .userInitiated) {
        var stored: [(documentID: String, markdown: String)] = []
        for job in work {
            guard let text = documentText(of: job.url, passwords: passwords) else { continue }
            stored.append((documentID: job.id, markdown: text))
        }
        return stored
    }.value
}
