import Foundation

/// A search over the results.
///
/// The syntax is the small one people already expect from a mail client: bare words match
/// the name, `field:value` narrows, and `>`/`<` compare. Anything unrecognised is treated
/// as a bare word rather than rejected, because a search box that refuses input is worse
/// than one that searches for the literal text.
///
///     extracto 2024            both words appear in the name
///     folder:bank size>10mb    in a folder called bank, over ten megabytes
///     pages>100 status:locked  long, and no password opened it
///     text:"quick brown"       those words appear in the opening pages
///     tag:reading              carries a tag starting with "reading"
public struct Query: Sendable, Equatable {
    public enum Comparison: String, Sendable { case equals, greater, less }

    public struct Term: Sendable, Equatable {
        public let field: String?
        public let value: String
        public let comparison: Comparison
    }

    public let terms: [Term]
    public var isEmpty: Bool { terms.isEmpty }
    /// True when anything here has to be answered from the document's own text, which
    /// only the library holds and only for documents it has read.
    public var needsText: Bool { !storedTerms.isEmpty }

    public init(_ text: String) {
        terms = Query.split(text).compactMap(Query.term(from:))
    }

    /// A query made of terms already parsed, for splitting one query into the part a
    /// projection can answer and the part the library has to.
    public init(terms: [Term]) {
        self.terms = terms
    }

    /// The terms this query has that only the store can answer.
    public var storedTerms: [Term] { terms.filter { Query.storedFields.contains($0.field ?? "") } }
    /// Everything else: what a `Searchable` can decide on its own.
    public var localTerms: [Term] { terms.filter { !Query.storedFields.contains($0.field ?? "") } }

    /// The search text that shows one tag's documents. Always quoted: a tag is free text
    /// and "to read" unquoted would parse as a tag search for "to" plus a bare word.
    public static func tagSearch(_ name: String) -> String {
        "tag:\"\(name)\""
    }

    /// Splits on spaces while keeping quoted runs together.
    static func split(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
            } else if character == " " && !quoted {
                if !current.isEmpty { pieces.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private static let fields: Set<String> = [
        "name", "was", "folder", "text", "status", "size", "pages", "year", "tag",
        "title", "author", "abstract",
    ]

    /// The fields only the library can answer: they are about the inside of a document,
    /// which lives in the store's extracted text rather than in anything an `Item` knows.
    public static let storedFields: Set<String> = ["text", "abstract"]

    static func term(from piece: String) -> Term? {
        for comparison in [(">", Comparison.greater), ("<", Comparison.less), (":", .equals)] {
            guard let index = piece.firstIndex(of: Character(comparison.0)) else { continue }
            let field = String(piece[piece.startIndex..<index]).lowercased()
            let value = String(piece[piece.index(after: index)...])
            guard fields.contains(field), !value.isEmpty else { continue }
            return Term(field: field, value: value, comparison: comparison.1)
        }
        let bare = piece.trimmingCharacters(in: .whitespaces)
        return bare.isEmpty ? nil : Term(field: nil, value: bare, comparison: .equals)
    }
}

/// Reads `10mb`, `500k`, `2000` as byte counts.
func byteValue(_ text: String) -> Int? {
    let lowered = text.lowercased()
    let multipliers: [(String, Int)] = [("gb", 1 << 30), ("mb", 1 << 20), ("kb", 1 << 10),
                                        ("g", 1 << 30), ("m", 1 << 20), ("k", 1 << 10)]
    for (suffix, scale) in multipliers where lowered.hasSuffix(suffix) {
        let number = lowered.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
        guard let value = Double(number) else { return nil }
        return Int(value * Double(scale))
    }
    return Int(lowered)
}

/// How much of a document counts as its opening for an `abstract:` search. A title page,
/// an author list and an abstract fit inside this; a paper's introduction mostly does not.
public let abstractCharacterLimit = 2_000

/// The year of a date, as four digits. `Calendar.current` rather than a formatter: this
/// runs once per file per search projection, and a formatter is the slower of the two.
func yearText(_ date: Date) -> String {
    String(Calendar.current.component(.year, from: date))
}

/// Normalises text for comparison: composed form, lowercased, as UTF-8 bytes.
///
/// Bytes rather than `String`, because `String.contains` is grapheme-cluster aware and
/// costs about fifty times a plain scan. Canonical composition is applied to both sides
/// so that an accent written as one code point still matches one written as two, which
/// is the correctness that byte comparison would otherwise lose.
func normalised(_ text: String) -> [UInt8] {
    Array(text.precomposedStringWithCanonicalMapping.lowercased().utf8)
}

/// Plain two-pointer scan. Short needles over documents of a few thousand bytes do not
/// justify anything cleverer, and this is already far below the cost of reading the file.
func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty else { return true }
    guard haystack.count >= needle.count else { return false }
    let first = needle[0]
    let limit = haystack.count - needle.count
    var index = 0
    while index <= limit {
        if haystack[index] == first {
            var offset = 1
            while offset < needle.count && haystack[index + offset] == needle[offset] { offset += 1 }
            if offset == needle.count { return true }
        }
        index += 1
    }
    return false
}

/// Everything a term can be tested against, prepared once per file rather than once per
/// keystroke: building this is most of what a metadata search used to cost.
public struct Searchable: Sendable {
    let name: [UInt8]
    let original: [UInt8]
    let folder: [UInt8]
    /// What the document says it is called and who wrote it. Empty when nothing has read
    /// the PDF and the library has nothing on record either, in which case a `title:` or
    /// `author:` term fails rather than matching everything.
    let title: [UInt8]
    let author: [UInt8]
    let status: String
    /// Every year this file could reasonably be said to be from: the four digits a name
    /// starts with, the year the PDF says it was created, and the year the file was last
    /// written. A paper named `smith-2024-causality.pdf` is a 2024 paper, and matching
    /// only the name's first four characters said it was not.
    let years: [String]
    let size: Int
    /// Nil when nothing has read the document yet. A `pages:` term fails against it
    /// rather than matching zero, which would let every unread file through a `pages<10`.
    let pages: Int?
    /// Nil until the document's text has been read, which only happens for a text query.
    let text: [UInt8]?
    /// From the library, not the file itself, so it defaults to empty: a caller that has
    /// not resolved this item to a document and asked what it is tagged with cannot say
    /// yes to a `tag:` term, and must not be made to guess.
    let tags: [String]

