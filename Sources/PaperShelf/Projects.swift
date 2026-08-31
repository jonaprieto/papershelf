import SwiftUI
import PaperShelfCore

// MARK: - Display types
//
// Library.swift (this round's SQLite store, built in parallel) owns the real project and
// document records. These are the app's own thin projections of them for display, not a
// second storage model: a `ProjectSummary` is just what a list row needs to draw itself.

struct ProjectSummary: Identifiable, Hashable {
    let id: Int64
    var name: String
    var documentCount: Int
}

/// A document as this feature shows it: enough to recognise without opening it (title,
/// author, page count), the identity and extracted text `chunk`/`selectExcerpts` need once
/// it is part of a project's conversation, and, for a document already filed here, which
/// section it is under. A document offered to add and a document already added but filed
/// under nothing both carry `section == nil`; the two lists that hand these out
/// (`members` and `availableDocuments`) are what tell them apart, not this type.
struct ProjectMember: Identifiable, Hashable {
    let document: ProjectDocument
    var author: String?
    var pageCount: Int?
    var section: String?

    var id: String { document.contentHash }
}

/// One section's worth of a project's members, as `groupMembers` produces it and the
/// detail view renders it, one `Section` per group.
struct MemberGroup: Identifiable {
    let section: String?
    let members: [ProjectMember]
    var id: String { section ?? "" }
}

/// Groups members by section for the detail list: every named section that actually has a
/// member in it, in the order `knownSections` reports them (the library's own order,
/// already alphabetical), then the unfiled ones last, since "filed under nothing" is where
/// a project's inbox naturally sits. A member whose section is not among `knownSections` —
/// stale data, or a caller that only updated one of the two — still gets its own group,
/// appended after the known ones, rather than silently vanishing from the list.
func groupMembers(_ members: [ProjectMember], knownSections: [String]) -> [MemberGroup] {
    let present = Set(members.compactMap(\.section))
    let extra = present.subtracting(knownSections)
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    var groups = (knownSections.filter(present.contains) + extra).map { section in
        MemberGroup(section: section, members: members.filter { $0.section == section })
    }
    let unfiled = members.filter { $0.section == nil }
    if !unfiled.isEmpty { groups.append(MemberGroup(section: nil, members: unfiled)) }
    return groups
}

/// Whether a project can answer a question yet, which is three states rather than two.
///
/// A project holding nothing and a project holding documents nobody has read yet both
/// leave the Ask button disabled, and telling a person "none of these documents has text"
/// when there are no documents at all points them at the wrong problem: one is waiting to
/// be filled, the other is waiting to be indexed.
enum AskReadiness: Equatable {
    case noDocuments
    case noText
    case ready
}

func askReadiness(of documents: [ProjectDocument]) -> AskReadiness {
    if documents.isEmpty { return .noDocuments }
    return documents.contains { !$0.markdown.isEmpty } ? .ready : .noText
}

