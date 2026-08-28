import SwiftUI
import PDFHammerCore

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
    var sections: (_ id: Int64) async throws -> [String]
    /// Files a document under a section, adding it to the project first if it is not a
    /// member yet. `nil` means filed under nothing — a real, common state, not "not added"
    /// — matching `Library.setSection`. This is the one path both adding documents and
    /// moving one already in the project go through.
    var setSection: (_ id: Int64, _ contentHash: String, _ section: String?) async throws -> Void
    var removeMember: (_ id: Int64, _ contentHash: String) async throws -> Void
    var tags: (_ contentHash: String) async throws -> [String]
    var addTag: (_ contentHash: String, _ name: String) async throws -> Void
    var removeTag: (_ contentHash: String, _ tag: String) async throws -> Void
    /// Backed by `Library.fullTextSearch`: which of the given documents best match a
    /// question, best first. See `selectExcerpts` in PDFHammerCore for why this matters.
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
}

// MARK: - Projects list

@MainActor
final class ProjectsStore: ObservableObject {
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

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
    @StateObject private var store: ProjectsStore
    @State private var showingNewProject = false
    @State private var newProjectName = ""
    private let env: ProjectsEnvironment

    init(env: ProjectsEnvironment) {
        self.env = env
        _store = StateObject(wrappedValue: ProjectsStore(env: env))
    }

