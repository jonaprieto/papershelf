import Foundation

// MARK: - Project documents
//
// A reading project's storage (the project itself, its member documents, tags) lives in
// Library.swift's SQLite store: `documents`, `projects`, `project_members`, `tags`. This
// file does not repeat that model or invent a second one: defining the type twice is the
// fastest way to end up with two incompatible ideas of what a project is. What lives
// here instead is the part that decides whether a project's answers are any good:
// stitching a question and the right slice of a project's extracted text into a prompt a
// model can cite from, and reading the citations back out.

/// One reading-project member document, reduced to what prompt assembly needs: enough to
/// identify and cite it, plus its extracted text. A caller builds this from a
/// `Library.DocumentRecord` after resolving a project's membership; nothing here reads a
/// database.
public struct ProjectDocument: Sendable, Equatable, Hashable {
    public let contentHash: String
    public let title: String
    /// Whole-document extracted text, tagged one page at a time as
    /// `<!-- page:N -->` immediately before that page's text (1-based, matching every
    /// other page number this app already shows: Annotations.swift's marks and table of
    /// contents are both 1-based). Text with no markers at all (a caller that has not
    /// adopted the convention yet) is treated as a single page 1, not dropped.
    public let markdown: String

    public init(contentHash: String, title: String, markdown: String) {
        self.contentHash = contentHash
        self.title = title
        self.markdown = markdown
    }
}

// MARK: - Chunking

/// A page-scoped slice of one document's extracted text, small enough to hand to a model
/// and precise enough to cite. A chunk never spans two pages: see `chunk(_:softLimit:)`.
public struct Excerpt: Sendable, Equatable, Identifiable {
    public let contentHash: String
    public let documentTitle: String
    public let page: Int
    public let body: String

    /// Not meaningful on its own, only stable enough for a SwiftUI `List`/`ForEach`.
    public var id: String { "\(contentHash)#\(page)#\(body.hashValue)" }

    public init(contentHash: String, documentTitle: String, page: Int, body: String) {
        self.contentHash = contentHash
        self.documentTitle = documentTitle
        self.page = page
        self.body = body
    }
}

private let pageMarker = try! NSRegularExpression(pattern: "<!--\\s*page:(\\d+)\\s*-->")

/// Splits page-tagged markdown into `(page, text)` pairs. Internal: `chunk(_:softLimit:)`
/// is the entry point everything else calls, this only exists so the splitting logic can
/// be tested on its own from `@testable import`.
func pages(of markdown: String) -> [(page: Int, text: String)] {
    guard !markdown.isEmpty else { return [] }
    let whole = markdown as NSString
    let matches = pageMarker.matches(in: markdown, range: NSRange(location: 0, length: whole.length))
    guard !matches.isEmpty else { return [(1, markdown.trimmingCharacters(in: .whitespacesAndNewlines))] }

    var found: [(Int, String)] = []
    for (index, match) in matches.enumerated() {
        guard let numberRange = Range(match.range(at: 1), in: markdown),
              let page = Int(markdown[numberRange]) else { continue }
        let start = match.range.location + match.range.length
        let end = index + 1 < matches.count ? matches[index + 1].range.location : whole.length
        guard end > start else { continue }
        let text = whole.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { found.append((page, text)) }
    }
    return found
}

/// Splits one document's extracted text into page-scoped chunks.
///
/// A chunk never spans two pages. That constraint is the entire mechanism by which a
/// citation stays honest: `readingProjectPrompt` labels each chunk with the literal page
/// it came from, and the model is only ever asked to copy that label back
/// (`readingProjectInstruction`), never to compute or remember a page number itself. A
/// chunk spanning two pages would make the label a guess.
///
/// A page under `softLimit` characters is kept whole, as one chunk: most pages of most
/// papers fit this. A longer page is split at paragraph (blank-line) boundaries and
/// paragraphs are packed greedily back up to `softLimit`, so a chunk is neither an entire
/// dense page nor a single throwaway-short paragraph. A single paragraph that alone
/// exceeds `softLimit` still becomes its own (oversized) chunk rather than being cut
/// mid-sentence: a quotation that stops mid-thought is worse than one that runs long.
public func chunk(_ document: ProjectDocument, softLimit: Int = 1_200) -> [Excerpt] {
    var excerpts: [Excerpt] = []
    for (page, text) in pages(of: document.markdown) {
        if text.count <= softLimit {
            excerpts.append(Excerpt(contentHash: document.contentHash, documentTitle: document.title,
                                    page: page, body: text))
            continue
        }
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var current = ""
        for paragraph in paragraphs {
            if current.isEmpty {
                current = paragraph
            } else if current.count + 2 + paragraph.count <= softLimit {
                current += "\n\n" + paragraph
            } else {
                excerpts.append(Excerpt(contentHash: document.contentHash, documentTitle: document.title,
                                        page: page, body: current))
                current = paragraph
            }
        }
        if !current.isEmpty {
            excerpts.append(Excerpt(contentHash: document.contentHash, documentTitle: document.title,
                                    page: page, body: current))
        }
    }
    return excerpts
}

