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

    @State private var model: ProjectDetailModel
    /// Held by the window rather than by the conversation under it, so the toolbar can
    /// write the whole thread out.
    @State private var conversation: ProjectConversationModel
    @State private var showingAddDocuments = false
    @State private var exporting = false
    @State private var dropTargeted = false
    @State private var editingMeaningScope: HighlightMeaningScope?

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
        _model = State(wrappedValue: ProjectDetailModel(
            project: project, env: env, membershipChanged: membershipChanged))
        _conversation = State(wrappedValue: ProjectConversationModel(
            project: project, env: env))
    }

    /// Which documents this question goes across. Seeded with everything that has text,
    /// because that is what asking across a project means; a checkbox is for the times it
    /// does not -- one book pulling every answer towards itself, or a reading list you
    /// want a chapter's worth of.
    @State private var chosen: Set<String> = []

    /// Only what was chosen and has text. A document with no text contributes a title and
    /// nothing to quote, so it cannot be part of an answer whatever the box says.
    private var asking: [ProjectDocument] {
        model.members.map(\.document).filter { chosen.contains($0.contentHash) && !$0.markdown.isEmpty }
    }

    private var choosable: [ProjectMember] {
        model.members.filter { !$0.document.markdown.isEmpty }
    }

    var body: some View {
        // Bounded to the room it is given rather than to what its panes would like. Asked
        // for their ideal height the two of them add up to more than the window, and a
        // subtree that demands more height than there is pushes the window's own status
        // bar off the bottom and clips its own content top and bottom. A `GeometryReader`
        // proposes the space that exists, so nothing inside can ask for more.
        GeometryReader { room in
            HStack(spacing: 0) {
                ProjectConversationView(documents: asking,
                                        totalDocuments: model.members.count,
                                        model: conversation,
                                        openCitation: show)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                if let previewing {
                    citationPreview(previewing).frame(width: Metric.contentsRail + 220)
                } else {
                    documents.frame(width: Metric.inspectorIdeal)
                }
            }
            .frame(width: room.size.width, height: room.size.height)
        }
        .navigationTitle(project.name)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .onExitCommand(perform: close)
        .task {
            await model.load()
            seedChosen()
        }
        .task(id: reloadToken) {
            guard reloadToken != 0 else { return }
            await model.load()
            seedChosen()
        }
        .fileExporter(isPresented: $exporting,
                      document: TextDocument(text: conversation.threadMarkdown),
                      contentType: .plainText,
                      defaultFilename: project.name) { _ in }
        .sheet(isPresented: $showingAddDocuments) {
            AddDocumentsSheet(candidates: model.available, knownSections: model.knownSections) { hashes, section in
                Task { await model.addBatch(hashes, section: section) }
            }
        }
        .sheet(item: $editingMeaningScope) { scope in
            HighlightMeaningEditor(palette: .shared, scope: scope)
        }
    }

    /// Everything readable, ticked. A document added while the project is open joins the
    /// question; one already unticked by hand stays unticked.
    private func seedChosen() {
        let readable = Set(choosable.map(\.document.contentHash))
        let unticked = Set(model.members.map(\.document.contentHash)).subtracting(chosen)
        chosen = readable.subtracting(unticked.intersection(readable))
        if chosen.isEmpty { chosen = readable }
    }

    /// The page a citation points at, shown beside the answer that cited it.
    struct Previewing: Equatable {
        let hash: String
        let url: URL
        let page: Int
        let title: String
    }

    @State private var previewing: Previewing?

    /// Opens a citation here rather than in another application. A citation is about one
    /// page, so the file is opened at it; a document opened at the front leaves you to
    /// find p. 108 yourself, which is the work the citation was supposed to save.
    private func show(_ citation: Citation) {
        guard let hash = citation.contentHash else { return }
        Task {
            guard let url = await env.locate(hash) else {
                // The library knows the document but not where it is any more. Handing it
                // to the system is the one thing left that might still find it.
                env.openAtPage(hash, citation.page)
                return
            }
            previewing = Previewing(hash: hash, url: url, page: citation.page,
                                    title: citation.documentTitle)
        }
    }

    /// The cited page, with the way back to the document list above it.
    private func citationPreview(_ preview: Previewing) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.step) {
                Button { previewing = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .tip("Back to the documents in this project")
                VStack(alignment: .leading, spacing: Space.hair) {
                    Text(preview.title)
                        .font(Face.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("p. \(preview.page)")
                        .font(Face.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Space.tight)
                Button { env.openAtPage(preview.hash, preview.page) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .tip("Open this page in the default PDF viewer")
            }
            .padding(.horizontal, Space.roomy)
            .padding(.vertical, Space.step)
            .frame(maxWidth: .infinity)
            .background(.bar)
            Divider()

            PDFPreview(url: preview.url, passwords: env.passwords(), page: preview.page)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
    }

    private var subtitle: String {
        let sections = Set(model.members.compactMap(\.section)).count
        let unread = model.members.count - choosable.count
        var parts = ["\(model.members.count) document\(model.members.count == 1 ? "" : "s")"]
        // How much there is to ask across, which is the number that decides whether a
        // question can be answered at all. Words rather than characters: nobody has an
        // intuition for 1,200,000 characters.
        let words = choosable.reduce(0) { $0 + $1.document.markdown.count } / 5
        if words > 0 {
            parts.append("\(words.formatted(.number.notation(.compactName))) words indexed")
        }
        if unread > 0 { parts.append("\(unread) not indexed") }
        if sections > 0 { parts.append("\(sections) section\(sections == 1 ? "" : "s")") }
        return parts.joined(separator: " \u{00B7} ")
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

            Button { exporting = true } label: {
                Label("Export the thread", systemImage: "square.and.arrow.up")
            }
            .disabled(conversation.turns.isEmpty)
            .tip("Write every question and answer in this project out as Markdown")

            Button {
                editingMeaningScope = .project(id: project.id, name: project.name)
            } label: {
                Label("Highlight meanings", systemImage: "textformat")
            }
            .tip("Customize highlight meanings for this project")
        }
    }

    /// What the project is made of, grouped the way it is filed, and honest about which
    /// documents have no text yet -- those contribute nothing but a title to an answer.
    private var documents: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.step) {
                Text("In this project").font(Face.headline)
                Text("\(model.members.count) document\(model.members.count == 1 ? "" : "s")")
                    .font(Face.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Space.snug)
                if !choosable.isEmpty {
                    Button(allChosen ? "Select none" : "Select all") {
                        chosen = allChosen ? [] : Set(choosable.map(\.document.contentHash))
                    }
                    .buttonStyle(.link)
                    .font(Face.caption)
                    .tip("Which documents this question goes across")
                }
            }
            .padding(.horizontal, Space.roomy)
            .padding(.vertical, Space.step)
            .frame(maxWidth: .infinity)
            .background(.bar)
            Divider()

            List {
                if model.members.isEmpty {
                    Text("No documents yet. Drop PDFs here, or add them from the library.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.groupedMembers) { group in
                    let readable = group.members.filter { !$0.document.markdown.isEmpty }
                    if !readable.isEmpty {
                        Section("\(group.section ?? "Unfiled") \u{00B7} \(readable.count)") {
                            ForEach(readable) { member in row(member) }
                        }
                    }
                }
                if !notIndexed.isEmpty {
                    Section {
                        ForEach(notIndexed) { member in unreadableRow(member) }
                    } header: {
                        // Reading them was only offered in the catalogue, over the whole
                        // shelf: for one paper dropped here that is a walk across every
                        // file the app knows about, which is why a project could sit with
                        // nothing to ask across and no way forward from this screen.
                        HStack {
                            Text("Not yet indexed \u{00B7} \(notIndexed.count)")
                            Spacer(minLength: Space.snug)
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
                seedChosen()
            }
            return true
        }
    }

    private var allChosen: Bool {
        !choosable.isEmpty && chosen.count >= choosable.count
    }

    private var notIndexed: [ProjectMember] {
        model.members.filter { $0.document.markdown.isEmpty }
    }

    private func row(_ member: ProjectMember) -> some View {
        Toggle(isOn: Binding(
            get: { chosen.contains(member.document.contentHash) },
            set: { on in
                if on { chosen.insert(member.document.contentHash) }
                else { chosen.remove(member.document.contentHash) }
            }
        )) {
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(member.document.title).font(Face.body).lineLimit(2)
                Text(detail(member))
                    .font(Face.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .contextMenu {
            Button("Remove from this project", role: .destructive) {
                Task { await model.remove(member) }
            }
        }
    }

    /// A document with no text: shown, unticked and unturnable, with the reason it cannot
    /// join a question. Hiding them is how a project came to sit with nothing to ask
    /// across and no sign of why.
    private func unreadableRow(_ member: ProjectMember) -> some View {
        Toggle(isOn: .constant(false)) {
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(member.document.title)
                    .font(Face.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("nothing to quote from yet \u{2014} read it first")
                    .font(Face.caption)
                    .foregroundStyle(Ink.amber)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(true)
        .contextMenu {
            Button("Remove from this project", role: .destructive) {
                Task { await model.remove(member) }
            }
        }
    }

    /// Who wrote it, how long it is, and whether it can be quoted. The last is the one
    /// that decides whether ticking the box does anything.
    private func detail(_ member: ProjectMember) -> String {
        [member.author, member.pageCount.map { "\($0) pp" }, "indexed"]
            .compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
}