    var body: some View {
        List {
            if store.projects.isEmpty && !store.isLoading {
                Text("No reading projects yet.").foregroundStyle(.secondary)
            }
            ForEach(store.projects) { project in
                NavigationLink(value: project) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name).font(.headline)
                        Text("\(project.documentCount) document\(project.documentCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { indexSet in
                for index in indexSet { Task { await store.delete(store.projects[index]) } }
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
    }
}

private struct NewProjectSheet: View {
    @Binding var name: String
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Reading Project").font(.headline)
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
final class ProjectDetailModel: ObservableObject {
    let project: ProjectSummary
    @Published private(set) var members: [ProjectMember] = []
    @Published private(set) var tagsByDocument: [String: [String]] = [:]
    @Published private(set) var available: [ProjectMember] = []
    @Published private(set) var knownSections: [String] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    private let env: ProjectsEnvironment

    init(project: ProjectSummary, env: ProjectsEnvironment) {
        self.project = project
        self.env = env
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
            var tags: [String: [String]] = [:]
            for member in documents {
                tags[member.document.contentHash] = try await env.tags(member.document.contentHash)
            }
            tagsByDocument = tags
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
        } catch {
            self.error = error.localizedDescription
        }
    }

    func remove(_ member: ProjectMember) async {
        do {
            try await env.removeMember(project.id, member.document.contentHash)
            members.removeAll { $0.id == member.id }
            knownSections = try await env.sections(project.id)
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
    @StateObject private var model: ProjectDetailModel
    @State private var showingAddDocuments = false
    @State private var tagDrafts: [String: String] = [:]
    @State private var sectionPromptTarget: ProjectMember?
    @State private var newSectionName = ""
    private let env: ProjectsEnvironment

    init(project: ProjectSummary, env: ProjectsEnvironment) {
        self.env = env
        _model = StateObject(wrappedValue: ProjectDetailModel(project: project, env: env))
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
                ProjectConversationView(project: model.project, documents: model.members.map(\.document), env: env)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(member.document.title)
                    if let detail = recognitionDetail(author: member.author, pageCount: member.pageCount) {
                        Text(detail)
                            .font(.caption)
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
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.secondary.opacity(0.15)))
                    .onTapGesture { onRemove(tag) }
                    .help("Click to remove this tag")
            }
            TextField("Add tag", text: $draft)
                .textFieldStyle(.plain)
                .font(.caption)
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Add Documents").font(.headline)
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
                        HStack(spacing: 8) {
                            Image(systemName: selected.contains(member.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(member.id) ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(member.document.title)
                                if let detail = recognitionDetail(author: member.author, pageCount: member.pageCount) {
                                    Text(detail).font(.caption).foregroundStyle(.secondary)
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
                    HStack(spacing: 6) {
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
                    Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
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
final class ProjectConversationModel: ObservableObject {
    let project: ProjectSummary
    @Published var pendingQuestion = ""
    @Published private(set) var turns: [ProjectTurn] = []
    /// Non-nil the instant excerpts are chosen and a question is ready to send. The view
    /// turns this into a confirmation dialog every time, never a setting remembered from
    /// last time: the answer (how many documents, how many characters) is different for
    /// every question.
    @Published private(set) var pendingPreview: OutboundPreview?
    @Published var error: String?
    @Published private(set) var isPreparing = false

    private let env: ProjectsEnvironment
    private var confirmedQuestion: String?
    private var confirmedExcerpts: [Excerpt] = []

    var endpointName: String { env.endpoint() }
    var modelName: String { env.model() }

    init(project: ProjectSummary, env: ProjectsEnvironment) {
        self.project = project
        self.env = env
    }

    /// Step 1: chooses excerpts and shows what would be sent. Nothing reaches the
    /// network yet; `confirmAndAsk()` is the only function here that calls `env.ask`.
    func prepareToAsk(documents: [ProjectDocument]) async {
        let question = pendingQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
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
    @StateObject private var model: ProjectConversationModel
    private let documents: [ProjectDocument]

    init(project: ProjectSummary, documents: [ProjectDocument], env: ProjectsEnvironment) {
        self.documents = documents
        _model = StateObject(wrappedValue: ProjectConversationModel(project: project, env: env))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.turns.isEmpty {
                        Text("Ask a question below. Every answer cites the document and page it came from.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.turns) { turn in
                        TurnView(turn: turn, onOpen: model.open)
                    }
                }
                .padding()
            }
            Divider()
            outbound
            HStack(alignment: .bottom) {
                TextField("Ask across this project…", text: $model.pendingQuestion, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { Task { await model.prepareToAsk(documents: documents) } }
                Button {
                    Task { await model.prepareToAsk(documents: documents) }
                } label: {
                    if model.isPreparing { ProgressView().controlSize(.small) } else { Text("Ask") }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(model.pendingQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || model.isPreparing)
            }
            .padding()
        }
        .navigationTitle("Ask: \(model.project.name)")
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
    }

    /// What would be sent, on screen the whole time a question is being typed.
    ///
    /// It was a dialog after the fact, which is the wrong moment: by then the decision
    /// has been made and the dialog is something to dismiss. Here it is a sentence a
    /// person reads while deciding what to ask, and it says the same three things the
    /// dialog did -- how much text, to which host, answered by which model.
    private var outbound: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.forward.square")
            Text(outboundLine)
            Spacer(minLength: 6)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var outboundLine: String {
        let indexed = documents.filter { !$0.markdown.isEmpty }
        guard !indexed.isEmpty else {
            return "None of these documents has text yet, so there is nothing to ask across."
        }
        // Words, not characters: nobody has an intuition for 190,000 characters, and the
        // number is approximate either way.
        let words = indexed.reduce(0) { $0 + $1.markdown.count } / 5
        let host = URL(string: model.endpointName)?.host ?? model.endpointName
        let named = model.modelName.isEmpty ? "" : " as \(model.modelName)"
        return "\(indexed.count) of \(documents.count) documents · roughly "
            + "\(words.formatted(.number.notation(.compactName))) words would be sent to \(host)\(named)"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(turn.question)
                .font(.headline)
            if turn.isLoading {
                ProgressView().controlSize(.small)
            } else if let error = turn.error {
                Text(error).foregroundStyle(.red)
            } else {
                Text(turn.reply)
                if !turn.citations.isEmpty {
                    citationList
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.08)))
    }

    private var citationList: some View {
        // A distinct (title, page) pair per button: the same page can legitimately be
        // cited more than once in one answer, and that should not draw two links.
        let unique = Array(Set(turn.citations.map { CitationKey($0) })).sorted()
        return HStack(spacing: 8) {
            ForEach(unique, id: \.self) { key in
                let citation = turn.citations.first { $0.documentTitle == key.title && $0.page == key.page }
                if let citation, citation.contentHash != nil {
                    Button("\(key.title), p. \(key.page)") { onOpen(citation) }
                        .buttonStyle(.link)
                        .font(.caption)
                } else {
                    // contentHash is nil: the model cited a title never actually sent.
                    // A plain link here would look identical to a real one and silently
                    // do nothing when tapped; show it as unresolved instead.
                    Text("\(key.title), p. \(key.page)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .strikethrough()
                        .help("This citation doesn't match a document that was sent with this question.")
                }
            }
        }
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