/// `chunk(_:softLimit:)` over every document, in the order given.
public func chunk(_ documents: [ProjectDocument], softLimit: Int = 1_200) -> [Excerpt] {
    documents.flatMap { chunk($0, softLimit: softLimit) }
}

// MARK: - Selecting what to send

/// Picks which excerpts to send with a question, so a project is never pasted in blind
/// and never silently truncated mid-thought.
///
/// Two modes, chosen by whether the project already fits:
///
/// - **Full recall.** If every chunk from every member document together fits in
///   `budget` characters, all of them go, in document/page order. Retrieval is a
///   workaround for exceeding the budget, not a virtue on its own: a small project (a
///   handful of papers) should get the whole thing rather than a lossy guess at what
///   matters, and full recall also means "the excerpts don't contain the answer" (the
///   instruction's own escape hatch) is a real finding, not an artifact of a search
///   missing the right words.
/// - **Ranked retrieval.** Otherwise, `rankedDocuments` is asked which of the project's
///   own documents best match the question. This is expected to be backed by
///   `Library.fullTextSearch` (FTS5 + bm25 over `documents.markdown`), deliberately not
///   reimplemented here, since the Library already has a real full-text index over
///   extracted text and building a second one in Swift would be exactly the kind of
///   redundant machinery this app avoids. Because that index ranks whole documents, not
///   chunks (Library.swift carries no per-chunk index in this design), documents are
///   walked best-first and each one's own chunks are packed in page order, favouring a
///   coherent read of the most relevant document over an arbitrary jump between page
///   numbers, until the budget is spent. A document the search does not surface at all
///   still belongs to the project, so it is kept, just last. A chunk that would overflow
///   the remaining budget is skipped, never truncated, for the same reason chunks don't
///   span pages: a citation promises the quoted text is genuinely, wholly, on that page.
public func selectExcerpts(
    question: String,
    documents: [ProjectDocument],
    budget: Int = 12_000,
    softLimit: Int = 1_200,
    rankedDocuments: (_ question: String, _ contentHashes: [String]) async throws -> [String]
) async throws -> [Excerpt] {
    let byHash = Dictionary(uniqueKeysWithValues: documents.map { ($0.contentHash, $0) })
    let allChunks = chunk(documents, softLimit: softLimit)
    guard allChunks.reduce(0, { $0 + $1.body.count }) > budget else { return allChunks }

    var order = try await rankedDocuments(question, documents.map(\.contentHash))
        .filter { byHash[$0] != nil }
    for hash in documents.map(\.contentHash) where !order.contains(hash) {
        order.append(hash)
    }

    var selected: [Excerpt] = []
    var used = 0
    for hash in order {
        guard let document = byHash[hash] else { continue }
        for excerpt in chunk(document, softLimit: softLimit) {
            guard used + excerpt.body.count <= budget else { continue }
            selected.append(excerpt)
            used += excerpt.body.count
        }
    }
    return selected
}

// MARK: - Prompting
//
// Mirrors BookGuess.swift's established shape for talking to a model: a blunt system
// message with an explicit output contract and an explicit anti-hallucination sentence,
// and a structured user message with labelled sections and an explicit empty-case
// placeholder. The one addition a citation feature needs beyond that precedent is telling
// the model exactly what a citation must look like, and putting each excerpt's citation
// label immediately above its own text; see the comment on `readingProjectPrompt`.

/// System message. An answer with no citation is worth much less than one that names its
/// source, so the citation format is not a suggestion here, it is the deliverable.
public let readingProjectInstruction = """
You answer questions using only the excerpts provided below, drawn from the user's own PDF library.
Every claim you make must be followed by a citation in the form (Title, p. N), naming the exact \
page the excerpt came from. If the excerpts do not contain the answer, say so plainly instead of \
guessing or using outside knowledge. Never invent a page number, a title, or a quotation that is \
not present in what follows.
"""

