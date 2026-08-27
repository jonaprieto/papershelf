import Foundation

/// What kind of thing an entry describes. BibTeX expects different fields for each, so
/// this decides what counts as incomplete.
public enum BibType: String, Sendable, CaseIterable, Identifiable {
    case book, article, misc, report, inbook, online, inproceedings, incollection, thesis

    public var id: String { rawValue }

    /// What goes after the `@`. A thesis is written as `@phdthesis`, the classic BibTeX
    /// name that biblatex also accepts as a legacy alias for `@thesis` (the same trick
    /// `report` already relies on to write `@techreport` instead of the stricter
    /// `@report`), so one keyword compiles under either standard.
    public var keyword: String {
        switch self {
        case .report: return "techreport"
        case .thesis: return "phdthesis"
        default: return rawValue
        }
    }

    public var label: String {
        switch self {
        case .book: return "@book"
        case .article: return "@article"
        case .misc: return "@misc"
        case .report: return "@techreport"
        case .inbook: return "@inbook"
        case .online: return "@online"
        case .inproceedings: return "@inproceedings"
        case .incollection: return "@incollection"
        case .thesis: return "@phdthesis"
        }
    }

    /// Of the fields this app can actually produce, the ones this type needs.
    ///
    /// BibTeX also wants publisher, journal or institution depending on the type, but
    /// nothing here can read those off a PDF, so reporting them as missing would be a
    /// permanent complaint with no way to act on it. See `requiredFieldGroups(for:)` for
    /// the full, standard-accurate requirement a paper-ready entry is actually judged
    /// against.
    public var expected: Set<String> {
        switch self {
        case .misc: return ["title"]
        case .online: return ["title", "year"]
        default: return ["title", "author", "year"]
        }
    }
}

/// Which vocabulary an entry's required fields are judged against. The two disagree on
/// what a type needs, not just on spelling: classic BibTeX's `@incollection` wants a
/// publisher, biblatex's wants an editor instead, and biblatex's `@online` requires a
/// doi/eprint/url that classic BibTeX has no way to express at all.
public enum BibStandard: String, Sendable, CaseIterable, Identifiable {
    case classic, biblatex
    public var id: String { rawValue }
    public var label: String { self == .classic ? "Classic BibTeX" : "biblatex" }
}

extension BibType {
    /// Which fields `standard` requires this type to have, as groups where any one member
    /// of a group satisfies it (`["author", "editor"]` reads as "author or editor").
    /// Taken directly from BibTeXing §3.1 (classic) and the biblatex manual §2.1.1
    /// (biblatex); the tables really do disagree, so there is no single merged
    /// "the" requirement for a type.
    public func requiredFieldGroups(for standard: BibStandard) -> [[String]] {
        switch (self, standard) {
        case (.book, .classic):
            return [["author", "editor"], ["title"], ["publisher"], ["year"]]
        case (.book, .biblatex):
            return [["author"], ["title"], ["year"]]
        case (.inbook, .classic):
            return [["author", "editor"], ["title"], ["publisher"], ["year"]]
        case (.inbook, .biblatex):
            // biblatex's @inbook is a different shape from classic's: booktitle replaces
            // chapter-and/or-pages as the thing that says which book this is part of.
            return [["author"], ["title"], ["booktitle"], ["year"]]
        case (.article, .classic), (.article, .biblatex):
            return [["author"], ["title"], ["journal"], ["year"]]
        case (.inproceedings, .classic), (.inproceedings, .biblatex):
            return [["author"], ["title"], ["booktitle"], ["year"]]
        case (.incollection, .classic):
            return [["author"], ["title"], ["booktitle"], ["publisher"], ["year"]]
        case (.incollection, .biblatex):
            return [["author"], ["title"], ["editor"], ["booktitle"], ["year"]]
        case (.report, .classic), (.report, .biblatex):
            return [["author"], ["title"], ["institution"], ["year"]]
        case (.thesis, .classic):
            return [["author"], ["title"], ["school"], ["year"]]
        case (.thesis, .biblatex):
            // biblatex's own @thesis also requires a `type` field ("mathesis" or
            // "phdthesis"), but the phdthesis alias this app writes sets that itself --
            // the same mechanism `report` already relies on for `@techreport`.
            return [["author"], ["title"], ["institution"], ["year"]]
        case (.misc, .classic):
            return []
        case (.misc, .biblatex):
            return [["title"]]
        case (.online, .classic):
            // No @online in classic BibTeX; nearest analogue is @misc.
            return [["title"]]
        case (.online, .biblatex):
            return [["author", "editor"], ["title"], ["doi", "url"], ["year"]]
        }
    }
}

