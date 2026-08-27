import SwiftUI
import AppKit
import PDFHammerCore

/// The store, made visible.
///
/// Everything the app has seen has been kept for a while now, and nothing in the interface
/// said so. A panel that shows what is in there, lets it be searched, and opens the reading
/// projects built on top of it is the difference between a feature and a file on disk.
extension ContentView {

    @ViewBuilder var libraryPanel: some View {
        // Bare Sections, like every other tab: the sidebar owns the Form, and nesting a
        // second one boxed and indented this tab differently from all its siblings.
        Group {
            if Library.shared == nil {
                Section {
                    Note(icon: "exclamationmark.triangle.fill", tint: .orange,
                         text: "The library could not be opened, so nothing is being kept. "
                               + "Everything else still works.")
                }
            } else {
                Section {
                    LabeledContent("Documents") { count(librarySummary?.documents) }
                    LabeledContent("Known paths") { count(librarySummary?.paths) }
                        .tip("Every place a document has been seen. A renamed file keeps "
                             + "its tags because the old path is still on record.")
                    LabeledContent("With text") { count(librarySummary?.withText) }
                        .tip("How many have had their text extracted, which is what a "
                             + "text search can reach")
                    LabeledContent("Tags") { count(librarySummary?.tags) }
                    LabeledContent("Projects") { count(librarySummary?.projects) }
                } header: {
                    Text("Library")
                } footer: {
                    Text("Kept in a small database under Application Support and updated as "
                         + "the watcher notices changes. The MCP server reads the same one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    HStack {
                        TextField("", text: $libraryQuery, prompt: Text("words in the text"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await searchLibrary() } }
                        Button("Search") { Task { await searchLibrary() } }
                            .disabled(libraryQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if librarySearching {
                        ProgressView().controlSize(.small)
                    } else if let libraryHits {
                        if libraryHits.isEmpty {
                            Text("Nothing matched.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(libraryHits, id: \.id) { hit in
                                Button {
                                    reveal(hit)
                                } label: {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(hit.title ?? "untitled")
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        if let author = hit.author {
                                            Text(author)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .tip("Show it in the Finder")
                            }
                        }
                    }
                } header: {
                    Text("Search the text")
                }

                Section {
                    Button {
                        showingProjects = true
                    } label: {
                        Label("Reading projects", systemImage: "books.vertical")
                    }
                    .buttonStyle(.link)
                    .tip("A named subset of the shelf you can ask questions about")

                    Button("Show the database in the Finder") {
                        if let url = libraryDatabaseURL() {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .task(id: runner.revision) { await refreshLibrarySummary() }
        .sheet(isPresented: $showingProjects) {
            if let library = Library.shared {
                ProjectsSheet(env: liveProjectsEnvironment(library: library, client: aiClient,
                                                           endpoint: aiBaseURL))
            }
        }
    }

    private func count(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "…")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    func refreshLibrarySummary() async {
        guard let library = Library.shared else { return }
        librarySummary = try? await library.summary()
    }

    private func searchLibrary() async {
        let text = libraryQuery.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let library = Library.shared else { return }
        librarySearching = true
        defer { librarySearching = false }
        libraryHits = (try? await library.fullTextSearch(text, limit: 25)) ?? []
    }

    /// The store keeps paths, so showing a hit means showing the file it came from.
    private func reveal(_ record: DocumentRecord) {
        guard let library = Library.shared else { return }
        Task {
            guard let places = try? await library.locations(forDocument: record.id),
                  let latest = places.max(by: { $0.lastSeenAt < $1.lastSeenAt })
            else { return }
            let url = URL(fileURLWithPath: latest.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                runner.note(.failed, subject: latest.path, detail: "no longer there")
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}


/// The projects list in a window of its own, since a conversation needs more room than a
/// sidebar has.
struct ProjectsSheet: View {
    let env: ProjectsEnvironment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Reading projects").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ProjectsListView(env: env)
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}