/// User message: the question, then one labelled block per excerpt naming the document
/// and the literal page it came from, immediately above that excerpt's own text.
///
/// That placement is the actual citation mechanism, not just formatting: the model is
/// never asked to remember or compute a page number, only to copy back the label already
/// sitting right next to the text it used. `parseCitations` then only has to find that
/// same label shape in the reply, not verify a number the model made up.
public func readingProjectPrompt(question: String, projectName: String, excerpts: [Excerpt]) -> String {
    let documentCount = Set(excerpts.map(\.contentHash)).count
    var out = "Question: \(question)\n\n"
    out += "Excerpts from \"\(projectName)\" (\(documentCount) document\(documentCount == 1 ? "" : "s"), "
    out += "\(excerpts.count) excerpt\(excerpts.count == 1 ? "" : "s")):\n\n"
    guard !excerpts.isEmpty else {
        return out + "(none of the project's documents matched this question)"
    }
    for excerpt in excerpts {
        out += "--- \(excerpt.documentTitle), p. \(excerpt.page) ---\n\(excerpt.body)\n\n"
    }
    return out
}

// MARK: - Reading citations back

/// One citation the model made, resolved back to the excerpt it most likely names: the
/// reply only ever names a title and a page, never a content hash, so resolving it means
/// finding which excerpt actually carried that label.
public struct Citation: Sendable, Equatable {
    public let documentTitle: String
    public let page: Int
    /// `nil` when no excerpt sent matches this citation's title: the model wrote
    /// something that was not actually offered to it, which is worth surfacing rather
    /// than silently linking to the wrong document.
    public let contentHash: String?
    /// Where in the reply text this citation sits, so an interface can turn just that
    /// span into a link instead of the whole answer.
    public let range: Range<String.Index>

    public init(documentTitle: String, page: Int, contentHash: String?, range: Range<String.Index>) {
        self.documentTitle = documentTitle
        self.page = page
        self.contentHash = contentHash
        self.range = range
    }
}

/// One numbered source under an answer: the number the marks in the text carry, and the
/// citation it points at.
public struct NumberedCitation: Equatable, Sendable, Identifiable {
    public let number: Int
    public let citation: Citation
    public var id: Int { number }

    public init(number: Int, citation: Citation) {
        self.number = number
        self.citation = citation
    }
}

/// A reply as it should be drawn: runs of text with numbered marks where the citations sit.
public enum ReplyPiece: Equatable, Sendable {
    case text(String)
    case mark(Int)
}

/// The distinct sources an answer leans on, numbered in the order they are first referred
/// to.
///
/// Distinct by document and page: the same page cited twice in one answer is one source
/// with one number, not two entries saying the same thing.
public func numberedCitations(_ citations: [Citation]) -> [NumberedCitation] {
    var seen: [String: Int] = [:]
    var out: [NumberedCitation] = []
    for citation in citations.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
        let key = "\(citation.documentTitle.lowercased())#\(citation.page)"
        guard seen[key] == nil else { continue }
        seen[key] = out.count + 1
        out.append(NumberedCitation(number: out.count + 1, citation: citation))
    }
    return out
}

/// Breaks a reply into text and numbered marks, replacing each written-out "(Title, p. N)"
/// with the number of the source it names.
///
/// A model writes its citations into the prose, which reads as clutter in the middle of a
/// sentence and takes up the room an answer needs. The marks say the same thing in one
/// character and point at the list underneath.
///
/// Concatenating the text pieces and the citation spans reproduces the reply exactly, so
/// nothing an answer said can be dropped on the way to the screen.
public func replyPieces(_ reply: String, citations: [Citation]) -> [ReplyPiece] {
    let numbers = numberedCitations(citations)
    guard !numbers.isEmpty else { return reply.isEmpty ? [] : [.text(reply)] }

    var numberFor: [String: Int] = [:]
    for entry in numbers {
        numberFor["\(entry.citation.documentTitle.lowercased())#\(entry.citation.page)"] = entry.number
    }

    // Sorted and non-overlapping: a model can cite the same span twice, and two marks
    // over one range would take a bite out of the text between them.
    var spans: [(Range<String.Index>, Int)] = []
    for citation in citations.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
        let key = "\(citation.documentTitle.lowercased())#\(citation.page)"
        guard let number = numberFor[key] else { continue }
        if let last = spans.last, citation.range.lowerBound < last.0.upperBound { continue }
        guard citation.range.lowerBound >= reply.startIndex,
              citation.range.upperBound <= reply.endIndex else { continue }
        spans.append((citation.range, number))
    }

    var pieces: [ReplyPiece] = []
    var cursor = reply.startIndex
    for (range, number) in spans {
        if cursor < range.lowerBound {
            pieces.append(.text(String(reply[cursor..<range.lowerBound])))
        }
        pieces.append(.mark(number))
        cursor = range.upperBound
    }
    if cursor < reply.endIndex {
        pieces.append(.text(String(reply[cursor...])))
    }
    return pieces
}

