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
    var tagFilter: String?
}

// MARK: - Environment
//
/// Everything the projects UI needs from storage and from the model, injected as plain
/// functions rather than a concrete type, the same shape AI.swift's `AIClient` and the
/// rest of this app's network calls already take. `Library` is the intended source of
/// every closure below once it lands; a preview hands in whatever it needs instead of
/// standing up a database.
struct ProjectsEnvironment {
    var listProjects: () async throws -> [ProjectSummary]
    var createProject: (_ name: String) async throws -> ProjectSummary
    var deleteProject: (_ id: Int64) async throws -> Void
    var members: (_ id: Int64) async throws -> [ProjectDocument]
    /// The rest of the library, so a project can offer something to add.
    var availableDocuments: (_ id: Int64) async throws -> [ProjectDocument]
    var addMember: (_ id: Int64, _ contentHash: String) async throws -> Void
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

// MARK: - Project detail: members and tags

@MainActor
final class ProjectDetailModel: ObservableObject {
    let project: ProjectSummary
    @Published private(set) var members: [ProjectDocument] = []
    @Published private(set) var tagsByDocument: [String: [String]] = [:]
    @Published private(set) var available: [ProjectDocument] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    private let env: ProjectsEnvironment

    init(project: ProjectSummary, env: ProjectsEnvironment) {
        self.project = project
        self.env = env
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let documents = try await env.members(project.id)
            members = documents
            var tags: [String: [String]] = [:]
            for document in documents {
                tags[document.contentHash] = try await env.tags(document.contentHash)
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

    func add(_ document: ProjectDocument) async {
        do {
            try await env.addMember(project.id, document.contentHash)
            members.append(document)
            available.removeAll { $0.contentHash == document.contentHash }
            // Tags are keyed by contentHash in the library, not by project, so a
            // document can arrive with tags it already had elsewhere; fetch them now
            // rather than showing it bare until the next full reload.
            tagsByDocument[document.contentHash] = try await env.tags(document.contentHash)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func remove(_ document: ProjectDocument) async {
        do {
            try await env.removeMember(project.id, document.contentHash)
            members.removeAll { $0.contentHash == document.contentHash }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func addTag(_ name: String, to document: ProjectDocument) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !(tagsByDocument[document.contentHash] ?? []).contains(trimmed) else { return }
        do {
            try await env.addTag(document.contentHash, trimmed)
            tagsByDocument[document.contentHash, default: []].append(trimmed)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func removeTag(_ name: String, from document: ProjectDocument) async {
        do {
            try await env.removeTag(document.contentHash, name)
            tagsByDocument[document.contentHash]?.removeAll { $0 == name }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ProjectDetailView: View {
    @StateObject private var model: ProjectDetailModel
    @State private var showingAddDocument = false
    @State private var tagDrafts: [String: String] = [:]
    private let env: ProjectsEnvironment

    init(project: ProjectSummary, env: ProjectsEnvironment) {
        self.env = env
        _model = StateObject(wrappedValue: ProjectDetailModel(project: project, env: env))
    }

    var body: some View {
        List {
            Section("Documents") {
                if model.members.isEmpty {
                    Text("No documents yet.").foregroundStyle(.secondary)
                }
                ForEach(model.members, id: \.contentHash) { document in
                    documentRow(document)
                }
            }
        }
        .navigationTitle(model.project.name)
        .toolbar {
            NavigationLink {
                ProjectConversationView(project: model.project, documents: model.members, env: env)
            } label: {
                Label("Ask", systemImage: "bubble.left.and.bubble.right")
            }
            .tip("Ask a question across every document in this project")
            .disabled(model.members.isEmpty)

            Button {
                showingAddDocument = true
                Task { await model.loadAvailable() }
            } label: {
                Label("Add Document", systemImage: "doc.badge.plus")
            }
            .tip("Add a document from your library to this project")
        }
        .sheet(isPresented: $showingAddDocument) {
            AddDocumentSheet(candidates: model.available) { document in
                Task { await model.add(document) }
                showingAddDocument = false
            }
        }
        .task { await model.load() }
        .alert("Something went wrong", isPresented: errorShown(for: model)) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    @ViewBuilder
    private func documentRow(_ document: ProjectDocument) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(document.title)
                Spacer()
                Button(role: .destructive) {
                    Task { await model.remove(document) }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .tip("Remove from this project, not from the library")
            }
            TagRow(
                tags: model.tagsByDocument[document.contentHash] ?? [],
                draft: Binding(
                    get: { tagDrafts[document.contentHash] ?? "" },
                    set: { tagDrafts[document.contentHash] = $0 }),
                onAdd: { name in
                    Task { await model.addTag(name, to: document) }
                    tagDrafts[document.contentHash] = ""
                },
                onRemove: { name in Task { await model.removeTag(name, from: document) } })
        }
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

private struct AddDocumentSheet: View {
    let candidates: [ProjectDocument]
    let onAdd: (ProjectDocument) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [ProjectDocument] {
        guard !query.isEmpty else { return candidates }
        return candidates.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a Document").font(.headline)
            TextField("Search your library", text: $query)
                .textFieldStyle(.roundedBorder)
            if filtered.isEmpty {
                Text(candidates.isEmpty ? "Every document is already in this project."
                                        : "Nothing matches.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filtered, id: \.contentHash) { document in
                    Button(document.title) {
                        onAdd(document)
                        dismiss()
                    }
                }
                .listStyle(.plain)
            }
        }
        .padding()
        .frame(width: 400, height: 320)
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
            pendingPreview = outboundPreview(excerpts: excerpts, endpoint: env.endpoint())
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
            HStack(alignment: .bottom) {
                TextField("Ask this project a question", text: $model.pendingQuestion, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { Task { await model.prepareToAsk(documents: documents) } }
                Button {
                    Task { await model.prepareToAsk(documents: documents) }
                } label: {
                    if model.isPreparing { ProgressView().controlSize(.small) } else { Text("Ask") }
                }
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
/// the type-checker will work through in reasonable time (App.swift has the same fix, for
/// the same reason, at its own `aiErrorShown`).
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
