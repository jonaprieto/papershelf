import PDFKit
import AppKit

/// Why a mark could not be written, in a sentence the caller can act on.
public struct PDFMarkError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// The marks a reader can make or change, with the id each one is known by.
///
/// An id has to survive the file being rewritten and other marks coming and going, and
/// most PDFs give their annotations no name of their own. So it is derived from what a note
/// or colour change leaves alone: the page, the kind, and where the mark sits. Two marks
/// stacked exactly on top of each other get a counter so they stay apart.
func editableMarks(in document: PDFDocument) -> [(page: PDFPage, number: Int, annotation: PDFAnnotation, id: String)] {
    let wanted: Set<String> = ["Highlight", "Underline", "StrikeOut", "Text"]
    var found: [(PDFPage, Int, PDFAnnotation, String)] = []
    var seen: [String: Int] = [:]
    for index in 0..<document.pageCount {
        guard let page = document.page(at: index) else { continue }
        for annotation in page.annotations {
            guard let type = annotation.type, wanted.contains(type) else { continue }
            let box = annotation.bounds
            // A tenth of a point is finer than any two real marks differ by, and coarser
            // than the rounding a rewrite puts into the stored numbers.
            let key = "\(index + 1)|\(type)|" + [box.minX, box.minY, box.width, box.height]
                .map { String(format: "%.1f", $0) }.joined(separator: ",")
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            var id = "\(index + 1)-" + String(hash, radix: 36)
            seen[id, default: 0] += 1
            if let count = seen[id], count > 1 { id += "-\(count)" }
            found.append((page, index + 1, annotation, id))
        }
    }
    return found
}

/// Highlights, underlines or strikes out `text` on one page and writes the file.
///
/// The text is matched ignoring case, spacing, line breaks and hyphens, so a passage quoted
/// from `read_page` finds itself across a hyphenated line end. Text that appears more than
/// once on the page is refused rather than guessed at.
@discardableResult
public func addPDFMark(to url: URL, page number: Int, text: String,
                       kind: PDFAnnotationSubtype = .highlight, colour: NSColor,
                       note: String = "") throws -> PDFMark {
    let document = try openForMarking(url)
    guard number >= 1, number <= document.pageCount, let page = document.page(at: number - 1) else {
        throw PDFMarkError("page \(number) is outside the document, which has \(document.pageCount)")
    }
    let ranges = matches(of: text, in: page.string ?? "")
    guard let range = ranges.first else {
        throw PDFMarkError("that text is not on page \(number); quote it as read_page gives it")
    }
    guard ranges.count == 1 else {
        throw PDFMarkError("that text appears \(ranges.count) times on page \(number); "
            + "quote more of the passage so it names one place")
    }
    guard let selection = page.selection(for: range),
          let made = addPDFHighlights(for: selection, colour: colour, note: note, kind: kind).first
    else { throw PDFMarkError("PDFKit could not place a mark on that text") }
    try rewrite(document, to: url)
    return try reread(url, matching: made, on: number)
}

/// Changes a mark's note, colour, or both, and writes the file. `nil` leaves a field as is.
@discardableResult
public func editPDFMark(in url: URL, id: String, note: String? = nil,
                        colour: NSColor? = nil) throws -> PDFMark {
    let document = try openForMarking(url)
    let found = try mark(id, in: document)
    if let note { found.annotation.contents = note }
    if let colour { found.annotation.color = colour }
    found.annotation.modificationDate = Date()
    try rewrite(document, to: url)
    return try reread(url, matching: found.annotation, on: found.number)
}

/// Takes a mark off its page and writes the file. Returns the mark as it was.
@discardableResult
public func removePDFMark(from url: URL, id: String) throws -> PDFMark {
    let document = try openForMarking(url)
    let found = try mark(id, in: document)
    let before = pdfMark(found)
    found.page.removeAnnotation(found.annotation)
    try rewrite(document, to: url)
    return before
}

private func openForMarking(_ url: URL) throws -> PDFDocument {
    guard let document = PDFDocument(url: url) else {
        throw PDFMarkError("\(url.path) could not be opened as a PDF")
    }
    // Writing an encrypted document back out through PDFKit can drop its protection, and
    // that is not a side effect a highlight should have.
    guard !document.isEncrypted else {
        throw PDFMarkError("that PDF is encrypted; mark it in PaperShelf instead")
    }
    return document
}

