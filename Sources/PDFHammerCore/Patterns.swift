import Foundation
import PDFKit

// MARK: - Name patterns
//
// An arrangeable alternative to NameRules (Hammer.swift): instead of nine toggles that
// reshape one blob of text pulled out of an existing filename, a NamePattern is an
// ordered list of named placeholders the caller arranges directly, each carrying its
// own casing, length and abbreviation rather than one setting applying to all of them,
// in the spirit of Zotero's and JabRef's drag-in-a-chip renaming.
//
// `render` reads the same facts Hammer.swift already collects on every run (Item,
// BookGuess, FolderContext) but opens no PDF and touches no disk of its own; wiring
// this into Options and the naming UI is a separate change, made elsewhere.
//
// Two kinds of helpers from Hammer.swift are reused directly rather than reimplemented:
// `findDate` (module-internal there, not file-private) for locating a date inside a
// stem, and the public `sanitizedFilename`/`folderContext`/`monthPrefix`. Hammer.swift's
// `tidy`/`clipped`/`isUninformative`/`withoutLeadingArticles` are file-private there, so
// this file has its own small equivalents rather than reaching for the originals.

// MARK: - Tokens

/// One placeholder a pattern can be built from, with its own rendering options.
/// `Kind.rawValue` is also its spelling inside `[...]` in a pattern string.
public struct NameToken: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable, Identifiable, Equatable {
        case date            // year or year-month, lifted from the filename/folder/metadata/guess
        case year            // date's first four digits alone
        case title           // guess.title, else the stem with its own date lifted out
        case author          // guess.author, else documentInfo[Author]
        /// No pipeline in this codebase populates a publisher field: PDF metadata has
        /// no such attribute, and BookGuess only asks a model for title/author/year
        /// (BookGuess.swift:5-14). Reads documentInfo["Publisher"], which is always
        /// empty today; reserved for whenever a real source for it exists, handled the
        /// same way any other missing value already is.
        case publisher
        /// See `publisher`: reads documentInfo["Journal"], always empty today.
        case journal
        case folder          // nearest informative ancestor folder name (FolderContext.slug)
        case originalStem = "stem"   // the untouched original name, extension aside
        case counter         // "2", "3", ... only once a collision needs settling; empty for the first file
        public var id: String { rawValue }
    }

    /// Letter casing applied to the token's own resolved text. A no-op on a token that
    /// is already digits (date, year, counter).
    public enum Casing: String, Sendable, CaseIterable, Identifiable, Equatable {
        case unchanged, lower, upper, titleCase
        public var id: String { rawValue }
    }

    /// A token-specific shortening. Each case is meaningful for one or two kinds, and
    /// runs the same way regardless of kind: nothing here checks which token it was
    /// asked to shorten. It is harmless on a value with nothing for it to act on (no
    /// dash to strip, no space to split), but it will just as readily reshape a title,
    /// journal, or folder value that happens to contain one, since the transform itself
    /// does not know it was meant for a different kind of token.
    public enum Abbreviation: String, Sendable, CaseIterable, Identifiable, Equatable {
        /// No shortening.
        case none
        /// Strips internal dashes: `.date` reading `2024-06` becomes `202406`.
        case compact
        /// Keeps text after the last space: `.author` reading `Ada Lovelace` becomes `Lovelace`.
        case surname
        /// First letter of each space-separated word, uppercased: `.journal` reading
        /// `Journal of Machine Learning Research` becomes `JOMLR`.
        case initials
        public var id: String { rawValue }
    }

    public var kind: Kind
    public var casing: Casing
    /// Characters, clipped on a word boundary where one is available inside the
    /// budget. Zero leaves the token's own value unclipped.
    public var maxLength: Int
    public var abbreviation: Abbreviation

    public init(_ kind: Kind, casing: Casing = .unchanged, maxLength: Int = 0,
                abbreviation: Abbreviation = .none) {
        self.kind = kind
        self.casing = casing
        self.maxLength = maxLength
        self.abbreviation = abbreviation
    }
}

// MARK: - Elements and pattern

/// One arranged piece of a pattern: a placeholder with its own options, or text the
/// user typed by hand.
public enum NameElement: Sendable, Equatable {
    case token(NameToken)
    case literal(String)
}

