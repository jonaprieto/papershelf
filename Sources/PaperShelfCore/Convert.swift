import Foundation
import PDFKit
import Vision

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

/// The name that means "read it here, with nothing installed", as opposed to the empty
/// string, which means "whatever is best installed right now".
public let builtInReaderName = "built-in"

/// The name for reading the pages as pictures, with the OCR that ships with macOS.
public let builtInOCRName = "built-in-ocr"

/// How a document is turned into Markdown.
///
/// Two of these need nothing installed. `reader` is the document's own text layer, which
/// is exact and instant and is what most PDFs have; `ocr` reads the pages as pictures
/// with Vision, which is the only thing in this list that can read a scan, and it ships
/// with the operating system rather than being a Python program someone has to find. That
/// is what makes the app useful on a scanned shelf out of the box.
public enum MarkdownEngine: Sendable, Equatable {
    /// The best answer available for this particular document: an installed converter if
    /// there is one, then the text layer, then OCR for a page that has no text layer.
    case automatic
    case reader
    case ocr
    case external(MarkdownConverter)

    public var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .reader: return "the built-in reader"
        case .ocr: return "the built-in OCR"
        case .external(let converter): return converter.name
        }
    }
}

/// The engine a stored preference names.
///
/// An empty preference, which is what every install starts with, means automatic: take
/// the best tool installed, and where none is, read the document here. The two built-in
/// names pick one of those on purpose, and any other name picks that external tool when
/// it is installed, falling back to automatic when it is not, since a preference naming
/// a tool somebody has since uninstalled should not turn into a worse answer silently.
public func engine(named name: String) -> MarkdownEngine {
    switch name {
    case "": return .automatic
    case builtInReaderName: return .reader
    case builtInOCRName: return .ocr
    default:
        guard let found = availableConverters().first(where: { $0.0.name == name })?.0
        else { return .automatic }
        return .external(found)
    }
}

/// One PDF as Markdown, and the name of whatever produced it.
///
/// Every path here ends in an answer. An external tool is used when it is installed, since
/// a layout-aware converter keeps headings and tables the text layer cannot describe; a
/// document with a text layer is read from it, which is exact and costs nothing; and a
/// document without one is read as pictures, which is the only way a scan becomes text at
/// all. A caller never has to decide what to do about a tool that is not there.
///
/// Blocking: it waits on another process, or on OCR. Call it off the main actor.
public func markdown(for url: URL, passwords: [String], using engine: MarkdownEngine,
                     title: String? = nil) -> (text: String, tool: String) {
    let fallbackTitle = title ?? (url.lastPathComponent as NSString).deletingPathExtension

    func read() -> (String, String) {
        (markdownFromPDF(url: url, passwords: passwords, title: fallbackTitle),
         "the built-in reader")
    }
    func recognise(after note: String = "") -> (String, String) {
        let text = markdownFromScan(url: url, passwords: passwords, title: fallbackTitle)
        return (text, note.isEmpty ? "the built-in OCR" : "the built-in OCR, \(note)")
    }

    switch engine {
    case .reader:
        return read()
    case .ocr:
        return recognise()
    case .external(let converter):
        guard let tool = locate(converter.executable) else { return read() }
        if let text = runConverter(tool: tool, converter: converter, source: url), !text.isEmpty {
            return (text, converter.name)
        }
        // A tool that is installed can still fail on a particular file, and an empty
        // answer is worse than the one that always works.
        let fallback = read()
        return (fallback.0, "the built-in reader, after \(converter.name) returned nothing")
    case .automatic:
        if let converter = availableConverters().first?.0 {
            return markdown(for: url, passwords: passwords, using: .external(converter),
                            title: fallbackTitle)
        }
        // The text layer where there is one: it is the document's own words, exactly, and
        // it takes no time. OCR only for what has none, which is what a scan is.
        let direct = read()
        guard !hasReadableText(url: url, passwords: passwords) else { return direct }
        let recognised = recognise(after: "since this document has no text layer")
        return recognised.0.count > direct.0.count ? recognised : direct
    }
}

/// Whether the document carries its own text, which decides whether reading it is a
/// matter of asking or a matter of looking.
///
/// Judged on the first few pages: a scan is a scan from its first page, and opening every
/// page of a long book to find out costs more than the answer is worth.
public func hasReadableText(url: URL, passwords: [String], pages: Int = 3) -> Bool {
    guard let document = PDFDocument(url: url) else { return false }
    if document.isLocked {
        for password in passwords where document.unlock(withPassword: password) { break }
    }
    guard !document.isLocked else { return false }
    var found = 0
    for index in 0..<min(pages, document.pageCount) {
        found += document.page(at: index)?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0
        // A page of a scanned book often carries a stray character or two from a stamp or
        // a page number, so "has text" has to mean more than "is not empty". A short
        // sentence is text; a page number is not.
        if found > 20 { return true }
    }
    return false
}

/// Runs one converter over one file, in a scratch directory of its own.
public func runConverter(tool: URL, converter: MarkdownConverter, source: URL) -> String? {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("papershelf-md-\(UUID().uuidString)", isDirectory: true)
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

/// How many pages OCR reads before it stops.
///
/// Recognition is a second or so a page, so a four-hundred-page scan would be several
/// minutes of somebody waiting. Thirty pages is more than enough to search, to quote and
/// to tell what a document is, which is what this text is for.
public let ocrPageLimit = 30

/// The pages read as pictures, with the text recognition that ships with macOS.
///
/// This is the engine that makes a scanned shelf useful without installing anything: a
/// PDF with no text layer is invisible to every other reader here, and to search, and to
/// a project's questions. Vision is on every Mac this app runs on, so it is always
/// available, unlike the Python converters, and it is good enough on printed pages to be
/// worth the wait.
///
/// Blocking, and slow by nature. Call it off the main actor.
public func markdownFromScan(url: URL, passwords: [String], title: String? = nil,
                             pageLimit: Int = ocrPageLimit) -> String {
    guard let document = PDFDocument(url: url) else { return "" }
    if document.isLocked {
        for password in passwords where document.unlock(withPassword: password) { break }
    }
    guard !document.isLocked else { return "" }

    let name = title ?? (url.lastPathComponent as NSString).deletingPathExtension
    var out = "# \(markdownEscape(name))\n\n"
    for index in 0..<min(pageLimit, document.pageCount) {
        guard let page = document.page(at: index) else { continue }
        let lines = recognisedLines(on: page)
        guard !lines.isEmpty else { continue }
        out += "## Page \(index + 1)\n\n"
        // One paragraph per run of lines, joined the way the reader joins them: OCR
        // returns a line per line of print, and a page of those is not a paragraph.
        out += markdownEscape(lines.joined(separator: " ")) + "\n\n"
    }
    if document.pageCount > pageLimit {
        out += "_Read the first \(pageLimit) of \(document.pageCount) pages._\n\n"
    }
    return out
}

/// One page's text, recognised. Nil results are pages Vision could not read, which are
/// left out rather than reported as empty ones.
func recognisedLines(on page: PDFPage) -> [String] {
    let bounds = page.bounds(for: .mediaBox)
    // Twice the page size: recognition on a page rendered at its own points misses small
    // print, and this is the cheapest way to give it something to work with.
    let scale: CGFloat = 2
    let width = Int(bounds.width * scale)
    let height = Int(bounds.height * scale)
    guard width > 0, height > 0,
          let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return [] }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
    page.draw(with: .mediaBox, to: context)
    guard let image = context.makeImage() else { return [] }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    guard (try? handler.perform([request])) != nil else { return [] }
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
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
