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

/// Everything a term can be tested against, gathered once per file.
public struct Searchable: Sendable {
    public let name: String
    public let original: String
    public let folder: String
    public let status: String
    public let year: String
    public let size: Int
    public let pages: Int
    /// Nil until the document's text has been read, which only happens for a text query.
    public let text: String?

    public init(item: Item, text: String? = nil) {
        name = item.destinationName.lowercased()
        original = item.sourceName.lowercased()
        folder = (item.relativePath as NSString).deletingLastPathComponent.lowercased()
        status = item.status.rawValue
        year = String(item.destinationName.prefix(4))
        size = item.byteCount ?? 0
        pages = item.pageCount ?? 0
        self.text = text?.lowercased()
    }
}

/// Whether one file satisfies every term. Terms are joined with and, which is what a
/// space means to nearly everyone typing into a search box.
public func matches(_ subject: Searchable, _ query: Query) -> Bool {
    query.terms.allSatisfy { term in
        let value = term.value.lowercased()
        switch term.field {
        case nil:
            return subject.name.contains(value) || subject.original.contains(value)
        case "name": return subject.name.contains(value)
        case "was": return subject.original.contains(value)
        case "folder": return subject.folder.contains(value)
        case "status": return subject.status.hasPrefix(value)
        case "year": return subject.year.hasPrefix(value)
        // A text term with no text read yet cannot be satisfied, so the file drops out
        // rather than being let through on a technicality.
        case "text": return subject.text?.contains(value) ?? false
        case "size", "pages":
            let actual = term.field == "size" ? subject.size : subject.pages
            guard let wanted = term.field == "size" ? byteValue(value) : Int(value) else { return false }
            switch term.comparison {
            case .greater: return actual > wanted
            case .less: return actual < wanted
            case .equals: return actual == wanted
            }
        default: return true
        }
    }
}