private func mark(_ id: String, in document: PDFDocument) throws
    -> (page: PDFPage, number: Int, annotation: PDFAnnotation, id: String) {
    guard let found = editableMarks(in: document).first(where: { $0.id == id }) else {
        throw PDFMarkError("no mark with id \(id); call list_highlights for current ids")
    }
    return found
}

private func pdfMark(_ found: (page: PDFPage, number: Int, annotation: PDFAnnotation, id: String)) -> PDFMark {
    let annotation = found.annotation
    return PDFMark(page: found.number, kind: (annotation.type ?? "").lowercased(),
                   quoted: annotation.type == "Text" ? "" : quotedText(of: annotation, on: found.page),
                   note: annotation.contents ?? "", colour: annotationColour(annotation.color),
                   id: found.id, modified: annotation.modificationDate)
}

/// The mark as the file now holds it, so the id handed back is the one the next read uses.
private func reread(_ url: URL, matching annotation: PDFAnnotation, on number: Int) throws -> PDFMark {
    guard let document = PDFDocument(url: url) else { throw PDFMarkError("the file did not read back") }
    let type = annotation.type
    let box = annotation.bounds
    let candidates = editableMarks(in: document).filter {
        $0.number == number && $0.annotation.type == type
            && abs($0.annotation.bounds.minX - box.minX) < 0.5
            && abs($0.annotation.bounds.minY - box.minY) < 0.5
    }
    guard let found = candidates.first else { throw PDFMarkError("the mark did not read back") }
    return pdfMark(found)
}

/// Same temporary-file-then-replace write as the reader's own saves, so an interrupted
/// write never leaves half a document where the paper was. A reader showing the file sees
/// its date move and reads it again.
private func rewrite(_ document: PDFDocument, to url: URL) throws {
    guard let data = document.dataRepresentation() else {
        throw PDFMarkError("PDFKit could not serialize the document")
    }
    let temporary = url.deletingLastPathComponent()
        .appendingPathComponent(".papershelf-notes-\(UUID().uuidString).pdf")
    do {
        try data.write(to: temporary, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } catch {
        try? FileManager.default.removeItem(at: temporary)
        throw PDFMarkError("could not write \(url.lastPathComponent): \(error.localizedDescription)")
    }
}

/// UTF-16 ranges of `needle` in `haystack`, comparing only what a quote and a page agree
/// on: letters, digits and punctuation, case-folded, with ligatures spelled out and curly
/// quotes straightened. Spacing, line breaks and hyphens do not take part.
func matches(of needle: String, in haystack: String) -> [NSRange] {
    func folded(_ text: String) -> (keys: [Unicode.Scalar], spans: [NSRange]) {
        var keys: [Unicode.Scalar] = []
        var spans: [NSRange] = []
        var offset = 0
        for scalar in text.unicodeScalars {
            let width = String(scalar).utf16.count
            defer { offset += width }
            let skipped = CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: "-\u{00AD}\u{2010}\u{2011}"))
            guard !skipped.contains(scalar) else { continue }
            let spelled = String(scalar).precomposedStringWithCompatibilityMapping.lowercased()
            for key in spelled.unicodeScalars {
                let straight: Unicode.Scalar
                switch key {
                case "\u{2018}", "\u{2019}": straight = "'"
                case "\u{201C}", "\u{201D}": straight = "\""
                default: straight = key
                }
                keys.append(straight)
                spans.append(NSRange(location: offset, length: width))
            }
        }
        return (keys, spans)
    }
    let query = folded(needle).keys
    let page = folded(haystack)
    guard !query.isEmpty, query.count <= page.keys.count else { return [] }
    // ponytail: naive scan, quadratic in the worst case; a page is a few thousand
    // characters and a quote a few hundred, so this stays well under a millisecond.
    var found: [NSRange] = []
    var start = 0
    while start + query.count <= page.keys.count {
        if page.keys[start] == query[0], Array(page.keys[start..<start + query.count]) == query {
            let first = page.spans[start], last = page.spans[start + query.count - 1]
            found.append(NSRange(location: first.location,
                                 length: last.location + last.length - first.location))
            start += query.count
        } else {
            start += 1
        }
    }
    return found
}
