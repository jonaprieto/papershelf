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
                             endpoint: String, model: String = "") -> ProjectsEnvironment {
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
            var out: [ProjectMember] = []
            for (record, section) in try await library.sectionedMembers(ofProject: id) {
                // The text is what a question is answered from, so it travels with the
                // document. A document with none contributes nothing but its title.
                let text = try await library.extractedText(forDocument: record.id)?.markdown ?? ""
                out.append(member(record, section: section, markdown: text))
            }
            return out
        },
        availableDocuments: { id in
            let already = Set(try await library.members(ofProject: id).map(\.id))
            return try await library.documents()
                .filter { !already.contains($0.id) }
                .map { member($0, section: nil) }
        },
        sections: { id in try await library.sections(ofProject: id) },
        setSection: { id, documentID, section in
            try await library.setSection(section, forDocument: documentID, inProject: id)
        },
        removeMember: { id, documentID in
            try await library.removeMember(documentID, fromProject: id)
        },
        addFiles: { id, paths in try await library.addMembers(paths: paths, toProject: id) },
        tags: { documentID in try await library.tags(forDocument: documentID).map(\.name) },
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