/// One bibliography record. Title/author/year come off a PDF's name or an AI guess; the
/// rest exist so an entry can hold what a real paper's bibliography needs, even though
/// nothing upstream fills them in yet. Everything but the file path may be missing, and a
/// missing field is reported rather than filled in with a guess.
public struct BibEntry: Identifiable, Sendable, Equatable {
    /// The `Item.key` this came from, so a row here can point back at the file.
    public var itemKey: String
    public var key: String
    public var title: String
    public var author: String?
    public var editor: String?
    public var year: String?
    public var month: String?
    public var journal: String?
    public var booktitle: String?
    public var publisher: String?
    public var institution: String?
    public var school: String?
    public var pages: String?
    public var doi: String?
    public var url: String?
    public var file: String
    public var type: BibType = .book

    public init(itemKey: String, key: String, title: String, author: String? = nil,
                editor: String? = nil, year: String? = nil, month: String? = nil,
                journal: String? = nil, booktitle: String? = nil, publisher: String? = nil,
                institution: String? = nil, school: String? = nil, pages: String? = nil,
                doi: String? = nil, url: String? = nil, file: String, type: BibType = .book) {
        self.itemKey = itemKey
        self.key = key
        self.title = title
        self.author = author
        self.editor = editor
        self.year = year
        self.month = month
        self.journal = journal
        self.booktitle = booktitle
        self.publisher = publisher
        self.institution = institution
        self.school = school
        self.pages = pages
        self.doi = doi
        self.url = url
        self.file = file
        self.type = type
    }

    public var id: String { itemKey }

    /// The fields this type expects that this entry does not have, out of the handful
    /// this app can actually read off a PDF. See `gaps(for:)` for the fuller check
    /// against everything BibTeX or biblatex would actually ask for.
    public var missing: [String] {
        var gaps: [String] = []
        if type.expected.contains("author"), author == nil { gaps.append("author") }
        if type.expected.contains("year"), year == nil { gaps.append("year") }
        if type.expected.contains("title"), title.isEmpty { gaps.append("title") }
        return gaps
    }

    public var isComplete: Bool { missing.isEmpty }

    /// This entry's value for a BibTeX field name, or nil if it has none -- either
    /// because it is empty or because `BibEntry` has nowhere to hold it at all.
    private func fieldValue(_ name: String) -> String? {
        let value: String?
        switch name {
        case "title": value = title
        case "author": value = author
        case "editor": value = editor
        case "year": value = year
        case "journal": value = journal
        case "booktitle": value = booktitle
        case "publisher": value = publisher
        case "institution": value = institution
        case "school": value = school
        case "doi": value = doi
        case "url": value = url
        default: value = nil
        }
        return value?.isEmpty == false ? value : nil
    }

    /// The fields `standard` requires that this entry has no value for -- every field
    /// BibTeX or biblatex actually asks for, not just the handful `missing` checks. Says
    /// plainly that a submitted `@inproceedings` with no `booktitle` will not compile,
    /// rather than treat it as merely "incomplete" by this app's own narrower bar.
    public func gaps(for standard: BibStandard) -> [String] {
        type.requiredFieldGroups(for: standard).compactMap { group in
            group.contains { fieldValue($0) != nil } ? nil : group[0]
        }
    }

    public func isValid(for standard: BibStandard) -> Bool { gaps(for: standard).isEmpty }
}

/// Escapes what BibTeX treats as syntax. Values are wrapped in braces, so the characters
/// that matter are the braces themselves and the backslash that would escape them.
public func bibtexEscape(_ value: String) -> String {
    var out = ""
    for ch in value {
        switch ch {
        case "\\": out += "\\textbackslash{}"
        case "{", "}": out += "\\" + String(ch)
        case "$", "&", "%", "#", "_": out += "\\" + String(ch)
        case "~": out += "\\textasciitilde{}"
        case "^": out += "\\textasciicircum{}"
        default: out.append(ch)
        }
    }
    return out
}