/// An arrangeable filename pattern: tokens the user dragged into order, with literal
/// text wherever they typed it themselves.
public struct NamePattern: Sendable, Equatable {
    public var elements: [NameElement]
    /// Characters, clipped on a word boundary; zero leaves it. Applied to the whole
    /// rendered name, after every token has already been resolved and joined.
    public var maxTotalLength: Int

    public init(elements: [NameElement] = [], maxTotalLength: Int = 0) {
        self.elements = elements
        self.maxTotalLength = maxTotalLength
    }
}

// MARK: - Compact string syntax

/// Grammar (hand rolled, no third party parser), matching JabRef's flat bracket shape
/// rather than Zotero's keyword-argument blocks: a flat `[name:mod:mod]` block maps one
/// to one onto a draggable chip and its own small settings popover.
///
/// ```
/// pattern  := (literal | token)*
/// token    := '[' kind (':' modifier)* ']'
/// modifier := 'lower' | 'upper' | 'titlecase' | 'compact' | 'surname' | 'initials' | 'max' digits
/// literal  := any run of characters, with \[, \], \\ as escapes, up to the next unescaped '['
/// ```
extension NamePattern {
    /// Bracket syntax, e.g. `[date]-[title:max40]`. Round-trips through `init(parsing:)`.
    public var text: String {
        elements.map(Self.spelling).joined()
    }

    private static func spelling(_ element: NameElement) -> String {
        switch element {
        case .literal(let raw):
            return escape(raw)
        case .token(let token):
            var parts = [token.kind.rawValue]
            switch token.casing {
            case .unchanged: break
            case .lower: parts.append("lower")
            case .upper: parts.append("upper")
            case .titleCase: parts.append("titlecase")
            }
            switch token.abbreviation {
            case .none: break
            case .compact: parts.append("compact")
            case .surname: parts.append("surname")
            case .initials: parts.append("initials")
            }
            if token.maxLength > 0 { parts.append("max\(token.maxLength)") }
            return "[" + parts.joined(separator: ":") + "]"
        }
    }

