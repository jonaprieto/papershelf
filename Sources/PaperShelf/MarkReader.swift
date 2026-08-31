import Foundation
import AppKit
import PDFKit

/// The marks on a document nobody has opened.
///
/// Highlights live in the PDF, not in the library, so the notes panel could only list them
/// for the file the reader happened to have loaded: selecting a paper on the shelf got you
/// "open this document to see the passages marked in it" over a paper with nine highlights
/// in it. This reads the file instead.
///
/// Off the main actor, because parsing a couple of hundred pages is a tenth of a second and
/// the panel is redrawn on every arrow key. Cached by path and modification date, so
/// walking a shelf costs one read per document and none at all on the way back.
actor MarkReader {
    static let shared = MarkReader()

    /// What the panel needs to draw a row. Not `Annotator.Mark`: that one owns a live
    /// `PDFAnnotation` belonging to an open document, which is exactly what is missing here.
    struct Mark: Identifiable, Sendable, Equatable {
        let id: String
        let page: Int
        let quoted: String
        let note: String
        let colour: NSColor

        static func == (a: Mark, b: Mark) -> Bool {
            a.id == b.id && a.page == b.page && a.quoted == b.quoted && a.note == b.note
        }
    }

    private struct Entry {
        let modified: Date
        let size: Int
        let marks: [Mark]
    }

    private var cache: [String: Entry] = [:]
    /// Bounded, because a shelf can be walked for a long time and every entry holds the
    /// text of every highlight in a document.
    private let limit = 60

    func marks(in url: URL, passwords: [String] = []) -> [Mark] {
        let key = url.resolvingSymlinksInPath().path
        let stamp = Self.stamp(of: url)
        if let cached = cache[key], cached.modified == stamp.modified, cached.size == stamp.size {
            return cached.marks
        }
        let found = Self.read(url, passwords: passwords)
        if cache.count >= limit { cache.removeAll() }
        cache[key] = Entry(modified: stamp.modified, size: stamp.size, marks: found)
        return found
    }

    /// Forgets one document, for when the app itself has just written to it.
    func forget(_ url: URL) {
        cache[url.resolvingSymlinksInPath().path] = nil
    }

    /// Asked through `FileManager` rather than `URL.resourceValues`, which caches what it
    /// read the first time: with the URL as the cache key, a document rewritten under the
    /// same path went on reporting the size and date it had when the panel first saw it,
    /// and the marks added since were never read.
    private static func stamp(of url: URL) -> (modified: Date, size: Int) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ((attributes?[.modificationDate] as? Date) ?? .distantPast,
                (attributes?[.size] as? Int) ?? 0)
    }

    /// A file that cannot be read is a document with no marks, not an error: the panel has
    /// nothing useful to say about a volume that went away, and saying nothing is what an
    /// empty list already says.
    private static func read(_ url: URL, passwords: [String]) -> [Mark] {
        guard let document = PDFDocument(url: url) else { return [] }
        if document.isLocked {
            for password in passwords where document.unlock(withPassword: password) { break }
            guard !document.isLocked else { return [] }
        }
        var found: [Mark] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.type == "Highlight" {
                let quoted = page.selection(for: annotation.bounds)?.string?
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                found.append(Mark(id: "\(index)-\(Int(annotation.bounds.minY))-\(found.count)",
                                  page: index + 1,
                                  quoted: quoted,
                                  note: annotation.contents ?? "",
                                  colour: annotation.color))
            }
        }
        return found
    }
}
