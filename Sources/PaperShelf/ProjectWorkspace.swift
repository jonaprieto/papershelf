import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PaperShelfCore

/// A reading project in the middle of the window: the conversation, and the documents it
/// is asking across beside it.
///
/// It was three sheets deep -- a projects sheet, a detail sheet pushed inside it, and the
/// conversation pushed inside that -- so a question about fourteen books was asked in a
/// 720-point box with the shelf it came from hidden behind it. A project is a place, and
/// a place gets the window.
struct ProjectWorkspace: View {
    let project: ProjectSummary
    let env: ProjectsEnvironment
    /// Back to the shelf. The sidebar still shows which project is open, so this is the
    /// same rung of the ladder ⎋ is: out of this, into what contains it.
    let close: () -> Void

    @StateObject private var model: ProjectDetailModel
    @State private var showingAddDocuments = false
    @State private var exported = false
    @State private var dropTargeted = false

    /// Told when this project gains or loses a document, so the window's own count of it,
    /// drawn in the sidebar from a query taken when the window loaded, cannot go on
    /// saying what used to be true.
    /// Bumped by the window whenever something outside this view changes what the project
    /// holds, which is what a paper dropped on the project's row in the sidebar is. The
    /// list in front of you has to say what the project holds, not what it held when it
    /// was opened.
    var reloadToken: Int = 0

    init(project: ProjectSummary, env: ProjectsEnvironment,
         membershipChanged: @escaping () -> Void = {}, reloadToken: Int = 0,
         close: @escaping () -> Void) {
        self.reloadToken = reloadToken
        self.project = project
        self.env = env
        self.close = close
        _model = StateObject(wrappedValue: ProjectDetailModel(
            project: project, env: env, membershipChanged: membershipChanged))
    }

    var body: some View {
        HStack(spacing: 0) {
            ProjectConversationView(project: project,
                                    documents: model.members.map(\.document),
                                    env: env)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            documents.frame(width: Metric.inspectorIdeal)
        }
        .navigationTitle(project.name)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .onExitCommand(perform: close)
        .task { await model.load() }
        .task(id: reloadToken) {
            guard reloadToken != 0 else { return }
            await model.load()
        }
        .sheet(isPresented: $showingAddDocuments) {
            AddDocumentsSheet(candidates: model.available, knownSections: model.knownSections) { hashes, section in
                Task { await model.addBatch(hashes, section: section) }
            }
        }
    }

    private var subtitle: String {
        let sections = Set(model.members.compactMap(\.section)).count
        let indexed = model.members.filter { !$0.document.markdown.isEmpty }.count
        var parts = ["\(model.members.count) document\(model.members.count == 1 ? "" : "s")"]
        if indexed < model.members.count { parts.append("\(model.members.count - indexed) not indexed") }
        if sections > 0 { parts.append("\(sections) section\(sections == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: close) { Image(systemName: "chevron.left") }
                .keyboardShortcut(.cancelAction)
                .tip("Back to the shelf", key: "⎋")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showingAddDocuments = true
                Task { await model.loadAvailable() }
            } label: {
                Label("Add documents", systemImage: "doc.badge.plus")
            }
            .tip("Add documents from the library, several at once, filed under a section")
        }
    }

    /// What the project is made of, grouped the way it is filed, and honest about which
    /// documents have no text yet -- those contribute nothing but a title to an answer.
    private var documents: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("In this project").font(.callout.weight(.semibold))
                Spacer()
                Text("\(model.members.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
            Divider()

            List {
                if model.members.isEmpty {
                    Text("No documents yet. Drop PDFs here, or add them from the library.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.groupedMembers) { group in
                    Section("\(group.section ?? "Unfiled") · \(group.members.count)") {
                        ForEach(group.members) { member in row(member) }
                    }
                }
                if !notIndexed.isEmpty {
                    Section {
                        ForEach(notIndexed) { member in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(member.document.title).lineLimit(1)
                                Text("nothing to quote from yet")
                                    .font(.caption)
                                    .foregroundStyle(Ink.amber)
                            }
                        }
                    } header: {
                        // Reading them was only offered in the catalogue, over the whole
                        // shelf: for one paper dropped here that is a walk across every
                        // file the app knows about, which is why a project could sit with
                        // nothing to ask across and no way forward from this screen.
                        HStack {
                            Text("Not read yet · \(notIndexed.count)")
                            Spacer(minLength: 6)
                            Button {
                                Task { await model.readUnindexed() }
                            } label: {
                                if model.isReading {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Read \(notIndexed.count == 1 ? "it" : "them")")
                                }
                            }
                            .buttonStyle(.link)
                            .disabled(model.isReading)
                            .tip("Read the text of these documents so questions can quote them")
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        // A document dragged from the sidebar, or a PDF from Finder. Paths the library has
        // not seen are skipped by `addFiles`, so a stray drop is a no-op, not an import.
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : .clear)
        // `onDrop` rather than `dropDestination`: most of this pane is a List, and a drop
        // over a List does not reach the newer modifier wrapped around it. Every drag in
        // this app carries a file URL, so that is what it asks for.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                let urls = await droppedFileURLs(from: providers)
                guard !urls.isEmpty else { return }
                await model.addFiles(urls.map(\.path))
            }
            return true
        }
    }

    private var notIndexed: [ProjectMember] {
        model.members.filter { $0.document.markdown.isEmpty }
    }

    private func row(_ member: ProjectMember) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(member.document.title).lineLimit(2)
            Text([member.author, member.pageCount.map { "\($0) pp" }]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Remove from this project", role: .destructive) {
                Task { await model.remove(member) }
            }
        }
    }
}