    private static func escape(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for ch in raw {
            switch ch {
            case "[": out += "\\["
            case "]": out += "\\]"
            case "\\": out += "\\\\"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Parses the bracket syntax. A token name this build does not recognise (older,
    /// newer, or mistyped), or one carrying a modifier it does not understand, is kept
    /// as an opaque `.literal` of its own bracket text, brackets included, rather than
    /// dropped: a pattern that fails to parse cleanly never silently loses a piece of
    /// itself.
    public init(parsing text: String, maxTotalLength: Int = 0) {
        var elements: [NameElement] = []
        var literal = ""
        var chars = Substring(text)

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            elements.append(.literal(literal))
            literal = ""
        }

        while let ch = chars.first {
            if ch == "\\", chars.count > 1 {
                let next = chars[chars.index(after: chars.startIndex)]
                if "[]\\".contains(next) {
                    literal.append(next)
                    chars = chars.dropFirst(2)
                    continue
                }
            }
            if ch == "[", let close = chars.firstIndex(of: "]") {
                let body = chars[chars.index(after: chars.startIndex)..<close]
                if let token = Self.parseToken(body) {
                    flushLiteral()
                    elements.append(.token(token))
                } else {
                    literal += chars[chars.startIndex...close]
                }
                chars = chars[chars.index(after: close)...]
                continue
            }
            literal.append(ch)
            chars = chars.dropFirst()
        }
        flushLiteral()
        self.init(elements: elements, maxTotalLength: maxTotalLength)
    }

    /// `nil` when any piece of `body` (the kind, or one of its modifiers) is not
    /// recognised, so the caller keeps the whole bracket as literal text instead of
    /// silently applying only the parts it understood.
    private static func parseToken(_ body: Substring) -> NameToken? {
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard let first = parts.first, let kind = NameToken.Kind(rawValue: String(first)) else { return nil }
        var token = NameToken(kind)
        for raw in parts.dropFirst() {
            switch String(raw) {
            case "lower": token.casing = .lower
            case "upper": token.casing = .upper
            case "titlecase": token.casing = .titleCase
            case "compact": token.abbreviation = .compact
            case "surname": token.abbreviation = .surname
            case "initials": token.abbreviation = .initials
            default:
                let piece = String(raw)
                if piece.hasPrefix("max"), let n = Int(piece.dropFirst(3)), n > 0 {
                    token.maxLength = n
                } else {
                    return nil
                }
            }
        }
        return token
    }
}

// MARK: - Rendering

/// Renders `pattern` for one file. Only fields already on `item`, `guess`, `folder` are
/// read, no PDF is opened, no disk is touched, so a whole catalogue restyles as fast as
/// a preference can be flipped.
public func render(
    _ pattern: NamePattern,
    for item: Item,
    guess: BookGuess? = nil,
    folder: FolderContext = .none,
    collisionIndex: Int = 1,
    rules: NameRules? = nil
) -> String {
    let resolved: [(NameElement, String?)] = pattern.elements.map { element in
        guard case .token(let token) = element else { return (element, nil) }
        // A token's value comes out of a filename or a PDF's metadata, so it arrives
        // carrying whatever that filename carried: runs of spaces, a stray '--', the
        // publisher and the hash some download site appended. Given rules, it goes
        // through the same tidy the rest of the app renames by, so a pattern and the
        // ordinary rename agree about what a name looks like. Without them the value is
        // passed through as it is, which is what a caller wanting the raw text gets.
        // Literals the user typed are never touched either way.
        let value = resolvedValue(for: token.kind, item: item, guess: guess,
                                   folder: folder, collisionIndex: collisionIndex)
            .map { value in rules.map { tidy(value, $0) } ?? value }
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { apply(token, to: $0) }
        return (element, value)
    }

    let joined = assemble(resolved)
    guard !joined.isEmpty else { return item.sourceName }

    let clippedJoined = pattern.maxTotalLength > 0 ? clip(joined, to: pattern.maxTotalLength) : joined
    return sanitizedFilename(safeStem(clippedJoined))
}

/// Joins resolved elements left to right. A literal sitting directly next to a token
/// that resolved empty is dropped along with it: first the separator right after the
/// gap, or the one right before it if there is nothing after, so `[author]-[title]`
/// with no known author renders `title`, not `-title`, and a token dropped from the
/// middle of `[author]-[title]-[year]` leaves exactly one separator behind rather than
/// gluing the survivors together or leaving both dashes in place.
private func assemble(_ items: [(NameElement, String?)]) -> String {
    enum Piece { case value(String), literal(String), empty }

    var pieces: [Piece] = items.map { element, resolved in
        switch element {
        case .literal(let raw): return .literal(raw)
        case .token:
            guard let resolved, !resolved.isEmpty else { return .empty }
            return .value(resolved)
        }
    }

    var index = 0
    while index < pieces.count {
        guard case .empty = pieces[index] else { index += 1; continue }
        if index + 1 < pieces.count, case .literal = pieces[index + 1] {
            pieces.remove(at: index + 1)
        } else if index > 0, case .literal = pieces[index - 1] {
            pieces.remove(at: index - 1)
            index -= 1
        }
        pieces.remove(at: index)
        // Do not advance: whatever slid into this slot (e.g. a second empty token
        // that shared the separator just eaten) still needs its own check.
    }

    return pieces.map { piece -> String in
        switch piece {
        case .value(let s), .literal(let s): return s
        case .empty: return ""
        }
    }.joined()
}

/// The bare value for one token kind, before its own casing/abbreviation/length options
/// are applied. `nil` means genuinely absent, not merely blank.
private func resolvedValue(
    for kind: NameToken.Kind,
    item: Item,
    guess: BookGuess?,
    folder: FolderContext,
    collisionIndex: Int
) -> String? {
    switch kind {
    case .date:
        return datePrefix(item: item, guess: guess, folder: folder)
    case .year:
        return datePrefix(item: item, guess: guess, folder: folder).map { String($0.prefix(4)) }
    case .title:
        if let title = nonEmpty(guess?.title) { return title }
        let stem = titleStem(of: item)
        if let stem = nonEmpty(stem), stem.contains(where: \.isLetter) { return stem }
        return nonEmpty(folder.slug) ?? nonEmpty(stem)
    case .author:
        return nonEmpty(guess?.author) ?? nonEmpty(item.documentInfo[PDFDocumentAttribute.authorAttribute.rawValue])
    case .publisher:
        return nonEmpty(item.documentInfo["Publisher"])
    case .journal:
        return nonEmpty(item.documentInfo["Journal"])
    case .folder:
        return nonEmpty(folder.slug)
    case .originalStem:
        return nonEmpty(stem(of: item))
    case .counter:
        return collisionIndex > 1 ? String(collisionIndex) : nil
    }
}

/// `.date`'s own resolution order: a guess's year outranks everything else, since
/// `filename(for:rules:)` already treats a BookGuess's year as the most authoritative
/// date there is (BookGuess.swift:73-81); after that, a date already sitting in the
/// filename, then the enclosing folder, then the two metadata fallbacks, the same order
/// `process(job:options:)` assembles them in (Hammer.swift:1282-1285).
private func datePrefix(item: Item, guess: BookGuess?, folder: FolderContext) -> String? {
    if let year = nonEmpty(guess?.year) { return year }
    if let found = findDate(in: stem(of: item)) { return found.prefix }
    if let prefix = nonEmpty(folder.prefix) { return prefix }
    if let metadataDate = item.metadataDate { return monthPrefix(metadataDate) }
    if let modifiedDate = item.modifiedDate { return monthPrefix(modifiedDate) }
    return nil
}

private func nonEmpty(_ text: String?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
}

private func stem(of item: Item) -> String {
    (item.sourceName as NSString).deletingPathExtension
}

/// The stem with its own date lifted out, mirroring normalizedName's first step
/// (Hammer.swift:307): replaced rather than deleted, so `foo2024bar` does not become
/// `foobar`. Otherwise untouched; a token's own `casing` option is where letter-case
/// cleanup happens, not this function.
private func titleStem(of item: Item) -> String {
    let raw = stem(of: item)
    let edges = CharacterSet(charactersIn: " -_")
    guard let found = findDate(in: raw) else { return raw.trimmingCharacters(in: edges) }
    let replaced = (raw as NSString).replacingCharacters(in: found.range, with: " ")
    return replaced.trimmingCharacters(in: edges)
}

/// Applies a token's own casing, then abbreviation, then length limit, in that order.
private func apply(_ token: NameToken, to raw: String) -> String {
    var value = raw
    switch token.casing {
    case .unchanged: break
    case .lower: value = value.lowercased()
    case .upper: value = value.uppercased()
    case .titleCase: value = value.capitalized
    }
    switch token.abbreviation {
    case .none:
        break
    case .compact:
        value = value.replacingOccurrences(of: "-", with: "")
    case .surname:
        if let space = value.lastIndex(of: " ") {
            value = String(value[value.index(after: space)...])
        }
    case .initials:
        let letters = value.split(separator: " ").compactMap(\.first)
        if !letters.isEmpty { value = String(letters).uppercased() }
    }
    if token.maxLength > 0 { value = clip(value, to: token.maxLength) }
    return value
}

/// Windows' reserved device names, so a render that would otherwise land on e.g.
/// `con.pdf` (a perfectly legal name on macOS/APFS, but broken on a filesystem or an
/// archive that treats it as a reserved device even case-insensitively) never comes
/// out of `render` unmodified.
private let reservedStems: Set<String> = [
    "con", "prn", "aux", "nul",
    "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
    "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
]

private func safeStem(_ stem: String) -> String {
    guard reservedStems.contains(stem.lowercased()) else { return stem }
    return "\(stem)-file"
}

/// Cuts `text` back to `limit` characters, preferring the last space/dash/underscore
/// boundary inside the budget so a value ends on a whole word rather than mid-syllable.
/// A smaller, file-local cousin of `clipped(_:to:)` in Hammer.swift, which is
/// file-private there and out of reach here.
private func clip(_ text: String, to limit: Int) -> String {
    guard limit > 0, text.count > limit else { return text }
    let cut = String(text.prefix(limit))
    let boundary: Set<Character> = ["-", "_", " "]
    if let index = cut.lastIndex(where: { boundary.contains($0) }) {
        let head = String(cut[cut.startIndex..<index])
        if !head.isEmpty { return head }
    }
    return cut.trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
}

// MARK: - Collision handling

/// `render`, tried again with an increasing counter until the result is not one of
/// `existingNames`: data the caller already has, never a filesystem probe; this file
/// makes no such calls (see `availableURL` in Hammer.swift for that job on real disk).
///
/// If `pattern` carries no `.counter` token to absorb the bump, a Hammer-style `-2`,
/// `-3` suffix is appended instead, matching `availableURL`'s own convention
/// (Hammer.swift:1016-1027).
public func availableName(
    for pattern: NamePattern,
    item: Item,
    guess: BookGuess? = nil,
    folder: FolderContext = .none,
    existingNames: Set<String>
) -> String {
    let base = render(pattern, for: item, guess: guess, folder: folder, collisionIndex: 1)
    guard existingNames.contains(base) else { return base }

    let hasCounterToken = pattern.elements.contains {
        if case .token(let token) = $0 { return token.kind == .counter }
        return false
    }

    var index = 2
    let ceiling = 10_000   // a safety valve, not a realistic collision count
    while index < ceiling {
        let candidate = hasCounterToken
            ? render(pattern, for: item, guess: guess, folder: folder, collisionIndex: index)
            : suffixed(base, index)
        if !existingNames.contains(candidate) { return candidate }
        index += 1
    }
    return suffixed(base, index)
}

/// Inserts `-n` right before the extension: `name.pdf` -> `name-2.pdf`.
private func suffixed(_ name: String, _ index: Int) -> String {
    let stem = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    return ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
}

// MARK: - Preview

/// One resolved token in a preview, so a UI can grey the ones that came out empty
/// without re-deriving the render logic itself.
public struct NameTokenPreview: Sendable, Equatable {
    public let kind: NameToken.Kind
    public let value: String
    public let isEmpty: Bool
}

/// Enough for a UI to show "this file becomes that name": the rendered result, and what
/// each token in the pattern resolved to.
public struct NamePreview: Sendable, Equatable {
    public let originalName: String
    public let renderedName: String
    public let tokens: [NameTokenPreview]
}

/// `render`, plus the folder walk `render` itself does not do, so a preview and a real
/// run resolve the same folder slug (`folderContext(for:under:)`, Hammer.swift:240).
/// `root` nil skips the walk, matching `folder: .none`.
public func preview(
    _ pattern: NamePattern,
    for item: Item,
    guess: BookGuess? = nil,
    under root: URL? = nil,
    collisionIndex: Int = 1
) -> NamePreview {
    let folder = root.map { folderContext(for: item.source, under: $0) } ?? .none
    let tokens: [NameTokenPreview] = pattern.elements.compactMap { element in
        guard case .token(let token) = element else { return nil }
        let value = resolvedValue(for: token.kind, item: item, guess: guess,
                                   folder: folder, collisionIndex: collisionIndex)
            .map { apply(token, to: $0) } ?? ""
        return NameTokenPreview(kind: token.kind, value: value, isEmpty: value.isEmpty)
    }
    return NamePreview(
        originalName: item.sourceName,
        renderedName: render(pattern, for: item, guess: guess, folder: folder, collisionIndex: collisionIndex),
        tokens: tokens
    )
}

/// `preview`, for a sample of documents at once, matched to any guesses already known
/// by `Item.key`.
public func previews(
    _ pattern: NamePattern,
    for items: [Item],
    guesses: [String: BookGuess] = [:],
    under root: URL? = nil
) -> [NamePreview] {
    items.map { preview(pattern, for: $0, guess: guesses[$0.key], under: root) }
}

// MARK: - Presets

/// A built-in pattern with a one-line note on when it earns its keep.
public struct NamePatternPreset: Sendable, Equatable, Identifiable {
    public let name: String
    public let summary: String
    public let pattern: NamePattern
    public var id: String { name }
}

extension NamePattern {
    /// Today's plain shape: a date up front, then whatever the name already says.
    public static let statement = NamePattern(parsing: "[date]-[title]")
    /// A shelf of books: who wrote it, when, what it is called.
    public static let book = NamePattern(parsing: "[author:surname]-[year]-[title]")
    /// For papers and articles where a reliable year is rarely on hand.
    public static let authorTitle = NamePattern(parsing: "[author:surname]-[title]")
    /// Sorts chronologically first; the title is capped so a long one does not run on.
    public static let reference = NamePattern(parsing: "[year]-[author:surname]-[title:max40]")

    public static let presets: [NamePatternPreset] = [
        NamePatternPreset(name: "Statement",
                           summary: "Bank and utility statements: the date is what you search by.",
                           pattern: .statement),
        NamePatternPreset(name: "Book",
                           summary: "Books with a known author and year, shelved by who wrote them.",
                           pattern: .book),
        NamePatternPreset(name: "Author + title",
                           summary: "Papers and articles where the year is unreliable or absent.",
                           pattern: .authorTitle),
        NamePatternPreset(name: "Reference",
                           summary: "A citation-style name for a folder you will cite from later.",
                           pattern: .reference),
    ]
}