/// What a row shows below the title to tell two documents apart at a glance: the author,
/// then how long it is, skipping whichever piece the library does not have.
func recognitionDetail(author: String?, pageCount: Int?) -> String? {
    var parts: [String] = []
    if let author, !author.isEmpty { parts.append(author) }
    if let pageCount { parts.append("\(pageCount) page\(pageCount == 1 ? "" : "s")") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

// MARK: - Environment
//
/// Everything the projects UI needs from storage and from the model, injected as plain
/// functions rather than a concrete type, the same shape AI.swift's `AIClient` and the
/// rest of this app's network calls already take. `ProjectsLive.swift` fills this in
/// against the real `Library`; a test hands in whatever it needs instead of standing up a
/// database.
struct ProjectsEnvironment {
    var listProjects: () async throws -> [ProjectSummary]
    var createProject: (_ name: String) async throws -> ProjectSummary
    var deleteProject: (_ id: Int64) async throws -> Void
    /// A project's documents, each with the section (if any) it is filed under.
    var members: (_ id: Int64) async throws -> [ProjectMember]
    /// The rest of the library, so a project can offer something to add. Never carries a
    /// section: nothing returned here is filed anywhere yet.
    var availableDocuments: (_ id: Int64) async throws -> [ProjectMember]
    /// The section names already in use in this project, so adding or moving a document
    /// offers them rather than making someone retype one they already invented.
    /// Reads the text of documents that have none yet, and answers how many gained some.
    ///
    /// A project can be filled with PDFs nobody has read, and until they are read there is
    /// nothing to ask across. The only way to read them was to index the whole shelf from
    /// the catalogue, which for one dropped paper is a walk over every file the app knows
    /// about. This reads exactly the documents named.
    var readDocuments: (_ contentHashes: [String]) async throws -> Int = { _ in 0 }
    var sections: (_ id: Int64) async throws -> [String]
    /// Files a document under a section, adding it to the project first if it is not a
    /// member yet. `nil` means filed under nothing — a real, common state, not "not added"
    /// — matching `Library.setSection`. This is the one path both adding documents and
    /// moving one already in the project go through.
    var setSection: (_ id: Int64, _ contentHash: String, _ section: String?) async throws -> Void
    var removeMember: (_ id: Int64, _ contentHash: String) async throws -> Void
    /// Adds documents by file path, which is what a drag carries. Returns how many of the
    /// paths were documents this library knows; the rest are skipped. Defaults to doing
    /// nothing so a stub environment only has to fill in what it is testing.
    var addFiles: (_ id: Int64, _ paths: [String]) async throws -> Int = { _, _ in 0 }
    /// The tags on a set of documents, asked once for the whole set. It used to be one
    /// question per document, which on a project of a thousand papers was a thousand round
    /// trips through the library actor before the list could be drawn.
    var tags: (_ contentHashes: [String]) async throws -> [String: [String]]
    var addTag: (_ contentHash: String, _ name: String) async throws -> Void
    var removeTag: (_ contentHash: String, _ tag: String) async throws -> Void
    /// Backed by `Library.fullTextSearch`: which of the given documents best match a
    /// question, best first. See `selectExcerpts` in PaperShelfCore for why this matters.
    var rankedDocuments: (_ question: String, _ contentHashes: [String]) async throws -> [String]
    /// A free-text system/user exchange with the configured model. `AIClient.identify`
    /// is shaped for a parsed `BookGuess` and cannot be reused as-is; this needs the raw
    /// reply text so citations can be parsed back out of it.
    var ask: (_ system: String, _ user: String) async throws -> String
    /// The endpoint currently configured, by name, for the privacy preview to show.
    var endpoint: () -> String
    /// The model a question would be answered by, named in the same line as the endpoint:
    /// what is sent and who answers it are one fact, not two.
    var model: () -> String = { "" }
    var openAtPage: (_ contentHash: String, _ page: Int) -> Void
    /// Where a document is on disk, and the passwords that open it. What a citation needs
    /// to be shown in this window rather than handed to another application.
    var locate: (_ contentHash: String) async -> URL? = { _ in nil }
    var passwords: () -> [String] = { [] }
}

// MARK: - Projects list

@MainActor
@Observable
final class ProjectsStore {
    private(set) var projects: [ProjectSummary] = []
    private(set) var isLoading = false
    var error: String?

    private let env: ProjectsEnvironment

    init(env: ProjectsEnvironment) {
        self.env = env
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            projects = try await env.listProjects()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func create(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            projects.append(try await env.createProject(trimmed))
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete(_ project: ProjectSummary) async {
        do {
            try await env.deleteProject(project.id)
            projects.removeAll { $0.id == project.id }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ProjectsListView: View {
    @State private var store: ProjectsStore
    @State private var showingNewProject = false
    @State private var newProjectName = ""
    /// The projects a swipe or the Delete key just asked to remove, held until the
    /// confirmation below decides. `Library.deleteProject` is a hard SQL delete of the
    /// project and every membership row with no undo anywhere in the app, so this dialog
    /// is the only path to it.
    @State private var projectsPendingDeletion: [ProjectSummary]?
    private let env: ProjectsEnvironment

    init(env: ProjectsEnvironment) {
        self.env = env
        _store = State(wrappedValue: ProjectsStore(env: env))
    }

    var body: some View {
        List {
            if store.projects.isEmpty && !store.isLoading {
                Text("No reading projects yet.").foregroundStyle(.secondary)
            }
            ForEach(store.projects) { project in
                NavigationLink(value: project) {
                    VStack(alignment: .leading, spacing: Space.hair) {
                        Text(project.name).font(Face.headline)
                        Text("\(project.documentCount) document\(project.documentCount == 1 ? "" : "s")")
                            .font(Face.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { indexSet in
                projectsPendingDeletion = indexSet.map { store.projects[$0] }
            }
        }
        .navigationTitle("Reading Projects")
        .navigationDestination(for: ProjectSummary.self) { project in
            ProjectDetailView(project: project, env: env)
        }
        .toolbar {
            Button {
                showingNewProject = true
            } label: {
                Label("New Project", systemImage: "plus")
            }
            .tip("A named subset of your library you can ask questions across")
        }
        .sheet(isPresented: $showingNewProject) {
            NewProjectSheet(name: $newProjectName) { name in
                Task {
                    await store.create(name: name)
                    newProjectName = ""
                    showingNewProject = false
                }
            }
        }
        .task { await store.load() }
        .alert("Something went wrong", isPresented: errorShown(for: store)) {
            Button("OK") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: Binding(
                get: { projectsPendingDeletion != nil },
                set: { if !$0 { projectsPendingDeletion = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                let projects = projectsPendingDeletion ?? []
                projectsPendingDeletion = nil
                for project in projects { Task { await store.delete(project) } }
            }
            Button("Cancel", role: .cancel) { projectsPendingDeletion = nil }
        } message: {
            Text("The documents stay on disk; the project and its sections are gone.")
        }
    }

    private var deleteConfirmationTitle: String {
        guard let projectsPendingDeletion, let first = projectsPendingDeletion.first else { return "" }
        return projectsPendingDeletion.count == 1
            ? "Delete \"\(first.name)\"?"
            : "Delete \(projectsPendingDeletion.count) projects?"
    }
}

private struct NewProjectSheet: View {
    @Binding var name: String
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Space.roomy) {
            Text("New Reading Project").font(Face.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onCreate(name) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") { onCreate(name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 320)
    }
}

// MARK: - Project detail: sections, members and tags

@MainActor
@Observable
final class ProjectDetailModel {
    let project: ProjectSummary
    private(set) var members: [ProjectMember] = []
    private(set) var tagsByDocument: [String: [String]] = [:]
    private(set) var available: [ProjectMember] = []
    private(set) var knownSections: [String] = []
    private(set) var isLoading = false
    /// True while the members with no text are being read, so the button that started it
    /// says so rather than looking like it did nothing.
    private(set) var isReading = false
    var error: String?

    private let env: ProjectsEnvironment
    /// Told whenever this project gains or loses a document. The sidebar draws its own
    /// count of every project from a separate query, taken when the window loaded it, so
    /// without this a document added or removed here left that count saying what used to
    /// be true: a project reading "1" beside a workspace showing none.
    private let membershipChanged: () -> Void

    init(project: ProjectSummary, env: ProjectsEnvironment,
         membershipChanged: @escaping () -> Void = {}) {
        self.project = project
        self.env = env
        self.membershipChanged = membershipChanged
    }

    /// Members grouped by section for the detail list. See `groupMembers`.
    var groupedMembers: [MemberGroup] { groupMembers(members, knownSections: knownSections) }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let documents = try await env.members(project.id)
            members = documents
            knownSections = try await env.sections(project.id)
            // Every member gets an entry, tagged or not: the views read this dictionary
            // directly, and "no tags" is an answer, not a missing one.
            let ids = documents.map(\.document.contentHash)
            let found = try await env.tags(ids)
            tagsByDocument = ids.reduce(into: [:]) { $0[$1] = found[$1] ?? [] }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Reads the text of every member that has none, so a project of freshly dropped PDFs
    /// can answer a question without indexing the whole shelf from the catalogue.
    func readUnindexed() async {
        let waiting = members.filter { $0.document.markdown.isEmpty }.map(\.document.contentHash)
        guard !waiting.isEmpty else { return }
        isReading = true
        defer { isReading = false }
        do {
            guard try await env.readDocuments(waiting) > 0 else { return }
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadAvailable() async {
        do {
            available = try await env.availableDocuments(project.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Files every document in `hashes` under `section` (`nil` files it under nothing) and
    /// reloads. A fresh `load()` is simpler, and no less correct, than patching extracted
    /// text into each new member by hand, and it is the only path here that can introduce
    /// a section nobody has filed anything under yet.
    func addBatch(_ hashes: Set<String>, section: String?) async {
        guard !hashes.isEmpty else { return }
        do {
            for hash in hashes {
                try await env.setSection(project.id, hash, section)
            }
            available.removeAll { hashes.contains($0.document.contentHash) }
            await load()
            membershipChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// PDFs dropped on the project, from the sidebar, the shelf, the list or Finder. A
    /// file the library has not met yet is indexed on the way in (see `addToProject`), so
    /// a drop files what was dropped rather than quietly doing nothing.
    func addFiles(_ paths: [String]) async {
        do {
            guard try await env.addFiles(project.id, paths) > 0 else { return }
            await load()
            membershipChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func remove(_ member: ProjectMember) async {
        do {
            try await env.removeMember(project.id, member.document.contentHash)
            members.removeAll { $0.id == member.id }
            knownSections = try await env.sections(project.id)
            membershipChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Refiles a document already in the project. `section` nil files it under nothing;
    /// it does not remove it. Only `section` changes locally — the document's own text and
    /// metadata did not, so there is nothing here worth a full reload for.
    func move(_ member: ProjectMember, to section: String?) async {
        do {
            try await env.setSection(project.id, member.document.contentHash, section)
            if let index = members.firstIndex(where: { $0.id == member.id }) {
                members[index].section = section
            }
            knownSections = try await env.sections(project.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func addTag(_ name: String, to member: ProjectMember) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !(tagsByDocument[member.document.contentHash] ?? []).contains(trimmed) else { return }
        do {
            try await env.addTag(member.document.contentHash, trimmed)
            tagsByDocument[member.document.contentHash, default: []].append(trimmed)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func removeTag(_ name: String, from member: ProjectMember) async {
        do {
            try await env.removeTag(member.document.contentHash, name)
            tagsByDocument[member.document.contentHash]?.removeAll { $0 == name }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ProjectDetailView: View {
    @State private var model: ProjectDetailModel
    @State private var showingAddDocuments = false
    @State private var tagDrafts: [String: String] = [:]
    @State private var sectionPromptTarget: ProjectMember?
    @State private var newSectionName = ""
    private let env: ProjectsEnvironment

    init(project: ProjectSummary, env: ProjectsEnvironment) {
        self.env = env
        _model = State(wrappedValue: ProjectDetailModel(project: project, env: env))
    }

    var body: some View {
        List {
            if model.members.isEmpty {
                Section("Documents") {
                    Text("No documents yet.").foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.groupedMembers) { group in
                    Section(sectionTitle(group)) {
                        ForEach(group.members) { member in
                            memberRow(member)
                        }
                    }
                }
            }
        }
        .navigationTitle(model.project.name)
        .toolbar {
            NavigationLink {
                ProjectConversationView(documents: model.members.map(\.document),
                                        model: ProjectConversationModel(project: model.project,
                                                                        env: env))
            } label: {
                Label("Ask", systemImage: "bubble.left.and.bubble.right")
            }
            .tip("Ask a question across every document in this project")
            .disabled(model.members.isEmpty)

            Button {
                showingAddDocuments = true
                Task { await model.loadAvailable() }
            } label: {
                Label("Add Documents", systemImage: "doc.badge.plus")
            }
            .tip("Add documents from your library, several at once, filed under a section")
        }
        .sheet(isPresented: $showingAddDocuments) {
            AddDocumentsSheet(candidates: model.available, knownSections: model.knownSections) { hashes, section in
                Task { await model.addBatch(hashes, section: section) }
            }
        }
        .task { await model.load() }
        .alert("Something went wrong", isPresented: errorShown(for: model)) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        .alert("New Section", isPresented: sectionPromptShown) {
            TextField("Section name", text: $newSectionName)
            Button("Cancel", role: .cancel) { cancelSectionPrompt() }
            Button("Move") { confirmSectionPrompt() }
                .disabled(newSectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("File \"\(sectionPromptTarget?.document.title ?? "")\" under a new section.")
        }
    }

    private func sectionTitle(_ group: MemberGroup) -> String {
        "\(group.section ?? "No Section") (\(group.members.count))"
    }

    @ViewBuilder
    private func memberRow(_ member: ProjectMember) -> some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Space.hair) {
                    Text(member.document.title)
                    if let detail = recognitionDetail(author: member.author, pageCount: member.pageCount) {
                        Text(detail)
                            .font(Face.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    env.openAtPage(member.document.contentHash, 1)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .tip("Open this document")

                Menu {
                    ForEach(model.knownSections.filter { $0 != member.section }, id: \.self) { section in
                        Button(section) { Task { await model.move(member, to: section) } }
                    }
                    if member.section != nil {
                        Button("No Section") { Task { await model.move(member, to: nil) } }
                    }
                    Divider()
                    Button("New Section…") { sectionPromptTarget = member }
                } label: {
                    Image(systemName: "folder")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .tip("Move to a different section")

                Button(role: .destructive) {
                    Task { await model.remove(member) }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .tip("Remove from this project, not from the library")
            }
            TagRow(
                tags: model.tagsByDocument[member.document.contentHash] ?? [],
                draft: Binding(
                    get: { tagDrafts[member.document.contentHash] ?? "" },
                    set: { tagDrafts[member.document.contentHash] = $0 }),
                onAdd: { name in
                    Task { await model.addTag(name, to: member) }
                    tagDrafts[member.document.contentHash] = ""
                },
                onRemove: { name in Task { await model.removeTag(name, from: member) } })
        }
    }

    private var sectionPromptShown: Binding<Bool> {
        Binding(get: { sectionPromptTarget != nil }, set: { if !$0 { cancelSectionPrompt() } })
    }

    private func cancelSectionPrompt() {
        sectionPromptTarget = nil
        newSectionName = ""
    }

    private func confirmSectionPrompt() {
        let trimmed = newSectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let target = sectionPromptTarget, !trimmed.isEmpty {
            Task { await model.move(target, to: trimmed) }
        }
        cancelSectionPrompt()
    }
}

private struct TagRow: View {
    let tags: [String]
    @Binding var draft: String
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void

    var body: some View {
        HStack(spacing: Space.snug) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(Face.caption)
                    .padding(.horizontal, Space.snug)
                    .padding(.vertical, Space.hair)
                    .background(Capsule().fill(.secondary.opacity(0.15)))
                    .onTapGesture { onRemove(tag) }
                    .help("Click to remove this tag")
            }
            TextField("Add tag", text: $draft)
                .textFieldStyle(.plain)
                .font(Face.caption)
                .frame(width: 90)
                .onSubmit { onAdd(draft) }
        }
    }
}

/// Choosing what to add, several documents at once, into one section chosen up front.
/// Reachable only from inside a project: adding from the catalogue itself, while a file is
/// still where it actually is, belongs to whichever screen owns that context menu, not
/// here.
struct AddDocumentsSheet: View {
    let candidates: [ProjectMember]
    let knownSections: [String]
    let onAdd: (_ hashes: Set<String>, _ section: String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: Set<String> = []
    @State private var section = ""

    private var filtered: [ProjectMember] {
        guard !query.isEmpty else { return candidates }
        return candidates.filter {
            $0.document.title.localizedCaseInsensitiveContains(query)
                || ($0.author?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.step) {
            Text("Add Documents").font(Face.headline)
            TextField("Search your library", text: $query)
                .textFieldStyle(.roundedBorder)
            if filtered.isEmpty {
                Text(candidates.isEmpty ? "Every document is already in this project."
                                        : "Nothing matches.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filtered) { member in
                    Button {
                        toggle(member)
                    } label: {
                        HStack(spacing: Space.step) {
                            Image(systemName: selected.contains(member.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(member.id) ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: Space.hair) {
                                Text(member.document.title)
                                if let detail = recognitionDetail(author: member.author, pageCount: member.pageCount) {
                                    Text(detail).font(Face.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
            if !knownSections.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.snug) {
                        ForEach(knownSections, id: \.self) { name in
                            Button(name) { section = name }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }
            TextField("Section (optional)", text: $section)
                .textFieldStyle(.roundedBorder)
                .tip("Leave blank to file these under nothing")
            HStack {
                if !selected.isEmpty {
                    Text("\(selected.count) selected").font(Face.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(addButtonTitle) {
                    let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
                    onAdd(selected, trimmed.isEmpty ? nil : trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding()
        .frame(width: 440, height: 440)
    }

    private var addButtonTitle: String {
        selected.isEmpty ? "Add" : "Add \(selected.count) Document\(selected.count == 1 ? "" : "s")"
    }

    private func toggle(_ member: ProjectMember) {
        if selected.contains(member.id) { selected.remove(member.id) } else { selected.insert(member.id) }
    }
}

// MARK: - Conversation: asking a project a question

/// One question and its answer, kept together with exactly what was sent, so the privacy
/// preview a question is confirmed against can be shown again later if asked.
struct ProjectTurn: Identifiable {
    let id = UUID()
    let question: String
    var excerpts: [Excerpt] = []
    var reply: String = ""
    var citations: [Citation] = []
    var isLoading = true
    var error: String?
}

@MainActor
@Observable
final class ProjectConversationModel {
    let project: ProjectSummary
    var pendingQuestion = ""
    private(set) var turns: [ProjectTurn] = []
    /// Non-nil the instant excerpts are chosen and a question is ready to send. The view
    /// turns this into a confirmation dialog every time, never a setting remembered from
    /// last time: the answer (how many documents, how many characters) is different for
    /// every question.
    private(set) var pendingPreview: OutboundPreview?
    var error: String?
    private(set) var isPreparing = false

    private let env: ProjectsEnvironment
    private var confirmedQuestion: String?
    private var confirmedExcerpts: [Excerpt] = []

    var endpointName: String { env.endpoint() }
    var modelName: String { env.model() }

    /// Every question and answer in this project, in the order they were asked. What the
    /// window's Export button writes out.
    var threadMarkdown: String {
        var out = "# \(project.name)\n"
        for turn in turns where !turn.isLoading && turn.error == nil {
            out += "\n## \(turn.question)\n\n\(turn.reply)\n"
            let sources = numberedCitations(turn.citations)
            guard !sources.isEmpty else { continue }
            out += "\nSources\n"
            for source in sources {
                out += "\n\(source.number). \(source.citation.documentTitle), "
                    + "p. \(source.citation.page)"
            }
            out += "\n"
        }
        return out
    }

    init(project: ProjectSummary, env: ProjectsEnvironment) {
        self.project = project
        self.env = env
    }

    /// Step 1: chooses excerpts and shows what would be sent. Nothing reaches the
    /// network yet; `confirmAndAsk()` is the only function here that calls `env.ask`.
    func prepareToAsk(documents: [ProjectDocument]) async {
        let question = pendingQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        // Nothing to quote from is nothing to ask. Without this, a project of documents
        // nobody has read yet still sent the question to the endpoint, which costs money
        // to have a model answer from its own memory and cite nothing, and contradicts
        // the line above the composer saying there is nothing to ask across. The button
        // is disabled for the same reason; this guards the path Return takes.
        guard askReadiness(of: documents) == .ready else { return }
        isPreparing = true
        defer { isPreparing = false }
        do {
            let excerpts = try await selectExcerpts(question: question, documents: documents) { text, hashes in
                try await self.env.rankedDocuments(text, hashes)
            }
            confirmedQuestion = question
            confirmedExcerpts = excerpts
            let preview = outboundPreview(excerpts: excerpts, endpoint: env.endpoint())
            // What is about to be sent is on screen above the composer the whole time it
            // is being typed, so the default endpoint no longer gets a dialog restating
            // it after the fact. An endpoint that is not the default, or one reached in
            // the clear, still does: that is a different promise, and it is the moment to
            // say so.
            guard preview.isDefaultEndpoint, !preview.isPlaintext else {
                pendingPreview = preview
                return
            }
            await confirmAndAsk()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func cancelPending() {
        pendingPreview = nil
        confirmedQuestion = nil
        confirmedExcerpts = []
    }

    /// Step 2: only reached after the confirmation dialog is accepted.
    func confirmAndAsk() async {
        guard let question = confirmedQuestion else { return }
        let excerpts = confirmedExcerpts
        pendingPreview = nil
        confirmedQuestion = nil
        confirmedExcerpts = []
        pendingQuestion = ""

        turns.append(ProjectTurn(question: question, excerpts: excerpts))
        let index = turns.count - 1

        do {
            let reply = try await env.ask(
                readingProjectInstruction,
                readingProjectPrompt(question: question, projectName: project.name, excerpts: excerpts))
            turns[index].reply = reply
            turns[index].citations = parseCitations(in: reply, excerpts: excerpts)
        } catch {
            turns[index].error = error.localizedDescription
        }
        turns[index].isLoading = false
    }

    func open(_ citation: Citation) {
        guard let hash = citation.contentHash else { return }
        env.openAtPage(hash, citation.page)
    }
}

struct ProjectConversationView: View {
    /// Held by whoever put this view on screen. The workspace's toolbar exports the
    /// thread, and it cannot export turns held privately by the view under it.
    ///
    /// `@Bindable`, because the field the question is typed into binds to
    /// `pendingQuestion`. The tracking that redraws the pane when an answer arrives comes
    /// from `@Observable` on the model itself, not from anything written here.
    @Bindable var model: ProjectConversationModel
    /// The documents this question goes across: what was ticked beside it, and readable.
    private let documents: [ProjectDocument]
    /// How many the project holds altogether, so the line above the field can say "12 of
    /// 14" rather than "12 of 12" -- the two numbers are the whole point of the choice.
    private let totalDocuments: Int

    /// What a click on a source does. The window shows it beside the answer rather than
    /// handing the file to another application, so checking a citation does not mean
    /// leaving the question behind.
    private let openCitation: (Citation) -> Void

    init(documents: [ProjectDocument], totalDocuments: Int? = nil,
         model: ProjectConversationModel,
         openCitation: ((Citation) -> Void)? = nil) {
        self.documents = documents
        self.totalDocuments = totalDocuments ?? documents.count
        self.model = model
        self.openCitation = openCitation ?? model.open
    }

    /// The answer being written out to a file, when one is.
    @State private var saving: ProjectTurn?

    var body: some View {
        ScrollView {
            // Not lazy. A conversation is tens of turns, so laziness buys nothing.
            VStack(alignment: .leading, spacing: Space.gutter) {
                if model.turns.isEmpty {
                    Text("Ask a question below. Every answer cites the document and page it came from.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.turns) { turn in
                    TurnView(turn: turn,
                             onOpen: openCitation,
                             footnote: footnote(for: turn),
                             copyWithCitations: { copy(turn) },
                             saveAsNote: { saving = turn })
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // A bottom inset, not the last row of a `VStack`. Stacked, the scroll area and the
        // composer added up to more than the pane, and an oversized child in a flexible
        // frame is centred: the top of the conversation was clipped above the pane and the
        // field clipped below it, which is why this pane looked empty and had nothing to
        // type into.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                VStack(spacing: Space.step) {
                    outbound
                    HStack(alignment: .bottom, spacing: Space.step) {
                        TextField("Ask across this project…",
                                  text: $model.pendingQuestion, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)
                            .onSubmit { Task { await model.prepareToAsk(documents: documents) } }
                        Button {
                            Task { await model.prepareToAsk(documents: documents) }
                        } label: {
                            if model.isPreparing {
                                ProgressView().controlSize(.small)
                            } else {
                                HStack(spacing: Space.snug) {
                                    Text("Ask")
                                    Text("\u{2318}\u{21A9}")
                                        .font(Face.mono.weight(.bold))
                                        .padding(.horizontal, Space.tight)
                                        .background(.white.opacity(0.22),
                                                    in: RoundedRectangle(cornerRadius: 3))
                                }
                            }
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.pendingQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || model.isPreparing
                                  || askReadiness(of: documents) != .ready)
                    }
                }
                .padding(Space.roomy)
            }
            .background(.bar)
        }
        .confirmationDialog(confirmationTitle, isPresented: confirmationShown, titleVisibility: .visible) {
            Button("Send") { Task { await model.confirmAndAsk() } }
            Button("Cancel", role: .cancel) { model.cancelPending() }
        } message: {
            Text(confirmationMessage)
        }
        .alert("Something went wrong", isPresented: errorShown(for: model)) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        // A file rather than a note kept in the library: there is nowhere in the library
        // that holds an answer, and a button that looked like it saved one would be
        // saving it nowhere.
        .fileExporter(isPresented: Binding(get: { saving != nil },
                                           set: { if !$0 { saving = nil } }),
                      document: TextDocument(text: saving.map(markdown) ?? ""),
                      contentType: .plainText,
                      defaultFilename: model.project.name) { _ in saving = nil }
    }

    /// What an answer was built from. Not what it cost: a price per answer is not
    /// recorded anywhere, and a number invented here would be read as one that was.
    private func footnote(for turn: ProjectTurn) -> String {
        guard !turn.isLoading, turn.error == nil, !turn.excerpts.isEmpty else { return "" }
        let documents = Set(turn.excerpts.map(\.contentHash)).count
        var parts = ["\(turn.excerpts.count) chunk\(turn.excerpts.count == 1 ? "" : "s") "
                     + "from \(documents) document\(documents == 1 ? "" : "s")"]
        if !model.modelName.isEmpty { parts.append(model.modelName) }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// The answer with its sources written out under it, which is the shape it takes
    /// anywhere it is pasted.
    ///
    /// `threadMarkdown` on the model is the same thing for every turn at once.
    private func markdown(_ turn: ProjectTurn) -> String {
        var out = "## \(turn.question)\n\n\(turn.reply)\n"
        let sources = numberedCitations(turn.citations)
        guard !sources.isEmpty else { return out }
        out += "\nSources\n"
        for source in sources {
            out += "\n\(source.number). \(source.citation.documentTitle), p. \(source.citation.page)"
            if let quote = turn.excerpts.first(where: {
                $0.contentHash == source.citation.contentHash && $0.page == source.citation.page
            })?.body, !quote.isEmpty {
                let flat = quote.replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                out += "\n   \u{201C}\(flat)\u{201D}"
            }
        }
        return out + "\n"
    }

    private func copy(_ turn: ProjectTurn) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown(turn), forType: .string)
    }

    /// What would be sent, on screen the whole time a question is being typed.
    ///
    /// It was a dialog after the fact, which is the wrong moment: by then the decision
    /// has been made and the dialog is something to dismiss. Here it is a sentence a
    /// person reads while deciding what to ask, and it says the same three things the
    /// dialog did -- how much text, to which host, answered by which model.
    private var outbound: some View {
        HStack(alignment: .top, spacing: Space.step) {
            Image(systemName: "info.circle")
                .foregroundStyle(askReadiness(of: documents) == .ready
                                 ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Ink.amber))
            Text(outboundLine)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.snug)
        }
        .font(Face.caption)
        .foregroundStyle(.secondary)
        .padding(Space.step)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Metric.card))
    }

    private var outboundLine: String {
        let indexed = documents.filter { !$0.markdown.isEmpty }
        switch askReadiness(of: documents) {
        case .noDocuments:
            return "No documents in this project yet. Drop PDFs on the list beside this, "
                 + "or add them from the library."
        case .noText:
            return totalDocuments > 0
                ? "None of the documents ticked beside this has text yet, so there is "
                    + "nothing to ask across."
                : "None of these documents has text yet, so there is nothing to ask across."
        case .ready:
            break
        }
        // Words, not characters: nobody has an intuition for 190,000 characters, and the
        // number is approximate either way.
        let words = indexed.reduce(0) { $0 + $1.markdown.count } / 5
        let host = URL(string: model.endpointName)?.host ?? model.endpointName
        let named = model.modelName.isEmpty ? "" : " as \(model.modelName)"
        return "\(indexed.count) of \(totalDocuments) documents · roughly "
            + "\(words.formatted(.number.notation(.compactName))) words will be sent to \(host)\(named)"
    }

    private var confirmationShown: Binding<Bool> {
        Binding(get: { model.pendingPreview != nil }, set: { if !$0 { model.cancelPending() } })
    }

    private var confirmationTitle: String {
        guard let preview = model.pendingPreview else { return "" }
        return "Send \(preview.documentCount) document\(preview.documentCount == 1 ? "" : "s") to \(preview.endpointHost)?"
    }

    /// Restated in full every time a question is asked, never a checkbox ticked once: the
    /// amount of text and the endpoint are exactly what changed since the last question.
    /// An endpoint that is not the trusted default, or one reached without encryption,
    /// gets a visibly stronger warning rather than the same quiet phrasing as the default.
    private var confirmationMessage: String {
        guard let preview = model.pendingPreview else { return "" }
        var message = "About \(preview.approximateCharacterCount) characters of your documents' text."
        if preview.isPlaintext {
            message += " Warning: this endpoint is not encrypted (plain http). "
                + "Anything on the network path between here and \(preview.endpointHost) can read it."
        } else if !preview.isDefaultEndpoint {
            message += " Warning: this is not the default OpenAI endpoint. "
                + "Only continue if you trust \(preview.endpointHost) with your documents."
        }
        return message
    }
}

private struct TurnView: View {
    let turn: ProjectTurn
    let onOpen: (Citation) -> Void
    /// What the answer cost and what it was built from, said once under it.
    var footnote: String = ""
    var copyWithCitations: () -> Void = {}
    var saveAsNote: () -> Void = {}
    var askWithAll: (() -> Void)?

    private var sources: [NumberedCitation] { numberedCitations(turn.citations) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.roomy) {
            HStack(alignment: .firstTextBaseline, spacing: Space.step) {
                // Who asked. A conversation with no speakers on it reads as a document,
                // and the question stops being a question you asked.
                Text(initials)
                    .font(Face.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.quaternary.opacity(0.6), in: Circle())
                Text(turn.question)
                    .font(Face.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if turn.isLoading {
                ProgressView().controlSize(.small).padding(.leading, Space.bay)
            } else if let error = turn.error {
                Text(error).foregroundStyle(Ink.red).padding(.leading, Space.bay)
            } else {
                VStack(alignment: .leading, spacing: Space.roomy) {
                    answer
                    if !sources.isEmpty { sourceList }
                    actions
                }
                .padding(.leading, Space.bay)
            }
        }
    }

    /// The reply, with each written-out "(Title, p. 17)" drawn as the number of the source
    /// it names. The citations belong under the answer, not in the middle of its sentences.
    private var answer: some View {
        Text(attributed)
            .font(Face.body)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        for piece in replyPieces(turn.reply, citations: turn.citations) {
            switch piece {
            case .text(let text):
                out += AttributedString(text)
            case .mark(let number):
                var mark = AttributedString(" \(number) ")
                mark.font = Face.micro.weight(.semibold).monospacedDigit()
                mark.foregroundColor = Ink.blue
                mark.backgroundColor = Ink.blue.opacity(0.14)
                out += mark
            }
        }
        return out
    }

    /// What each number points at: the document, the page, and the passage the answer was
    /// built from, so a claim can be checked without leaving the answer.
    private var sourceList: some View {
        VStack(spacing: 0) {
            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                if index > 0 { Divider().opacity(0.5) }
                sourceRow(source)
            }
        }
        .padding(.vertical, Space.tight)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Metric.card))
    }

    @ViewBuilder
    private func sourceRow(_ source: NumberedCitation) -> some View {
        let citation = source.citation
        let resolved = citation.contentHash != nil
        let quote = turn.excerpts.first {
            $0.contentHash == citation.contentHash && $0.page == citation.page
        }?.body
        Button {
            if resolved { onOpen(citation) }
        } label: {
            HStack(alignment: .top, spacing: Space.step) {
                Text("\(source.number)")
                    .font(Face.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(resolved ? Ink.blue : Color.secondary)
                    .frame(width: 18, height: 18)
                    .background((resolved ? Ink.blue : Color.secondary).opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: Space.tight) {
                    Text("\(citation.documentTitle) \u{00B7} p. \(citation.page)")
                        .font(Face.caption.weight(.semibold))
                        .strikethrough(!resolved)
                    if let quote, !quote.isEmpty {
                        Text("\u{201C}\(trimmed(quote))\u{201D}")
                            .font(Face.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !resolved {
                        // The model cited a title that was never sent. A plain link would
                        // look identical to a real one and quietly do nothing.
                        Text("This citation doesn't match a document that was sent.")
                            .font(Face.caption)
                            .foregroundStyle(Ink.amber)
                    }
                }
                Spacer(minLength: Space.snug)
                if resolved {
                    Image(systemName: "chevron.right")
                        .font(Face.micro)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Space.roomy)
            .padding(.vertical, Space.step)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!resolved)
    }

    /// A quotation is evidence, not an excerpt of the whole page: three lines of it is
    /// enough to check a claim against, and more of it buries the next source.
    private func trimmed(_ quote: String) -> String {
        let flat = quote.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > 240 else { return flat }
        return String(flat.prefix(240)) + "\u{2026}"
    }

    private var actions: some View {
        HStack(spacing: Space.step) {
            Button("Copy with citations", action: copyWithCitations)
            Button("Save as Markdown\u{2026}", action: saveAsNote)
            if let askWithAll {
                Button("Ask again with all", action: askWithAll)
            }
            Spacer(minLength: Space.step)
            if !footnote.isEmpty {
                Text(footnote)
                    .font(Face.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
    }

    /// The initials of whoever is at this machine, which is who asked.
    private var initials: String {
        let name = NSFullUserName()
        let letters = name.split(separator: " ").compactMap(\.first).prefix(2)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

/// Deduplicates citations for display: `Citation` itself carries a `Range<String.Index>`
/// that makes two citations to the same page compare unequal even when they should
/// collapse into one link.
private struct CitationKey: Hashable, Comparable {
    let title: String
    let page: Int

    init(_ citation: Citation) {
        title = citation.documentTitle
        page = citation.page
    }

    static func < (lhs: CitationKey, rhs: CitationKey) -> Bool {
        lhs.title == rhs.title ? lhs.page < rhs.page : lhs.title < rhs.title
    }
}

// MARK: - Shared

/// `Binding(get:set:)` inline in a modifier chain pushes some of these bodies past what
/// the type-checker will work through in reasonable time (Catalogue.swift has the same
/// fix, for the same reason, at its own `aiErrorShown`).
@MainActor
private func errorShown(for store: ProjectsStore) -> Binding<Bool> {
    Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })
}

@MainActor
private func errorShown(for model: ProjectDetailModel) -> Binding<Bool> {
    Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
}

@MainActor
private func errorShown(for model: ProjectConversationModel) -> Binding<Bool> {
    Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
}
