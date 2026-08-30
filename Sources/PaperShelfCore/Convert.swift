import Foundation
import PDFKit

/// An external tool that turns a PDF into Markdown.
///
/// None of these ship with the app. They are used when they happen to be installed,
/// because a converter is a large Python program and bundling one into a Swift app with
/// no dependencies would be a poor trade for a feature most runs never touch.
public struct MarkdownConverter: Sendable, Equatable {
    public let name: String
    public let executable: String
    public let note: String
    /// Built as a function because the tools disagree about how to name an output file.
    public let arguments: @Sendable (URL, URL) -> [String]

    public static func == (a: MarkdownConverter, b: MarkdownConverter) -> Bool {
        a.name == b.name && a.executable == b.executable
    }
}

/// Best first. Layout-aware tools beat plain extraction, and everything beats nothing.
public let markdownConverters: [MarkdownConverter] = [
    MarkdownConverter(
        name: "Marker", executable: "marker_single",
        note: "Layout-aware: headings, lists and tables survive",
        arguments: { input, output in
            [input.path, "--output_dir", output.deletingLastPathComponent().path]
        }
    ),
    MarkdownConverter(
        name: "Docling", executable: "docling",
        note: "Layout-aware, with table structure",
        arguments: { input, output in
            [input.path, "--to", "md", "--output", output.deletingLastPathComponent().path]
        }
    ),
    MarkdownConverter(
        name: "MarkItDown", executable: "markitdown",
        note: "Microsoft's converter; for PDFs it extracts the text",
        arguments: { input, output in [input.path, "-o", output.path] }
    ),
    MarkdownConverter(
        name: "pdftotext", executable: "pdftotext",
        note: "Poppler's extractor, laid out by column",
        arguments: { input, output in ["-layout", input.path, output.path] }
    ),
]

/// Where a tool lives, or nil when it is not installed.
///
/// `which` is not enough: a GUI app inherits launchd's PATH, which has none of the places
/// these get installed, so the usual ones are looked at directly.
public func locate(_ executable: String) -> URL? {
    var places = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin"]
    if let home = ProcessInfo.processInfo.environment["HOME"] {
        places.append(contentsOf: [home + "/.local/bin", home + "/.cargo/bin",
                                   home + "/Library/Python/3.11/bin",
                                   home + "/Library/Python/3.12/bin"])
    }
    for place in places {
        let candidate = URL(fileURLWithPath: place).appendingPathComponent(executable)
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
}

public func availableConverters() -> [(MarkdownConverter, URL)] {
    markdownConverters.compactMap { converter in
        locate(converter.executable).map { (converter, $0) }
    }
}

/// True for a line that stands on its own: a contents entry, an index entry, anything
/// with dot leaders or a trailing page number.
func isListing(_ line: String) -> Bool {
    if line.contains(". . .") || line.contains("....") { return true }
    guard let last = line.split(separator: " ").last, last.count <= 4,
          last.allSatisfy(\.isNumber), line.contains(" ") else { return false }
    // A sentence can end on a year, and a year is not a page number.
    return !(last.count == 4 && (last.hasPrefix("19") || last.hasPrefix("20")))
}

/// The built-in conversion: the document's own text, page by page.
///
/// A PDF does not record what is a heading, so nothing here can invent one. What it can do
/// is keep the paragraphs and say where each page began, which is enough to read and to
/// quote from, and it needs nothing installed.
public func markdownFromPDF(url: URL, passwords: [String], title: String? = nil,
                            pageMarkers: Bool = true) -> String {
    guard let document = PDFDocument(url: url) else { return "" }
    if document.isLocked {
        for password in passwords where document.unlock(withPassword: password) { break }
    }

    var out = "# \(markdownEscape(title ?? (url.lastPathComponent as NSString).deletingPathExtension))\n\n"
    for index in 0..<document.pageCount {
        guard let text = document.page(at: index)?.string, !text.isEmpty else { continue }
        if pageMarkers { out += "## Page \(index + 1)\n\n" }

        // Lines that end mid-sentence belong to the paragraph that follows: a PDF wraps
        // for the page it was set for, not for the width this will be read at.
        var paragraph = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !paragraph.isEmpty { out += markdownEscape(paragraph) + "\n\n"; paragraph = "" }
                continue
            }
            paragraph += paragraph.isEmpty ? trimmed : " " + trimmed
            // A contents or index line is a line, not part of a paragraph: joining them
            // turns a table of contents into one unreadable run.
            if isListing(trimmed) { out += markdownEscape(paragraph) + "\n\n"; paragraph = "" }
        }
        if !paragraph.isEmpty { out += markdownEscape(paragraph) + "\n\n" }
    }
    return out
}
