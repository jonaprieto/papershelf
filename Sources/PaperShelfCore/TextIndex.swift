import Foundation
import PDFKit

/// Reading a document's text so it can be searched later.
///
/// `openingText` in BookGuess.swift answers a different question: what a model needs to
/// guess what a book is, which is the first few pages and no more. Search wants the body,
/// and wants it stored, so the disk is read once per file rather than once per query.
///
/// The cap is deliberate. A library of fourteen thousand books with no bound on stored
/// text is several gigabytes of SQLite, and the value of the tail is low: a phrase that
/// appears only past page thirty of one book is not what a shelf search is for. At a
/// hundred thousand characters a book contributes about thirty dense pages.
public let textIndexCharacterLimit = 100_000

/// The document's text, up to the cap.
///
/// Nil means the file could not be opened at all, which is a failure worth retrying when
/// the disk comes back. An empty string means the document opened and has no text layer,
/// which is a scan: a normal, permanent answer that should be stored so the file is not
/// read again on every launch.
public func documentText(of url: URL, passwords: [String],
                         limit: Int = textIndexCharacterLimit) -> String? {
    guard let document = PDFDocument(url: url) else { return nil }
    if document.isLocked {
        for password in passwords where document.unlock(withPassword: password) { break }
    }
    guard !document.isLocked else { return nil }
    var collected = ""
    collected.reserveCapacity(min(limit, 1 << 16))
    for index in 0..<document.pageCount {
        guard let text = document.page(at: index)?.string else { continue }
        collected += text
        collected += "\n"
        if collected.count >= limit { return String(collected.prefix(limit)) }
    }
    return collected
}

/// One file as the index sees it: where it is, which document it belongs to, and when its
/// text was last read.
public struct TextIndexRow: Sendable, Equatable {
    public let path: String
    public let documentID: String
    public let extractedAt: Date?

    public init(path: String, documentID: String, extractedAt: Date?) {
        self.path = path
        self.documentID = documentID
        self.extractedAt = extractedAt
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
