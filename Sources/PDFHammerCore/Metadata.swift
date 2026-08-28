import Foundation

// MARK: - Transport injection

/// Mirrors `URLSession.shared.data(for:)` exactly, so wiring this to the network in the App
/// target is a one-liner. Every lookup below takes one of these instead of reaching for
/// `URLSession` itself, so a test can hand it a stub and never touch a socket: a test suite
/// that fails on a train is a broken test suite.
public typealias HTTPFetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

public enum MetadataError: Error, Sendable, Equatable {
    case badURL
    case http(Int)
    case unreadable
    case notFound
}

public enum MetadataSource: String, Sendable, CaseIterable, Identifiable, Equatable {
    case doi, crossref, arxiv, openLibrary
    public var id: String { rawValue }
}

/// Identifies this app to a service being asked for data, plus a contact address when the
/// caller has one. Crossref's polite pool and Open Library's identified-request bump both
/// key off a real User-Agent; a service with nobody to notice a spike in traffic from is the
/// one that ends up throttling everybody.
public func userAgent(contact: String? = nil) -> String {
    let base = "PDFHammer/1.1.0 (https://github.com/jonaprieto/pdf-hammer)"
    guard let contact, !contact.isEmpty else { return base }
    return base + "; mailto:\(contact)"
}

private let requestTimeout: TimeInterval = 15

// MARK: - DOI content negotiation

/// The shape doi.org's content negotiation actually returns for
/// `Accept: application/vnd.citationstyles.csl+json`: title and container-title come back
/// as plain strings here, unlike Crossref's own REST API, where the same fields are arrays
/// (see CrossrefWork below). Verified live for both a Crossref DOI and a DataCite DOI, so
/// this is the registrar-agnostic path: it works for a DOI from any agency doi.org fronts,
/// not only Crossref's, which is why it is the identifier-lookup path rather than Crossref's
/// own `/works/{doi}`.
public struct CSLWork: Sendable, Equatable, Decodable {
    public struct Author: Sendable, Equatable, Decodable {
        public var given: String?
        public var family: String?
    }
    public struct Issued: Sendable, Equatable, Decodable {
        public var dateParts: [[Int]]?
        enum CodingKeys: String, CodingKey { case dateParts = "date-parts" }
    }
    public var type: String?
    public var title: String?
    public var containerTitle: String?
    public var author: [Author]?
    public var issued: Issued?
    public var doi: String?
    public var publisher: String?
    public var volume: String?
    public var page: String?
    public var url: String?

    enum CodingKeys: String, CodingKey {
        case type, title, author, issued, publisher, volume, page, url
        case containerTitle = "container-title"
        case doi = "DOI"
    }
}

public func doiRequest(doi: String, contact: String? = nil,
                       accept: String = "application/vnd.citationstyles.csl+json") -> URLRequest? {
    guard let url = URL(string: "https://doi.org/" + doi) else { return nil }
    var request = URLRequest(url: url, timeoutInterval: requestTimeout)
    request.setValue(accept, forHTTPHeaderField: "Accept")
    request.setValue(userAgent(contact: contact), forHTTPHeaderField: "User-Agent")
    return request
}

public func parseCSLWork(_ data: Data) -> CSLWork? {
    try? JSONDecoder().decode(CSLWork.self, from: data)
}

