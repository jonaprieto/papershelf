import SwiftUI
import AppKit
import PaperShelfCore

/// Turns a PDF into Markdown, using a converter that happens to be installed or falling
/// back to reading the document directly.
///
/// The fallback matters more than the tools: it needs nothing, works on every file the
/// app can already open, and is what most people will ever use. A layout-aware converter
/// is better when there is one, and saying which was used is part of the answer.
@MainActor
final class Converting: ObservableObject {
    @Published private(set) var working = false
    @Published private(set) var result: String?
    @Published private(set) var usedTool: String?
    @Published var problem: String?

    /// Recomputed on demand rather than cached: someone can install one while the app runs.
    var installed: [(MarkdownConverter, URL)] { availableConverters() }

    func convert(_ item: Item, passwords: [String], using engine: MarkdownEngine) async {
        guard !working else { return }
        working = true
        defer { working = false }

        let source = item.currentURL
        let title = (item.destinationName as NSString).deletingPathExtension
        // The same conversion the projects use to read their own documents (see
        // `readTextForProject`), so what a person sees in this sheet and what a question
        // is answered from cannot be produced two different ways.
        let produced = await Task.detached(priority: .userInitiated) {
            markdown(for: source, passwords: passwords, using: engine, title: title)
        }.value
        result = produced.text
        usedTool = produced.tool
    }

    /// Keeps a conversion as what the library knows this document says. Reports failure
    /// through `problem`, since a write that quietly did nothing is how a person ends up
    /// asking a project a question it cannot answer.
    func keep(_ markdown: String, for item: Item) async -> Bool {
        guard let library = Library.shared else {
            problem = "The library is unavailable, so there is nowhere to keep this."
            return false
        }
        guard await storeAsDocumentText(markdown, for: item.currentURL, library: library) else {
            problem = "Could not keep this as \(item.destinationName)'s text."
            return false
        }
        return true
    }

    func clear() {
        result = nil
        usedTool = nil
    }
}

/// Shows the Markdown, says what produced it, and offers to save it.
struct MarkdownSheet: View {
    let item: Item
    let passwords: [String]
    @ObservedObject var converting: Converting
    @Environment(\.dismiss) private var dismiss
    /// The converter is picked by name, because a Picker tag has to be Hashable and a
    /// converter carries a closure. It is the same setting Settings › Integrations
    /// shows, so the choice is made once rather than on every sheet.
    @Bindable private var prefs = Prefs.shared
    @State private var saving = false
    /// True once this Markdown has been kept as the document's text, so the button says
    /// what happened rather than inviting the same write again.
    @State private var kept = false

    private var installed: [(MarkdownConverter, URL)] { converting.installed }
    /// The same resolution a project uses (see `engine(named:)`): a name picks that
    /// tool, the two built-in names pick one of those on purpose, and an empty preference
    /// means take the best answer available for the document in front of you.
    private var picked: MarkdownEngine { engine(named: prefs.defaultConverter) }

    /// What the chosen engine is for, said where it is chosen.
    private var engineNote: String {
        switch picked {
        case .automatic:
            return "The best answer for this document: an installed converter, its own "
                 + "text layer, or OCR for a scan that has none."
        case .reader: return "Reads the document's own text. Needs nothing installed."
        case .ocr:
            return "Reads the pages as pictures, with the recognition that ships with "
                 + "macOS. The only one of these that can read a scan."
        case .external(let converter): return converter.note
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.roomy) {
            HStack {
                Text(item.destinationName).font(Face.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            HStack(spacing: Space.step) {
                Picker("Converter", selection: $prefs.defaultConverter) {
                    Text("Automatic (best for the document)").tag("")
                    Text("Built-in reader").tag(builtInReaderName)
                    Text("Built-in OCR").tag(builtInOCRName)
                    ForEach(installed, id: \.0.name) { converter, _ in
                        Text(converter.name).tag(converter.name)
                    }
                }
                .frame(width: 260)
                .tip(engineNote, key: nil)

                Button("Convert") {
                    Task { await converting.convert(item, passwords: passwords, using: picked) }
                }
                .disabled(converting.working)

                if converting.working { ProgressView().controlSize(.small) }
                Spacer()
                if let result = converting.result {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result, forType: .string)
                    }
                    Button("Save…") { saving = true }
                    // The same text a reading project reads its own documents with, kept
                    // for this file from wherever it was selected. Without this the only
                    // way to give a document text was to index the whole shelf, and the
                    // only way to get a converter's Markdown out of here was a file on
                    // disk the app then knew nothing about.
                    Button(kept ? "Kept" : "Use as this document's text") {
                        Task { kept = await converting.keep(result, for: item) }
                    }
                    .disabled(kept || Library.shared == nil)
                    .tip("Keep this as the document's text, so search can find it and a "
                         + "project can quote it")
                }
            }

            if installed.isEmpty {
                // Said once, plainly, rather than hidden behind a disabled control: there is
                // nothing wrong, there is simply nothing else installed.
                Text("No external converter found. Install one (marker, docling or markitdown) "
                     + "to keep headings and tables; the built-in reader works without it.")
                    .font(Face.caption).foregroundStyle(.secondary)
            }

            if let result = converting.result {
                if let tool = converting.usedTool {
                    Text("Converted by \(tool).").font(Face.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(result)
                        .font(Face.code)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.step)
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
            } else {
                Spacer()
            }
        }
        .padding(Space.gutter)
        .frame(minWidth: 620, minHeight: 460)
        .onChange(of: converting.result) { _, _ in kept = false }
        .task {
            // Left alone rather than overwritten: the preference is shared with Settings
            // and with what a project reads its documents through, and opening this sheet
            // is not a decision about any of that.
            if converting.result == nil {
                await converting.convert(item, passwords: passwords, using: picked)
            }
        }
        .fileExporter(isPresented: $saving,
                      document: TextDocument(text: converting.result ?? ""),
                      contentType: .plainText,
                      defaultFilename: (item.destinationName as NSString)
                        .deletingPathExtension + ".md") { _ in }
    }
}