private let citationPattern = try! NSRegularExpression(pattern: "\\(([^()]+?),\\s*p\\.\\s*(\\d+)\\)")

/// Pulls "(Title, p. N)" citations back out of a reply.
///
/// Matched by title first (case-insensitive: a model paraphrases case more often than it
/// invents a title outright), then narrowed by page when more than one excerpt shares
/// that title, so a title that appears on several pages still resolves to the specific
/// page the model actually named, not just the first excerpt with a matching title.
public func parseCitations(in reply: String, excerpts: [Excerpt]) -> [Citation] {
    let whole = reply as NSString
    let matches = citationPattern.matches(in: reply, range: NSRange(location: 0, length: whole.length))
    return matches.compactMap { match -> Citation? in
        guard let range = Range(match.range, in: reply),
              let titleRange = Range(match.range(at: 1), in: reply),
              let pageRange = Range(match.range(at: 2), in: reply),
              let page = Int(reply[pageRange]) else { return nil }
        let title = reply[titleRange].trimmingCharacters(in: .whitespaces)
        let candidates = excerpts.filter { $0.documentTitle.caseInsensitiveCompare(title) == .orderedSame }
        let hash = candidates.first { $0.page == page }?.contentHash ?? candidates.first?.contentHash
        return Citation(documentTitle: title, page: page, contentHash: hash, range: range)
    }
}

// MARK: - Privacy: what is about to leave the machine
//
// Today the only AI call in the app (`AIClient.identify`) sends at most ~1800 characters
// from three pages of one file, only when the user explicitly asks to identify it. A
// project question can send the whole extracted text of every member document, to
// whatever OpenAI-compatible endpoint is configured, and the app accepts a plain http://
// endpoint exactly like an https:// one. This is a materially different amount of
// exposure, and it must be shown, in plain terms, before it happens: every time a
// question is sent, not once behind a setting someone ticks and forgets.

/// The endpoint every install starts with (`SettingsView.swift`'s own default). Kept here
/// rather than imported from the app target, since Core has no dependency on PaperShelf
/// and "not the default" needs something to compare against.
public let defaultAIEndpoint = "https://api.openai.com/v1"

/// What is about to leave the machine, in the terms a person actually judges: how many
/// documents, roughly how many characters, and to which endpoint by name.
public struct OutboundPreview: Sendable, Equatable {
    public let documentCount: Int
    public let approximateCharacterCount: Int
    /// The host name to show, e.g. "api.openai.com", never the full URL with any path
    /// or query a custom endpoint might carry.
    public let endpointHost: String
    /// False for anything other than the exact default endpoint string, including the
    /// same host reached over plain `http://`: that is a materially weaker promise even
    /// though it "looks like" the same place.
    public let isDefaultEndpoint: Bool
    /// True when the endpoint is reachable over plain HTTP, so the excerpts cross the
    /// network readable by anything on the path, not only the destination.
    public let isPlaintext: Bool

    public init(documentCount: Int, approximateCharacterCount: Int, endpointHost: String,
                isDefaultEndpoint: Bool, isPlaintext: Bool) {
        self.documentCount = documentCount
        self.approximateCharacterCount = approximateCharacterCount
        self.endpointHost = endpointHost
        self.isDefaultEndpoint = isDefaultEndpoint
        self.isPlaintext = isPlaintext
    }
}

/// Builds the preview a confirmation dialog shows before `excerpts` are sent to `endpoint`.
public func outboundPreview(excerpts: [Excerpt], endpoint: String) -> OutboundPreview {
    let trimmed = endpoint.trimmingCharacters(in: .whitespaces)
    let url = URL(string: trimmed)
    return OutboundPreview(
        documentCount: Set(excerpts.map(\.contentHash)).count,
        approximateCharacterCount: excerpts.reduce(0) { $0 + $1.body.count },
        endpointHost: url?.host ?? trimmed,
        isDefaultEndpoint: trimmed == defaultAIEndpoint,
        isPlaintext: (url?.scheme?.lowercased() ?? "") == "http")
}