/// The common accented Latin letters, written as the standalone LaTeX macro a classic
/// (non-biber) BibTeX run needs, since biber is the only processor in this chain that
/// reads UTF-8 natively (biblatex.pdf §2.4.2).
private let bibtexStandaloneLetters: [Character: String] = [
    "æ": "\\ae{}", "Æ": "\\AE{}", "œ": "\\oe{}", "Œ": "\\OE{}",
    "ø": "\\o{}", "Ø": "\\O{}", "å": "\\aa{}", "Å": "\\AA{}",
    "ß": "\\ss{}", "ð": "\\dh{}", "Ð": "\\DH{}", "þ": "\\th{}", "Þ": "\\TH{}",
    "ł": "\\l{}", "Ł": "\\L{}", "ı": "\\i{}",
]

/// Combining marks whose LaTeX macro wraps around the base letter as `\'{e}`.
private let bibtexAccentSymbols: [UInt32: String] = [
    0x0301: "'", 0x0300: "`", 0x0302: "^", 0x0308: "\"", 0x0303: "~", 0x0304: "=",
]
/// Combining marks whose LaTeX macro is spelled out as a letter, `\c{c}` rather than a
/// symbol.
private let bibtexAccentLetters: [UInt32: String] = [
    0x0327: "c", 0x030A: "r", 0x030C: "v", 0x0328: "k", 0x0307: ".",
]

/// Rewrites accented and other non-ASCII Latin letters as the LaTeX escapes above, for a
/// value that has to survive a classic BibTeX run rather than a biber/biblatex one.
/// Covers the common European diacritics and a handful of standalone letters; anything
/// else keeps its base letter and silently drops a mark this table does not know, since
/// losing an accent is a smaller wrong than losing the letter entirely.
public func bibtexTransliterate(_ value: String) -> String {
    var out = ""
    var pendingBase: Character?
    func flush() {
        if let base = pendingBase {
            out.append(base)
            pendingBase = nil
        }
    }

    for scalar in value.decomposedStringWithCanonicalMapping.unicodeScalars {
        if let base = pendingBase {
            if let macro = bibtexAccentSymbols[scalar.value] {
                out += "\\\(macro){\(base)}"
                pendingBase = nil
                continue
            }
            if let macro = bibtexAccentLetters[scalar.value] {
                out += "\\\(macro){\(base)}"
                pendingBase = nil
                continue
            }
        }
        let character = Character(scalar)
        if let macro = bibtexStandaloneLetters[character] {
            flush()
            out += macro
            continue
        }
        if scalar.properties.canonicalCombiningClass != .notReordered {
            continue // an accent this table does not know: keep the base, drop the mark
        }
        flush()
        pendingBase = character
    }
    flush()
    return out
}

/// Wraps every word past the first in an extra pair of braces, so a citation style that
/// lowercases everything but a title's first letter cannot touch a proper noun or an
/// acronym -- the "enclose the words ... in braces" convention (TeX FAQ, FAQ-capbibtex),
/// e.g. `The {Great} {API}`. The first word is left alone: every style capitalizes a
/// title's first letter regardless, so protecting it would only add noise.
public func bibtexProtectCapitals(_ value: String) -> String {
    let words = value.split(separator: " ", omittingEmptySubsequences: false)
    return words.enumerated().map { index, word in
        guard index > 0, word.contains(where: \.isUppercase) else { return String(word) }
        return "{\(word)}"
    }.joined(separator: " ")
}

/// Turns a single hyphen (or an en/em dash typed by mistake) between two page numbers
/// into BibTeX's own double dash, which TeX renders as the en dash a range needs --
/// "the standard styles convert a single dash ... to the double dash" (BibTeXing §3.2).
/// Already-doubled dashes, and anything that is not a plain number range (`43+`, a
/// single page), pass through unchanged.
public func bibtexPageRange(_ value: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "(\\d)\\s*[-\\u2010-\\u2015]+\\s*(\\d)")
    else { return value }
    let range = NSRange(value.startIndex..., in: value)
    return regex.stringByReplacingMatches(in: value, range: range, withTemplate: "$1--$2")
}

