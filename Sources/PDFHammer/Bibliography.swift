import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import PDFHammerCore

/// Mirrors NodeView, but each file shows what it will contribute to the .bib.
struct BibNodeView: View {
    let node: Node
    @Binding var expanded: Set<String>
    @ObservedObject var runner: Runner

    var body: some View {
        if let key = node.itemKey, let entry = runner.bibByItem[key] {
            BibRow(entry: entry).tag(key).id(key)
        } else if node.itemKey == nil {
            DisclosureGroup(isExpanded: expansion) {
                ForEach(node.children ?? []) { child in
                    BibNodeView(node: child, expanded: $expanded, runner: runner)
                }
            } label: {
                Label {
                    Text(node.name).fontWeight(.medium)
                } icon: {
                    Image(systemName: "folder.fill").foregroundStyle(.tint)
                }
                .contentShape(Rectangle())
                .onTapGesture { expansion.wrappedValue.toggle() }
            }
        }
    }

    private var expansion: Binding<Bool> {
        Binding(
            get: { expanded.contains(node.id) },
            set: { open in
                if open { expanded.insert(node.id) } else { expanded.remove(node.id) }
            }
        )
    }
}

struct BibRow: View {
    let entry: BibEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.isComplete ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(entry.isComplete
                                 ? Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140))
                                 : Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60)))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.key)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.title.isEmpty ? "no title" : entry.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let author = entry.author {
                        Text(author).foregroundStyle(.secondary)
                    }
                    if let year = entry.year {
                        Text(year).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if !entry.missing.isEmpty {
                        Text("no " + entry.missing.joined(separator: ", "))
                            .foregroundStyle(Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60)))
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

/// The generated file. Entries are rendered one block at a time inside a LazyVStack, so
/// only what is on screen is ever tokenized: highlighting the whole document on every
/// redraw is what made this slow.
struct BibFileView: View {
    let entries: [BibEntry]
    @Binding var order: BibOrder
    @Binding var completeOnly: Bool
    let style: BibStyle

    @AppStorage("bibWrapped") private var wrapped = true
    @State private var blocks: [String] = []
    @State private var edited: String?
    @State private var copied = false
    @State private var saving = false

    /// What Copy and Save write: the edit if there is one, otherwise the blocks joined.
    private var text: String {
        if let edited { return edited }
        guard !blocks.isEmpty else { return "" }
        return blocks.joined(separator: style.blankLines ? "\n\n" : "\n") + "\n"
    }

    private var signature: String {
        [
            order.rawValue, "\(completeOnly)", "\(entries.count)",
            entries.first?.key ?? "", entries.last?.key ?? "",
            "\(style.lineWidth)", style.indent, "\(style.align)", style.delimiter.rawValue,
            "\(style.trailingComma)", "\(style.blankLines)", "\(style.sortFields)",
            "\(style.dropAllCaps)", style.omit.sorted().joined(separator: ","),
        ].joined(separator: "|")
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if edited != nil {
                TextEditor(text: Binding(get: { edited ?? "" }, set: { edited = $0 }))
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
            } else if blocks.isEmpty {
                ContentUnavailableView("Nothing to write yet", systemImage: "text.quote")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            Text(highlighted(block))
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                // Wrapped, a long path folds into the pane instead of
                                // running off it. Unwrapped, the layout is the file's own.
                                .fixedSize(horizontal: !wrapped, vertical: false)
                        }
                    }
                    .padding(14)
                }
            }
        }
        // Rebuilt only when the inputs actually move, off the main thread.
        .task(id: signature) {
            let snapshot = entries
            let currentOrder = order
            let onlyComplete = completeOnly
            let currentStyle = style
            let built = await Task.detached(priority: .userInitiated) {
                bibtexOrdered(snapshot, includeIncomplete: !onlyComplete, order: currentOrder)
                    .map { bibtexBlock($0, style: currentStyle) }
            }.value
            guard !Task.isCancelled else { return }
            blocks = built
        }
        .fileExporter(isPresented: $saving,
                      document: TextDocument(text: text),
                      contentType: .plainText,
                      defaultFilename: "library.bib") { _ in }
    }

    private var controls: some View {
      ScrollView(.horizontal) {
        HStack(spacing: 10) {
            Picker("Order", selection: $order) {
                ForEach(BibOrder.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(edited != nil)

            Toggle("Wrap", isOn: $wrapped)
                .toggleStyle(.checkbox)
                .tip("Fold long lines into the pane; the file itself is unchanged")
            Toggle("Complete only", isOn: $completeOnly)
                .toggleStyle(.checkbox)
                .disabled(edited != nil)

            if edited != nil {
                Label("Edited by hand", systemImage: "pencil")
                    .font(.callout)
                    .foregroundStyle(Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60)))
                Button("Discard edits") { edited = nil }
                    .controlSize(.small)
                    .tip("Throw away your edits, back to the generated file")
            } else {
                Button("Edit") { edited = text }
                    .controlSize(.small)
                    .tip("Take the text over by hand; ordering freezes")
            }

            Spacer()

            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(2)); copied = false }
            }
            .controlSize(.small)
            Button("Save…") { saving = true }
                .controlSize(.small)
                .tip("Write the file somewhere")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
      }
      .scrollIndicators(.hidden)
      .fixedSize(horizontal: false, vertical: true)
    }
}

/// Colours one block for reading. The tokens rebuild their input exactly, so what is
/// shown is character for character what Copy and Save produce.
func highlighted(_ text: String) -> AttributedString {
    var out = AttributedString()
    for token in bibtexTokens(text) {
        var piece = AttributedString(token.text)
        switch token.kind {
        case .entryType:
            piece.foregroundColor = Color(light: srgb(142, 42, 152), dark: srgb(214, 137, 226))
            piece.font = .system(.callout, design: .monospaced).weight(.semibold)
        case .key:
            piece.foregroundColor = Color(light: srgb(29, 78, 216), dark: srgb(133, 174, 255))
            piece.font = .system(.callout, design: .monospaced).weight(.semibold)
        case .field:
            piece.foregroundColor = Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60))
        case .value:
            piece.foregroundColor = Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140))
        case .punctuation:
            piece.foregroundColor = .secondary
        case .plain:
            break
        }
        out += piece
    }
    return out
}

struct TextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}


// MARK: - Duplicates