    /// `pageCount` is the library's own answer, for a file the shelf listed without
    /// opening: the item carries a page count only once something has read the PDF.
    public init(item: Item, text: String? = nil, tags: [String] = [],
                pageCount: Int? = nil, title: String? = nil, author: String? = nil) {
        name = normalised(item.destinationName)
        original = normalised(item.sourceName)
        folder = normalised((item.relativePath as NSString).deletingLastPathComponent)
        self.title = normalised(item.documentInfo["Title"] ?? title ?? "")
        self.author = normalised(item.documentInfo["Author"] ?? author ?? "")
        status = item.status.rawValue
        years = [String(item.destinationName.prefix(4)),
                 item.metadataDate.map(yearText),
                 item.modifiedDate.map(yearText)].compactMap { $0 }
        size = item.byteCount ?? 0
        pages = item.pageCount ?? pageCount
        self.text = text.map(normalised)
        self.tags = tags
    }
}

/// A query with its needles converted once, rather than per file.
public struct PreparedQuery: Sendable {
    let terms: [(term: Query.Term, needle: [UInt8], number: Int?)]

    public init(_ query: Query) {
        terms = query.terms.map { term in
            let number = term.field == "size"
                ? byteValue(term.value)
                : (term.field == "pages" ? Int(term.value) : nil)
            return (term, normalised(term.value), number)
        }
    }
}

/// Whether one file satisfies every term. Terms are joined with and, which is what a
/// space means to nearly everyone typing into a search box.
public func matches(_ subject: Searchable, _ query: PreparedQuery) -> Bool {
    query.terms.allSatisfy { term, needle, number in
        switch term.field {
        case nil:
            return contains(subject.name, needle) || contains(subject.original, needle)
        case "name": return contains(subject.name, needle)
        case "title": return contains(subject.title, needle)
        case "author": return contains(subject.author, needle)
        // What a paper opens with, which is where its abstract is. Only answerable once
        // the document's text has been read; see `abstractCharacterLimit`.
        case "abstract":
            return subject.text.map { contains(Array($0.prefix(abstractCharacterLimit)), needle) } ?? false
        case "was": return contains(subject.original, needle)
        case "folder": return contains(subject.folder, needle)
        case "status": return subject.status.hasPrefix(term.value.lowercased())
        case "year": return subject.years.contains { $0.hasPrefix(term.value) }
        // Empty (unresolved) tags fail rather than pass, the same convention "text"
        // already uses: a file nothing has checked cannot be said to carry the tag.
        case "tag": return subject.tags.contains { $0.lowercased().hasPrefix(term.value.lowercased()) }
        // A text term with no text read yet cannot be satisfied, so the file drops out
        // rather than being let through on a technicality.
        case "text": return subject.text.map { contains($0, needle) } ?? false
        case "size", "pages":
            guard let wanted = number else { return false }
            guard let actual = term.field == "size" ? subject.size : subject.pages
            else { return false }
            switch term.comparison {
            case .greater: return actual > wanted
            case .less: return actual < wanted
            case .equals: return actual == wanted
            }
        default: return true
        }
    }
}

/// Convenience for a one-off check. Repeated searching should prepare the query once.
public func matches(_ subject: Searchable, _ query: Query) -> Bool {
    matches(subject, PreparedQuery(query))
}

// MARK: - The query as chips

public extension Query {
    /// The query broken into the pieces a person can take back one at a time.
    ///
    /// A search box that can only be cleared whole is a search box people retype. These
    /// are the same pieces the parser reads, put back the way they were typed, so a chip
    /// removed leaves a query that still means what the remaining chips say.
    static func chips(_ text: String) -> [String] {
        split(text).map(requoted)
    }

    /// The query without one chip.
    static func removing(_ chip: String, from text: String) -> String {
        chips(text).filter { $0 != chip }.joined(separator: " ")
    }

    /// A piece as it has to be written to survive another parse. Splitting drops the
    /// quotes that held a value together, so anything with a space in it gets them back.
    private static func requoted(_ piece: String) -> String {
        guard piece.contains(" ") else { return piece }
        for separator in [":", ">", "<"] {
            guard let index = piece.firstIndex(of: Character(separator)) else { continue }
            let field = String(piece[piece.startIndex..<index])
            guard !field.contains(" ") else { continue }
            return field + separator + "\"" + String(piece[piece.index(after: index)...]) + "\""
        }
        return "\"" + piece + "\""
    }
}