/// The twelve BibTeX month macros, keyed by every spelling this app accepts: the digit,
/// the zero-padded digit, the three-letter macro itself, and the full English name.
private let bibtexMonthNames: [String: String] = {
    let names = ["january", "february", "march", "april", "may", "june",
                 "july", "august", "september", "october", "november", "december"]
    var table: [String: String] = [:]
    for (index, name) in names.enumerated() {
        let macro = String(name.prefix(3))
        table[name] = macro
        table[macro] = macro
        table[String(index + 1)] = macro
        table[String(format: "%02d", index + 1)] = macro
    }
    return table
}()

/// The three-letter BibTeX month macro (`jan` … `dec`) for a month given as a number, an
/// abbreviation, or a full English name -- nil for anything else, so a caller can fall
/// back to writing the value as given rather than emit something that is not a macro.
public func bibtexMonthMacro(_ value: String) -> String? {
    bibtexMonthNames[value.trimmingCharacters(in: .whitespaces).lowercased()]
}

/// One BibTeX name in its four parts (BibTeXing §4, item 18): First, von, Last, and Jr --
/// "Ludwig van Beethoven" is First "Ludwig", von "van", Last "Beethoven"; "Gates, Jr,
/// Henry Louis" is Last "Gates", Jr "Jr", First "Henry Louis".
public struct BibName: Sendable, Equatable {
    public var first: String
    public var von: String
    public var last: String
    public var jr: String

    public init(first: String = "", von: String = "", last: String, jr: String = "") {
        self.first = first
        self.von = von
        self.last = last
        self.jr = jr
    }

    /// BibTeX's own canonical form, "von Last, Jr, First" -- the only one of the three
    /// input forms with no ambiguity about where each part ends.
    public var canonical: String {
        var out = von.isEmpty ? last : "\(von) \(last)"
        if !jr.isEmpty { out += ", \(jr)" }
        if !first.isEmpty { out += ", \(first)" }
        return out
    }
}

/// Splits `text` on `separator`, ignoring any occurrence inside braces -- exactly where
/// BibTeX itself stops looking, since a corporate author like "{Brace and Center}" is
/// braced specifically to keep BibTeX's own name-list splitter out of it.
private func splitOutsideBraces(_ text: String, on separator: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var depth = 0
    var index = text.startIndex
    while index < text.endIndex {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1 }
        if depth <= 0, text[index...].hasPrefix(separator) {
            parts.append(current)
            current = ""
            index = text.index(index, offsetBy: separator.count)
            continue
        }
        current.append(text[index])
        index = text.index(after: index)
    }
    parts.append(current)
    return parts
}

/// "a token is parsed as 'von' if its first letter ... is lower case" (BibTeXing §4).
private func lowercaseLed(_ token: Substring) -> Bool {
    token.first(where: \.isLetter)?.isLowercase ?? false
}

/// Splits space-separated name tokens into First/von/Last, per BibTeXing §4's own
/// algorithm: the von part is the run of lowercase-led tokens found before the final
/// token (which is always Last, however it is cased, so Last can never come up empty);
/// First is whatever comes before that run.
private func splitNameTokens(_ text: String) -> (first: String, von: String, last: String) {
    let tokens = text.split(separator: " ").filter { !$0.isEmpty }
    guard tokens.count > 1 else { return ("", "", tokens.first.map(String.init) ?? "") }

    var vonStart: Int?
    var vonEnd: Int?
    for index in 0..<(tokens.count - 1) where lowercaseLed(tokens[index]) {
        if vonStart == nil { vonStart = index }
        vonEnd = index
    }
    guard let start = vonStart, let end = vonEnd else {
        return (tokens.dropLast().joined(separator: " "), "", String(tokens.last!))
    }
    return (tokens[0..<start].joined(separator: " "),
            tokens[start...end].joined(separator: " "),
            tokens[(end + 1)...].joined(separator: " "))
}