/// doi.org itself publishes no rate limit; the registries it redirects to do. Crossref
/// calls a `mailto`-identified caller the "polite pool" and uses 50 requests/second as its
/// own illustrative figure (the live `x-rate-limit-limit`/`x-rate-limit-interval` headers on
/// a given response are the actual number); DataCite documents no fixed figure at all.
/// `contact` is threaded through regardless, since it can only help.
public func fetchDOI(_ doi: String, contact: String? = nil, fetch: HTTPFetch) async throws -> CSLWork {
    guard let request = doiRequest(doi: doi, contact: contact) else { throw MetadataError.badURL }
    let (data, response) = try await fetch(request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else { throw code == 404 ? MetadataError.notFound : MetadataError.http(code) }
    guard let work = parseCSLWork(data) else { throw MetadataError.unreadable }
    return work
}

// MARK: - Crossref bibliographic search (the fallback when there is no identifier at all)

/// The shape Crossref's own REST API returns: title and container-title are ARRAYS here,
/// unlike the scalar strings doi.org's csl+json negotiation gives for the identical
/// underlying record (see CSLWork above) -- two different JSON shapes for the same
/// bibliographic fact, depending on which URL is asked.
public struct CrossrefWork: Sendable, Equatable, Decodable {
    public struct Author: Sendable, Equatable, Decodable {
        public var given: String?
        public var family: String?
    }
    public struct Issued: Sendable, Equatable, Decodable {
        public var dateParts: [[Int]]?
        enum CodingKeys: String, CodingKey { case dateParts = "date-parts" }
    }
    public var doi: String
    public var type: String
    public var title: [String]
    public var containerTitle: [String]?
    public var author: [Author]?
    public var issued: Issued?
    public var volume: String?
    public var issue: String?
    public var page: String?
    public var publisher: String?
    public var issn: [String]?

    enum CodingKeys: String, CodingKey {
        case type, title, author, issued, volume, issue, page, publisher
        case doi = "DOI"
        case containerTitle = "container-title"
        case issn = "ISSN"
    }
}

/// `GET /works?query.bibliographic=<text>`, Crossref's own relevance ranking over a free
/// text title/author query; used only once a document carries no DOI or arXiv id to look
/// up directly.
public func crossrefSearchURL(bibliographic query: String, rows: Int = 5, contact: String? = nil) -> URL? {
    var components = URLComponents(string: "https://api.crossref.org/works")
    var items = [
        URLQueryItem(name: "query.bibliographic", value: query),
        URLQueryItem(name: "rows", value: String(rows)),
    ]
    if let contact, !contact.isEmpty { items.append(URLQueryItem(name: "mailto", value: contact)) }
    components?.queryItems = items
    return components?.url
}

public func parseCrossrefSearch(_ data: Data) -> [CrossrefWork] {
    struct Envelope: Decodable {
        struct Message: Decodable { var items: [CrossrefWork] }
        var message: Message
    }
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return [] }
    return envelope.message.items
}

