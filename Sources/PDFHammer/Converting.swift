import SwiftUI
import AppKit
import PDFHammerCore

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

    func convert(_ item: Item, passwords: [String], using converter: MarkdownConverter?) async {
        guard !working else { return }
        working = true
        defer { working = false }

        let source = item.currentURL
        let title = (item.destinationName as NSString).deletingPathExtension

        guard let converter, let tool = locate(converter.executable) else {
            result = markdownFromPDF(url: source, passwords: passwords, title: title)
            usedTool = "the built-in reader"
            return
        }

        let text = await Task.detached(priority: .userInitiated) {
            Converting.run(tool: tool, converter: converter, source: source)
        }.value

        if let text, !text.isEmpty {
            result = text
            usedTool = converter.name
        } else {
            // A tool that is installed can still fail on a particular file, and an empty
            // answer is worse than the one that always works.
            result = markdownFromPDF(url: source, passwords: passwords, title: title)
            usedTool = "the built-in reader, after \(converter.name) returned nothing"
        }
    }

    private nonisolated static func run(tool: URL, converter: MarkdownConverter,
                                        source: URL) -> String? {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfhammer-md-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let output = scratch.appendingPathComponent(
            (source.lastPathComponent as NSString).deletingPathExtension + ".md")

        let process = Process()
        process.executableURL = tool
        process.arguments = converter.arguments(source, output)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        if let text = try? String(contentsOf: output, encoding: .utf8) { return text }
        // Some of them decide the filename themselves, so take whatever Markdown appeared.
        let produced = (try? FileManager.default.subpathsOfDirectory(atPath: scratch.path)) ?? []
        for path in produced where path.hasSuffix(".md") {
            if let text = try? String(contentsOf: scratch.appendingPathComponent(path),
                                      encoding: .utf8) { return text }
        }
        return nil
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
    /// By name, because a Picker tag has to be Hashable and a converter carries a closure.
    @State private var chosen: String = ""
    @State private var saving = false

    private var installed: [(MarkdownConverter, URL)] { converting.installed }
    private var picked: MarkdownConverter? { installed.first { $0.0.name == chosen }?.0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(item.destinationName).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 8) {
                Picker("Converter", selection: $chosen) {
                    Text("Built-in reader").tag("")
                    ForEach(installed, id: \.0.name) { converter, _ in
                        Text(converter.name).tag(converter.name)
                    }
                }
                .frame(width: 260)
                .tip(picked?.note ?? "Reads the document's own text. Needs nothing installed.",
                     key: nil)

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
                }
            }

            if installed.isEmpty {
                // Said once, plainly, rather than hidden behind a disabled control: there is
                // nothing wrong, there is simply nothing else installed.
                Text("No external converter found. Install one (marker, docling or markitdown) "
                     + "to keep headings and tables; the built-in reader works without it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let result = converting.result {
                if let tool = converting.usedTool {
                    Text("Converted by \(tool).").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(result)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
            } else {
                Spacer()
            }
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 460)
        .task {
            if converting.result == nil {
                chosen = installed.first?.0.name ?? ""
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