/// Splits a BibTeX-style name list on the literal word " and " (never inside braces),
/// then each name into First/von/Last/Jr per BibTeXing §4: a comma splits "von Last"
/// from "First" (two commas puts "Jr" between them); with no comma, the name is read as
/// "First von Last".
public func parseBibNames(_ value: String) -> [BibName] {
    splitOutsideBraces(value, on: " and ").map { raw in
        let name = raw.trimmingCharacters(in: .whitespaces)
        let parts = splitOutsideBraces(name, on: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        switch parts.count {
        case 1:
            let (first, von, last) = splitNameTokens(parts[0])
            return BibName(first: first, von: von, last: last)
        case 2:
            let (_, von, last) = splitNameTokens(parts[0])
            return BibName(first: parts[1], von: von, last: last)
        default:
            let (_, von, last) = splitNameTokens(parts[0])
            return BibName(first: parts[2...].joined(separator: ", "), von: von, last: last, jr: parts[1])
        }
    }
}

/// Reparses and rejoins a name list in BibTeX's own canonical "von Last, Jr, First" form,
/// so "Ludwig van Beethoven and Knuth, Donald" and "van Beethoven, Ludwig and Knuth,
/// Donald" render identically.
public func canonicalAuthorList(_ value: String) -> String {
    parseBibNames(value).map(\.canonical).joined(separator: " and ")
}

/// Turns a normalized filename back into title words, dropping the date prefix.
private func titleWords(from filename: String) -> (title: String, year: String?) {
    let stem = (filename as NSString).deletingPathExtension
    var year: String?
    var rest = stem
    if let found = findDate(in: stem) {
        year = String(found.prefix.prefix(4))
        rest = (stem as NSString).replacingCharacters(in: found.range, with: " ")
    }
    let words = rest
        .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
        .map(String.init)
        .filter { !$0.isEmpty }
    return (words.joined(separator: " "), year)
}

/// A citation key in the usual shape: surname, year, first word of the title.
public func citationKey(author: String?, year: String?, title: String) -> String {
    func clean(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
    let surname = author.map { clean($0.split(separator: " ").last.map(String.init) ?? $0) } ?? ""
    let first = clean(title.split(separator: " ").first.map(String.init) ?? "")
    let parts = [surname, year ?? "", first].filter { !$0.isEmpty }
    return parts.isEmpty ? "entry" : parts.joined(separator: ":")
}

/// Builds entries for the given files. `known` supplies anything already learned about a
/// file, by `Item.key`; whatever is missing is read out of the name.
public func bibEntries(for items: [Item],
                       known: [String: BookGuess] = [:],
                       type: BibType = .book) -> [BibEntry] {
    var used: [String: Int] = [:]
    return items.map { item in
        let guess = known[item.key]
        let parsed = titleWords(from: item.destinationName)
        let title = guess?.title ?? parsed.title
        let year = guess?.year ?? parsed.year

        var key = citationKey(author: guess?.author, year: year, title: title)
        // Two works by the same author in the same year need telling apart.
        let count = used[key, default: 0]
        used[key] = count + 1
        if count > 0 { key += String(UnicodeScalar(UInt8(97 + min(count - 1, 25)))) }

        return BibEntry(itemKey: item.key, key: key, title: title, author: guess?.author,
                        year: year, file: item.destination.path, type: type)
    }
}

public enum BibOrder: String, Sendable, CaseIterable, Identifiable {
    /// By citation key, the order a .bib is usually kept in.
    case alphabetical
    /// Grouped by the folder each file sits in, matching what the browser shows.
    case folder

    public var id: String { rawValue }
    public var label: String { self == .alphabetical ? "Alphabetical" : "By folder" }
}

/// Orders entries for output without rendering them.
public func bibtexOrdered(_ entries: [BibEntry],
                          includeIncomplete: Bool = true,
                          order: BibOrder = .alphabetical) -> [BibEntry] {
    let usable = includeIncomplete ? entries : entries.filter(\.isComplete)
    switch order {
    case .alphabetical:
        return usable.sorted { $0.key < $1.key }
    case .folder:
        return usable.sorted {
            let a = ($0.file as NSString).deletingLastPathComponent
            let b = ($1.file as NSString).deletingLastPathComponent
            return a == b ? $0.key < $1.key : a < b
        }
    }
}

/// Formatting choices, matching what bibtex-tidy offers.
public struct BibStyle: Sendable, Equatable {
    public enum Delimiter: String, Sendable, CaseIterable, Identifiable {
        case braces, quotes
        public var id: String { rawValue }
        public var label: String { self == .braces ? "{braces}" : "\"quotes\"" }
        var open: String { self == .braces ? "{" : "\"" }
        var close: String { self == .braces ? "}" : "\"" }
    }

    /// Whether accented and other non-ASCII characters are written as LaTeX escapes, so
    /// the file survives a classic (non-biber) BibTeX run, or left as UTF-8, which is
    /// shorter and all a biber/biblatex pipeline needs.
    public enum UnicodeHandling: String, Sendable, CaseIterable, Identifiable {
        case preserve, escape
        public var id: String { rawValue }
        public var label: String { self == .preserve ? "Preserve" : "Escape" }
    }

    /// How a month value is written: as given, or as BibTeX's own three-letter bareword
    /// macro (`month = jul`), which needs no quoting and lets a style localize it.
    public enum MonthStyle: String, Sendable, CaseIterable, Identifiable {
        case asGiven, macro
        public var id: String { rawValue }
        public var label: String { self == .asGiven ? "As given" : "Macro (jan…dec)" }
    }

    /// Wrap values longer than this. Zero leaves them on one line.
    public var lineWidth: Int
    public var indent: String
    /// Pad field names so the `=` line up.
    public var align: Bool
    public var delimiter: Delimiter
    public var trailingComma: Bool
    /// A blank line between entries.
    public var blankLines: Bool
    /// Sort the fields within each entry rather than keeping the natural, bibtex-tidy-
    /// style order (title, author, year, month, journal, ...). `fieldOrder` below can
    /// still promote specific fields ahead of a plain alphabetical sort.
    public var sortFields: Bool
    /// Lowercase values written entirely in capitals, which OCR and catalogues produce.
    public var dropAllCaps: Bool
    /// Fields to leave out, by name. Defaults to just `file`: a source PDF's local path
    /// has no business in a bibliography meant for a paper, while every field this app
    /// can actually produce is shown until this says otherwise.
    public var omit: Set<String>
    /// Named fields are written first, in this order; anything left over keeps its usual
    /// place (or is sorted alphabetically, if `sortFields` is also on). Empty leaves the
    /// natural order untouched.
    public var fieldOrder: [String]
    /// Drop a field entirely rather than write it with an empty value.
    public var dropEmptyFields: Bool
    /// Write a value that is only digits (a year, a lone page number) bare, with no
    /// braces or quotes -- bibtex-tidy's --numeric.
    public var numericFields: Bool
    public var monthStyle: MonthStyle
    public var unicodeHandling: UnicodeHandling
    /// Brace-protect every word in the title but the first, so a case-changing citation
    /// style cannot touch a proper noun or an acronym.
    public var protectCapitals: Bool
    /// Reparse and rewrite `author`/`editor` into BibTeX's own canonical
    /// "von Last, Jr, First" form.
    public var canonicalizeAuthors: Bool
    /// Turn a single hyphen between two page numbers into BibTeX's double-dash range.
    public var normalizePageRanges: Bool

    public init(lineWidth: Int = 80,
                indent: String = "  ",
                align: Bool = true,
                delimiter: Delimiter = .braces,
                trailingComma: Bool = true,
                blankLines: Bool = true,
                sortFields: Bool = false,
                dropAllCaps: Bool = false,
                omit: Set<String> = ["file"],
                fieldOrder: [String] = [],
                dropEmptyFields: Bool = true,
                numericFields: Bool = false,
                monthStyle: MonthStyle = .asGiven,
                unicodeHandling: UnicodeHandling = .preserve,
                protectCapitals: Bool = false,
                canonicalizeAuthors: Bool = false,
                normalizePageRanges: Bool = false) {
        self.lineWidth = lineWidth
        self.indent = indent
        self.align = align
        self.delimiter = delimiter
        self.trailingComma = trailingComma
        self.blankLines = blankLines
        self.sortFields = sortFields
        self.dropAllCaps = dropAllCaps
        self.omit = omit
        self.fieldOrder = fieldOrder
        self.dropEmptyFields = dropEmptyFields
        self.numericFields = numericFields
        self.monthStyle = monthStyle
        self.unicodeHandling = unicodeHandling
        self.protectCapitals = protectCapitals
        self.canonicalizeAuthors = canonicalizeAuthors
        self.normalizePageRanges = normalizePageRanges
    }

    public static let standard = BibStyle()
}

/// Wraps on spaces, indenting continuations past the `=`. A word longer than the budget
/// is left whole: breaking a path or a URL to satisfy a column is worse than exceeding it.
func wrapped(_ value: String, width: Int, continuation: String) -> [String] {
    guard width > 0, value.count > width else { return [value] }
    var lines: [String] = []
    var current = ""
    for word in value.split(separator: " ", omittingEmptySubsequences: false) {
        let candidate = current.isEmpty ? String(word) : current + " " + word
        let budget = lines.isEmpty ? width : width - continuation.count
        if candidate.count > budget, !current.isEmpty {
            lines.append(current)
            current = String(word)
        } else {
            current = candidate
        }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
}

/// One entry, in the layout bibtex-tidy would leave behind.
///
/// Rendering per entry rather than per file is what lets the viewer highlight only what
/// is on screen: a collection of thousands would otherwise be tokenized in full on every
/// redraw.
public func bibtexBlock(_ entry: BibEntry, style: BibStyle = .standard) -> String {
    func maybeLower(_ value: String) -> String {
        guard style.dropAllCaps else { return value }
        let letters = value.filter(\.isLetter)
        guard !letters.isEmpty, letters == letters.uppercased() else { return value }
        return value.lowercased()
    }
    func authorLike(_ value: String) -> String {
        let lowered = maybeLower(value)
        return style.canonicalizeAuthors ? canonicalAuthorList(lowered) : lowered
    }

    let title = maybeLower(entry.title)

    // The natural order mirrors bibtex-tidy's own default field sort: title and the
    // people who made it, when and where it was made, then identifiers, then this app's
    // own addition (file) last.
    var candidates: [(name: String, value: String)] = [("title", title)]
    if let author = entry.author { candidates.append(("author", authorLike(author))) }
    if let editor = entry.editor { candidates.append(("editor", authorLike(editor))) }
    if let year = entry.year { candidates.append(("year", year)) }
    if let month = entry.month { candidates.append(("month", month)) }
    if let journal = entry.journal { candidates.append(("journal", maybeLower(journal))) }
    if let booktitle = entry.booktitle { candidates.append(("booktitle", maybeLower(booktitle))) }
    if let publisher = entry.publisher { candidates.append(("publisher", maybeLower(publisher))) }
    if let institution = entry.institution { candidates.append(("institution", maybeLower(institution))) }
    if let school = entry.school { candidates.append(("school", maybeLower(school))) }
    if let pages = entry.pages {
        candidates.append(("pages", style.normalizePageRanges ? bibtexPageRange(pages) : pages))
    }
    if let doi = entry.doi { candidates.append(("doi", doi)) }
    if let url = entry.url { candidates.append(("url", url)) }
    candidates.append(("file", entry.file))

    if style.dropEmptyFields { candidates.removeAll { $0.value.isEmpty } }
    candidates.removeAll { style.omit.contains($0.name) }

    // A raw field is written bare, with no delimiter: a month macro, or (with
    // numericFields on) any value that is only digits.
    var fields: [(name: String, value: String, raw: Bool)] = candidates.map { field in
        if field.name == "month", style.monthStyle == .macro, let macro = bibtexMonthMacro(field.value) {
            return (field.name, macro, true)
        }
        if style.numericFields, !field.value.isEmpty, field.value.allSatisfy(\.isNumber) {
            return (field.name, field.value, true)
        }
        return (field.name, field.value, false)
    }

    if !style.fieldOrder.isEmpty || style.sortFields {
        // uniquingKeysWith rather than uniqueKeysWithValues: a caller that lists the same
        // field twice should not crash the renderer over it.
        let priority = Dictionary(style.fieldOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        fields = fields.enumerated().sorted { a, b in
            switch (priority[a.element.name], priority[b.element.name]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                guard style.sortFields else { return a.offset < b.offset }
                return a.element.name == b.element.name ? a.offset < b.offset : a.element.name < b.element.name
            }
        }.map(\.element)
    }

    guard !fields.isEmpty else { return "@\(entry.type.keyword){\(entry.key),\n}" }

    let width = style.align ? (fields.map { $0.name.count }.max() ?? 0) : 0
    let body = fields.enumerated().map { index, field in
        let padding = String(repeating: " ", count: max(0, width - field.name.count))
        let comma = (style.trailingComma || index < fields.count - 1) ? "," : ""
        if field.raw {
            return "\(style.indent)\(field.name)\(padding) = \(field.value)\(comma)"
        }
        let prefix = "\(style.indent)\(field.name)\(padding) = \(style.delimiter.open)"
        let continuation = String(repeating: " ", count: prefix.count)
        let budget = style.lineWidth - prefix.count - style.delimiter.close.count - comma.count
        var escaped = bibtexEscape(field.value)
        if style.unicodeHandling == .escape { escaped = bibtexTransliterate(escaped) }
        // Brace-protection has to add its braces after escaping, not before: escaping
        // would otherwise treat the braces it just added as literal characters to guard.
        if field.name == "title", style.protectCapitals { escaped = bibtexProtectCapitals(escaped) }
        let lines = wrapped(escaped, width: budget, continuation: continuation)
        let joined = lines.enumerated()
            .map { $0.offset == 0 ? $0.element : continuation + $0.element }
            .joined(separator: "\n")
        return prefix + joined + style.delimiter.close + comma
    }.joined(separator: "\n")

    return "@\(entry.type.keyword){\(entry.key),\n\(body)\n}"
}

/// The whole file, for copying and saving.
public func bibtexDocument(_ entries: [BibEntry],
                           includeIncomplete: Bool = true,
                           order: BibOrder = .alphabetical,
                           style: BibStyle = .standard) -> String {
    let ordered = bibtexOrdered(entries, includeIncomplete: includeIncomplete, order: order)
    guard !ordered.isEmpty else { return "" }
    let separator = style.blankLines ? "\n\n" : "\n"
    return ordered.map { bibtexBlock($0, style: style) }.joined(separator: separator) + "\n"
}

// MARK: - Highlighting

public enum BibTokenKind: Sendable, Equatable {
    case entryType   // @book
    case key         // the citation key
    case field       // title, author, year, file
    case value       // what sits inside the braces
    case punctuation // braces, commas, equals
    case plain
}

public struct BibToken: Sendable, Equatable {
    public let text: String
    public let kind: BibTokenKind
}

/// Splits a .bib into coloured pieces.
///
/// Concatenating every token reproduces the input exactly, so highlighting can never
/// quietly drop or reorder a character of what is about to be saved. A test holds that.
public func bibtexTokens(_ text: String) -> [BibToken] {
    var tokens: [BibToken] = []
    func push(_ piece: String, _ kind: BibTokenKind) {
        guard !piece.isEmpty else { return }
        tokens.append(BibToken(text: piece, kind: kind))
    }

    // Keeping the separators means the join is lossless, newline for newline.
    let lines = text.components(separatedBy: "\n")
    for (index, line) in lines.enumerated() {
        defer { if index < lines.count - 1 { push("\n", .plain) } }

        if line.hasPrefix("@") {
            // @book{key,
            if let brace = line.firstIndex(of: "{") {
                push(String(line[line.startIndex..<brace]), .entryType)
                push("{", .punctuation)
                let rest = line[line.index(after: brace)...]
                if let comma = rest.firstIndex(of: ",") {
                    push(String(rest[rest.startIndex..<comma]), .key)
                    push(String(rest[comma...]), .punctuation)
                } else {
                    push(String(rest), .key)
                }
            } else {
                push(line, .entryType)
            }
            continue
        }

        // "  title = {value},"
        if let equals = line.firstIndex(of: "="), line.hasPrefix(" ") {
            push(String(line[line.startIndex..<equals]), .field)
            push("=", .punctuation)
            let rest = line[line.index(after: equals)...]
            if let open = rest.firstIndex(of: "{"), let close = rest.lastIndex(of: "}") , open < close {
                push(String(rest[rest.startIndex..<open]) + "{", .punctuation)
                push(String(rest[rest.index(after: open)..<close]), .value)
                push(String(rest[close...]), .punctuation)
            } else {
                push(String(rest), .value)
            }
            continue
        }

        push(line, line.trimmingCharacters(in: .whitespaces) == "}" ? .punctuation : .plain)
    }
    return tokens
}
