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
public struct Query: Sendable, Equatable {
    public enum Comparison: String, Sendable { case equals, greater, less }

    public struct Term: Sendable, Equatable {
        public let field: String?
        public let value: String
        public let comparison: Comparison
    }

    public let terms: [Term]
    public var isEmpty: Bool { terms.isEmpty }
    /// True when anything here needs the document's text, which is expensive to get.
    public var needsText: Bool { terms.contains { $0.field == "text" } }

    public init(_ text: String) {
        terms = Query.split(text).compactMap(Query.term(from:))
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
        "name", "was", "folder", "text", "status", "size", "pages", "year",
    ]

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
    let status: String
    let year: String
    let size: Int
    let pages: Int
    /// Nil until the document's text has been read, which only happens for a text query.
    let text: [UInt8]?

    public init(item: Item, text: String? = nil) {
        name = normalised(item.destinationName)
        original = normalised(item.sourceName)
        folder = normalised((item.relativePath as NSString).deletingLastPathComponent)
        status = item.status.rawValue
        year = String(item.destinationName.prefix(4))
        size = item.byteCount ?? 0
        pages = item.pageCount ?? 0
        self.text = text.map(normalised)
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
        case "was": return contains(subject.original, needle)
        case "folder": return contains(subject.folder, needle)
        case "status": return subject.status.hasPrefix(term.value.lowercased())
        case "year": return subject.year.hasPrefix(term.value)
        // A text term with no text read yet cannot be satisfied, so the file drops out
        // rather than being let through on a technicality.
        case "text": return subject.text.map { contains($0, needle) } ?? false
        case "size", "pages":
            guard let wanted = number else { return false }
            let actual = term.field == "size" ? subject.size : subject.pages
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