/// Same polite-pool etiquette as fetchDOI: a `mailto` on the query, and again in the
/// User-Agent, moves the request to Crossref's better-served pool.
public func searchCrossref(bibliographic query: String, contact: String? = nil,
                           fetch: HTTPFetch) async throws -> [CrossrefWork] {
    guard let url = crossrefSearchURL(bibliographic: query, contact: contact) else { throw MetadataError.badURL }
    var request = URLRequest(url: url, timeoutInterval: requestTimeout)
    request.setValue(userAgent(contact: contact), forHTTPHeaderField: "User-Agent")
    let (data, response) = try await fetch(request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else { throw MetadataError.http(code) }
    return parseCrossrefSearch(data)
}

/// Crossref's `type` vocabulary (30 values, `GET /types`) mapped down to this app's existing
/// BibType. Nothing here has an `.inproceedings` case yet, so a conference paper
/// (`proceedings-article`) is treated as `.article` and a chapter (`book-chapter` and its
/// relatives) as `.inbook`: the closest existing fit, not an exact one. Anything not listed
/// falls to `.misc` rather than a wrong specific guess.
public func bibType(forCrossrefType type: String) -> BibType {
    switch type {
    case "journal-article", "proceedings-article", "peer-review", "posted-content", "dissertation":
        return .article
    case "book", "monograph", "edited-book", "reference-book":
        return .book
    case "book-chapter", "book-section", "book-part", "book-track", "reference-entry":
        return .inbook
    case "report", "report-component", "report-series", "standard":
        return .report
    default:
        return .misc
    }
}

// MARK: - arXiv (Atom over XMLDocument, no third-party XML library needed)

public struct ArxivEntry: Sendable, Equatable {
    /// Bare id, e.g. "1706.03762" or "hep-th/9711200"; version stripped.
    public var id: String
    public var version: Int?
    public var title: String
    /// "Given Family" exactly as arXiv prints it, unsplit: arXiv never separates the two.
    public var authors: [String]
    public var summary: String
    public var primaryCategory: String?
    public var categories: [String]
    /// ISO 8601, left as arXiv sends it rather than parsed into a Date.
    public var published: String?
    public var comment: String?
    /// Present only once a preprint is formally published (`<arxiv:doi>`).
    public var doi: String?
    public var journalRef: String?
}

public func arxivIDLookupURL(id: String) -> URL? {
    var components = URLComponents(string: "https://export.arxiv.org/api/query")
    components?.queryItems = [URLQueryItem(name: "id_list", value: id)]
    return components?.url
}

/// Quoted so arXiv treats the title as one phrase, not separate terms to OR together. Per
/// arXiv's own manual, `id_list` is the correct way to fetch a *known* id and version; this
/// is only for the case where no id is known yet.
public func arxivTitleSearchURL(title: String, maxResults: Int = 5) -> URL? {
    var components = URLComponents(string: "https://export.arxiv.org/api/query")
    components?.queryItems = [
        URLQueryItem(name: "search_query", value: #"ti:"\#(title)""#),
        URLQueryItem(name: "max_results", value: String(maxResults)),
    ]
    return components?.url
}

/// Every arXiv `<id>` is stamped with the version it was fetched at
/// (".../abs/1706.03762v7"); everything downstream keys on the bare id, so the version is
/// split off here, once, rather than at every call site.
private func splitVersion(fromAbsID absID: String) -> (id: String, version: Int?) {
    guard let vIndex = absID.range(of: "v", options: .backwards) else { return (absID, nil) }
    let suffix = absID[vIndex.upperBound...]
    guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber), let version = Int(suffix) else { return (absID, nil) }
    return (String(absID[absID.startIndex..<vIndex.lowerBound]), version)
}

/// Matches by local name so the default Atom namespace and the `arxiv:` extension namespace
/// both resolve without registering either prefix by hand. A malformed or truncated feed
/// (or plain garbage) yields an empty array rather than throwing: nothing here force-unwraps
/// what arrived over the network.
public func parseArxivFeed(_ data: Data) -> [ArxivEntry] {
    guard let document = try? XMLDocument(data: data, options: []) else { return [] }
    guard let entryNodes = try? document.nodes(forXPath: "//*[local-name()='entry']") else { return [] }

    func text(_ node: XMLNode?) -> String {
        (node?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func optionalText(_ node: XMLNode?) -> String? {
        let value = text(node)
        return value.isEmpty ? nil : value
    }
    func firstChild(_ node: XMLNode, _ name: String) -> XMLNode? {
        (try? node.nodes(forXPath: "./*[local-name()='\(name)']"))?.first
    }
    func attribute(_ node: XMLNode?, _ name: String) -> String? {
        (node as? XMLElement)?.attribute(forName: name)?.stringValue
    }

    return entryNodes.compactMap { entry -> ArxivEntry? in
        let rawID = text(firstChild(entry, "id"))
        guard let absRange = rawID.range(of: "abs/") else { return nil }
        let title = text(firstChild(entry, "title"))
        guard !title.isEmpty else { return nil }

        let (id, version) = splitVersion(fromAbsID: String(rawID[absRange.upperBound...]))
        let authors = ((try? entry.nodes(forXPath: "./*[local-name()='author']/*[local-name()='name']")) ?? [])
            .map(text)
        let categoryNodes = (try? entry.nodes(forXPath: "./*[local-name()='category']")) ?? []

        return ArxivEntry(
            id: id,
            version: version,
            title: title,
            authors: authors,
            summary: text(firstChild(entry, "summary")),
            primaryCategory: attribute(firstChild(entry, "primary_category"), "term"),
            categories: categoryNodes.compactMap { attribute($0, "term") },
            published: optionalText(firstChild(entry, "published")),
            comment: optionalText(firstChild(entry, "comment")),
            doi: optionalText(firstChild(entry, "doi")),
            journalRef: optionalText(firstChild(entry, "journal_ref"))
        )
    }
}

public func fetchArxivEntry(id: String, fetch: HTTPFetch) async throws -> ArxivEntry? {
    guard let url = arxivIDLookupURL(id: id) else { throw MetadataError.badURL }
    var request = URLRequest(url: url, timeoutInterval: requestTimeout)
    request.setValue(userAgent(), forHTTPHeaderField: "User-Agent")
    let (data, response) = try await fetch(request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else { throw MetadataError.http(code) }
    return parseArxivFeed(data).first
}

/// arXiv's own etiquette asks for a 3 second gap between successive calls; this issues one
/// request and leaves any pacing between repeated calls to the caller, which is where the
/// app's actual call pattern lives.
public func searchArxiv(title: String, fetch: HTTPFetch) async throws -> [ArxivEntry] {
    guard let url = arxivTitleSearchURL(title: title) else { throw MetadataError.badURL }
    var request = URLRequest(url: url, timeoutInterval: requestTimeout)
    request.setValue(userAgent(), forHTTPHeaderField: "User-Agent")
    let (data, response) = try await fetch(request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else { throw MetadataError.http(code) }
    return parseArxivFeed(data)
}

// MARK: - Open Library (ISBN -> @book fields)

public struct OpenLibraryBook: Sendable, Equatable {
    public var title: String
    public var subtitle: String?
    public var authors: [String]
    public var publisher: String?
    public var publishDate: String?
    public var isbn10: String?
    public var isbn13: String?
}

/// `jscmd=data` resolves author names inline; the newer `/isbn/{isbn}.json` endpoint only
/// gives author keys, needing one further request per author, so this is the one-round-trip
/// choice for filling in a @book entry.
public func openLibraryISBNURL(isbn: String) -> URL? {
    var components = URLComponents(string: "https://openlibrary.org/api/books")
    components?.queryItems = [
        URLQueryItem(name: "bibkeys", value: "ISBN:\(isbn)"),
        URLQueryItem(name: "format", value: "json"),
        URLQueryItem(name: "jscmd", value: "data"),
    ]
    return components?.url
}

/// The response is keyed by the bibkey that was asked for (`"ISBN:0201558025": {...}`), so
/// the isbn used to build the request is needed again here to read the answer back out.
/// Every step is a conditional cast rather than a force-unwrap, since this is parsing
/// whatever the network actually sent back.
public func parseOpenLibraryBook(_ data: Data, isbn: String) -> OpenLibraryBook? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let record = object["ISBN:\(isbn)"] as? [String: Any],
          let title = record["title"] as? String, !title.isEmpty
    else { return nil }

    let authors = (record["authors"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
    let publishers = (record["publishers"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
    let identifiers = record["identifiers"] as? [String: Any]
    func firstIdentifier(_ key: String) -> String? {
        (identifiers?[key] as? [Any])?.compactMap { $0 as? String }.first
    }

    return OpenLibraryBook(
        title: title,
        subtitle: record["subtitle"] as? String,
        authors: authors,
        publisher: publishers.first,
        publishDate: record["publish_date"] as? String,
        isbn10: firstIdentifier("isbn_10"),
        isbn13: firstIdentifier("isbn_13")
    )
}

/// Open Library's own published limit: 1 request/second for an anonymous caller, 3x that
/// for one that identifies itself with a real User-Agent naming the app and a contact.
/// There is no query parameter for this, unlike Crossref's `mailto`; it lives entirely in
/// the header.
public func fetchOpenLibraryBook(isbn: String, contact: String? = nil,
                                 fetch: HTTPFetch) async throws -> OpenLibraryBook? {
    guard let url = openLibraryISBNURL(isbn: isbn) else { throw MetadataError.badURL }
    var request = URLRequest(url: url, timeoutInterval: requestTimeout)
    request.setValue(userAgent(contact: contact), forHTTPHeaderField: "User-Agent")
    let (data, response) = try await fetch(request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else { throw MetadataError.http(code) }
    return parseOpenLibraryBook(data, isbn: isbn)
}

// MARK: - Extraction from PDF first-page text

private func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
}

/// Crossref's own recommended pattern (crossref.org/blog/dois-and-matching-regular-expressions),
/// matched case-insensitively the way Crossref itself specifies (a trailing `/i`). Known
/// caveat, reproduced deliberately rather than patched over: a trailing `.`, `:` or `;` left
/// by page layout gets swallowed into the match. Crossref's own blog calls this open bycatch,
/// not a bug with a known fix, so this does not invent one either.
public let doiExtractionPattern = #"10\.\d{4,9}/[-._;()/:A-Z0-9]+"#
public let arxivNewIDPattern = #"arXiv:(\d{4}\.\d{4,5})(v\d+)?"#
public let arxivOldIDPattern = #"arXiv:([a-zA-Z-]+(?:\.[A-Z]{2})?/\d{7})(v\d+)?"#

private let doiRegex = regex(doiExtractionPattern, caseInsensitive: true)
private let arxivNewRegex = regex(arxivNewIDPattern)
private let arxivOldRegex = regex(arxivOldIDPattern)

/// The first thing on a PDF's opening page shaped like a DOI. A first page is full of things
/// that only look like one: a price, a version string, a decimal measurement with a unit
/// after the slash. This is a syntactic match, not proof the identifier is real; a caller
/// that needs to know looks it up and sees whether anything answers.
public func extractDOI(from text: String) -> String? {
    let ns = text as NSString
    guard let match = doiRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
    else { return nil }
    return ns.substring(with: match.range)
}

/// Tries the post-April-2007 scheme first (YYMM.NNNN[N]), then the pre-2007
/// archive[.subject-class]/YYMMNNN scheme. Either way the version suffix is dropped: every
/// lookup above wants the bare id.
public func extractArxivID(from text: String) -> String? {
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)
    if let match = arxivNewRegex.firstMatch(in: text, range: full) {
        return ns.substring(with: match.range(at: 1))
    }
    if let match = arxivOldRegex.firstMatch(in: text, range: full) {
        return ns.substring(with: match.range(at: 1))
    }
    return nil
}

/// A four-digit year, wherever it sits inside a free-text date. Open Library's `publish_date`
/// is not a fixed format: "1994", "December 27, 2017" and "March 1996" all occur in practice.
private let yearRegex = regex(#"(19|20)[0-9]{2}"#)

private func extractYear(from text: String) -> String? {
    let ns = text as NSString
    guard let match = yearRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
    else { return nil }
    return ns.substring(with: match.range)
}

// MARK: - Normalization

/// One source's answer, reshaped to the fields a BibEntry actually needs, so
/// `mergeMetadata` can compare five different response shapes field by field instead of
/// pattern-matching on which struct it is holding.
public struct NormalizedMetadata: Sendable, Equatable {
    public var source: MetadataSource
    public var title: String?
    /// "Given Family", author order preserved.
    public var authors: [String]
    public var year: String?
    public var doi: String?
    public var arxivID: String?
    /// Only ever set by arXiv.
    public var primaryClass: String?
    /// Journal or proceedings name.
    public var container: String?
    public var volume: String?
    /// Issue number.
    public var number: String?
    public var pages: String?
    public var publisher: String?
    public var isbn: String?
    public var type: BibType

    public init(source: MetadataSource, title: String? = nil, authors: [String] = [], year: String? = nil,
               doi: String? = nil, arxivID: String? = nil, primaryClass: String? = nil, container: String? = nil,
               volume: String? = nil, number: String? = nil, pages: String? = nil, publisher: String? = nil,
               isbn: String? = nil, type: BibType = .misc) {
        self.source = source
        self.title = title
        self.authors = authors
        self.year = year
        self.doi = doi
        self.arxivID = arxivID
        self.primaryClass = primaryClass
        self.container = container
        self.volume = volume
        self.number = number
        self.pages = pages
        self.publisher = publisher
        self.isbn = isbn
        self.type = type
    }
}

private func fullName(given: String?, family: String?) -> String? {
    let parts = [given, family].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
}

private func year(fromDateParts dateParts: [[Int]]?) -> String? {
    guard let first = dateParts?.first?.first else { return nil }
    return String(first)
}

public extension CSLWork {
    func normalized() -> NormalizedMetadata {
        NormalizedMetadata(
            source: .doi,
            title: title,
            authors: (author ?? []).compactMap { fullName(given: $0.given, family: $0.family) },
            year: year(fromDateParts: issued?.dateParts),
            doi: doi,
            container: containerTitle,
            volume: volume,
            pages: page,
            publisher: publisher,
            type: type.map(bibType(forCrossrefType:)) ?? .misc
        )
    }
}

public extension CrossrefWork {
    func normalized() -> NormalizedMetadata {
        NormalizedMetadata(
            source: .crossref,
            title: title.first,
            authors: (author ?? []).compactMap { fullName(given: $0.given, family: $0.family) },
            year: year(fromDateParts: issued?.dateParts),
            doi: doi,
            container: containerTitle?.first,
            volume: volume,
            number: issue,
            pages: page,
            publisher: publisher,
            type: bibType(forCrossrefType: type)
        )
    }
}

public extension ArxivEntry {
    func normalized() -> NormalizedMetadata {
        NormalizedMetadata(
            source: .arxiv,
            title: title,
            authors: authors,
            year: published.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil },
            doi: doi,
            arxivID: id,
            primaryClass: primaryCategory,
            container: journalRef,
            type: .article
        )
    }
}

public extension OpenLibraryBook {
    /// Always `.book`, and never merged against a paper-source field: see mergeMetadata.
    func normalized() -> NormalizedMetadata {
        let combinedTitle = [title, subtitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ": ")
        return NormalizedMetadata(
            source: .openLibrary,
            title: combinedTitle.isEmpty ? nil : combinedTitle,
            authors: authors,
            year: publishDate.flatMap(extractYear(from:)),
            publisher: publisher,
            isbn: isbn13 ?? isbn10,
            type: .book
        )
    }
}

// MARK: - Merge

/// Field-level merge, never whole-record: for each field, walk a ranked list of sources and
/// take the first one that has a value. Two different sources' values for the same field are
/// never averaged or concatenated.
///
/// `doi`, `container`, `volume`, `number`, `pages` and the type used to pick a source for
/// `doi`/`type` itself all follow the same order: doi, crossref, arxiv. A DOI resolved
/// through doi.org (whichever registry actually holds it) is the closest thing to a
/// canonical account of an already-published work; a Crossref record found by this app's own
/// title search is from the same registry but only reached by a fuzzy match; arXiv is the
/// author's own self-submitted preprint metadata, real but unedited by anyone else.
///
/// `title` reorders that to doi, arxiv, crossref: doi and arxiv were both reached by an
/// identifier this app pulled out of the document itself, so both outrank a Crossref record
/// that was only ever a guess at which of several search results was the right one.
///
/// `year` keeps the doi/crossref/arxiv order (formal venue year over arXiv's own posting
/// year, when both are known) rather than title's identifier-anchored order. This is a
/// judgment call, not something any of these services or BibTeX itself mandates -- some
/// citation styles prefer the original preprint year -- so it is kept as one clearly
/// commented rule rather than something a caller has to know to override.
///
/// `authors` prefers a real given/family split (doi, crossref) over arXiv's unsplit
/// "Given Family" string, and only falls back to Open Library's names when nothing else
/// supplied any.
///
/// Open Library never competes with the three paper sources for a paper's own fields, and
/// its own fields never lose to them: an ISBN is present only when the work is an actual
/// book, at which point Open Library is the sole source of `isbn` and, since it is the one
/// source that actually describes the book rather than some other record a fuzzy Crossref
/// search happened to return, of `title` too; `publisher` is asked from Open Library first,
/// and the merged `type` becomes `.book` outright rather than whatever
/// bibType(forCrossrefType:) would otherwise have produced.
public func mergeMetadata(_ records: [NormalizedMetadata]) -> NormalizedMetadata {
    func firstValue<T>(_ order: [MetadataSource], _ field: (NormalizedMetadata) -> T?) -> T? {
        for source in order {
            for record in records where record.source == source {
                if let value = field(record) { return value }
            }
        }
        return nil
    }
    func record(for source: MetadataSource) -> NormalizedMetadata? {
        records.first { $0.source == source }
    }
    func primarySource() -> MetadataSource {
        for source in paperOrder where record(for: source) != nil { return source }
        return records.first?.source ?? .crossref
    }

    let paperOrder: [MetadataSource] = [.doi, .crossref, .arxiv]
    let titleOrder: [MetadataSource] = [.doi, .arxiv, .crossref, .openLibrary]
    let yearOrder: [MetadataSource] = [.doi, .crossref, .arxiv, .openLibrary]
    let authorOrder: [MetadataSource] = [.doi, .crossref, .arxiv, .openLibrary]
    let publisherOrder: [MetadataSource] = [.openLibrary, .doi, .crossref]

    let openLibrary = record(for: .openLibrary)
    let isBook = openLibrary?.isbn != nil

    return NormalizedMetadata(
        source: isBook ? .openLibrary : primarySource(),
        title: isBook ? (openLibrary?.title ?? firstValue(titleOrder) { $0.title })
                      : firstValue(titleOrder) { $0.title },
        authors: firstValue(authorOrder) { $0.authors.isEmpty ? nil : $0.authors } ?? [],
        year: firstValue(yearOrder) { $0.year },
        doi: firstValue(paperOrder) { $0.doi },
        arxivID: record(for: .arxiv)?.arxivID,
        primaryClass: record(for: .arxiv)?.primaryClass,
        container: isBook ? nil : firstValue(paperOrder) { $0.container },
        volume: isBook ? nil : firstValue(paperOrder) { $0.volume },
        number: isBook ? nil : firstValue(paperOrder) { $0.number },
        pages: isBook ? nil : firstValue(paperOrder) { $0.pages },
        publisher: firstValue(publisherOrder) { $0.publisher },
        isbn: openLibrary?.isbn,
        type: isBook ? .book : (record(for: .doi)?.type ?? record(for: .crossref)?.type
                                ?? record(for: .arxiv)?.type ?? .misc)
    )
}

/// The opening of a piece of extracted text, with runs of whitespace squeezed to single
/// spaces.
///
/// Bounded on purpose. The panel that shows this displays three lines, while the text
/// behind it can be a whole book: squeezing all of it took about eighty milliseconds for a
/// thesis, and it was being done again on every pass of the view body that showed it.
/// Twenty times the room three lines can hold is enough to fill them and cheap enough not
/// to matter.
public func squeezedOpening(of text: String, limit: Int = 2000) -> String {
    text.prefix(limit).split(whereSeparator: \.isWhitespace).joined(separator: " ")
}
