import Foundation
import PDFKit

/// Reading a document's text so it can be searched later.
///
/// `openingText` in BookGuess.swift answers a different question: what a model needs to
/// guess what a book is, which is the first few pages and no more. Search wants the body,
/// and wants it stored, so the disk is read once per file rather than once per query.
///
/// The cap is deliberate. A library of fourteen thousand books with no bound on stored
/// text is tens of gigabytes of SQLite, and a five-thousand-page scan would be a
/// single row of it. Two million characters is a whole book for anything real: a
/// four-hundred-page book is about eight hundred thousand.
public let textIndexCharacterLimit = 2_000_000

/// What shape a stored row is in. Absent, on a row written before this existed, means
/// text with no page markers and a far lower cap, which is stale by definition.
public enum TextFormat: String, Sendable, Equatable {
    case markdown = "markdown-v1"
    case clipped = "markdown-v1-clipped"
}

/// The document's text as page-marked Markdown, up to the cap.
///
/// Nil means the file could not be opened, or is locked and no password given fits, which
/// is worth trying again when the disk or the password comes back. An empty string means
/// the document opened and has no text layer, which is a scan: a normal, permanent answer
/// that should be stored so the file is not read again on every launch. That pair of
/// answers is the reason this is not `markdownFromPDF`, which returns its title heading
/// and nothing else in both cases and cannot be told apart.
///
/// No title heading, no paragraph joining and no Markdown escaping either, unlike
/// `markdownFromPDF`: this text exists to be matched against and quoted from, and escaping
/// changes the characters a quote would be taken from. The page markers are the one piece
/// of structure worth adding, because they are the only way a search result can say which
/// page it found something on.
public func indexedMarkdown(of url: URL, passwords: [String],
                            limit: Int = textIndexCharacterLimit) -> (text: String, format: TextFormat)? {
    guard let document = PDFDocument(url: url) else { return nil }
    if document.isLocked {
        for password in passwords where document.unlock(withPassword: password) { break }
    }
    guard !document.isLocked else { return nil }
    var collected = ""
    collected.reserveCapacity(min(limit, 1 << 16))
    for index in 0..<document.pageCount {
        guard let text = document.page(at: index)?.string, !text.isEmpty else { continue }
        collected += "## Page \(index + 1)\n\n"
        collected += text
        collected += "\n\n"
        if collected.count >= limit {
            return (String(collected.prefix(limit)), .clipped)
        }
    }
    return (collected, .markdown)
}

/// One file as the index sees it: where it is, which document it belongs to, and when its
/// text was last read.
public struct TextIndexRow: Sendable, Equatable {
    public let path: String
    public let documentID: String
    public let extractedAt: Date?
    /// Nil for text stored before page markers existed, which is what makes it stale.
    public let format: TextFormat?

    public init(path: String, documentID: String, extractedAt: Date?, format: TextFormat? = nil) {
        self.path = path
        self.documentID = documentID
        self.extractedAt = extractedAt
        self.format = format
    }
}

/// Whether this file's text has to be read again.
///
/// Never read: yes. Read before the file was last written: yes, the text on record is of
/// a document that no longer exists. Read after: no, and a file with no modification date
/// is left alone rather than re-read on every pass on the strength of a missing fact.
public func needsIndexing(extractedAt: Date?, fileModified: Date?) -> Bool {
    guard let extractedAt else { return true }
    guard let fileModified else { return false }
    return fileModified > extractedAt
}

/// As `needsIndexing(extractedAt:fileModified:)`, plus the one thing a file date cannot
/// answer: text stored by a producer that predates page markers is stale however recently
/// it was written.
public func needsIndexing(extractedAt: Date?, fileModified: Date?, format: TextFormat?) -> Bool {
    guard format != nil else { return true }
    return needsIndexing(extractedAt: extractedAt, fileModified: fileModified)
}
