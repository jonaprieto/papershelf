import Foundation

/// One bibliography record. Everything but the file path may be missing, and a missing
/// field is reported rather than filled in with a guess.
public struct BibEntry: Identifiable, Sendable, Equatable {
    /// The `Item.key` this came from, so a row here can point back at the file.
    public var itemKey: String
    public var key: String
    public var title: String
    public var author: String?
    public var year: String?
    public var file: String

    public var id: String { itemKey }

    /// Fields a usable entry needs. Shown so the gaps can be filled deliberately.
    public var missing: [String] {
        var gaps: [String] = []
        if author == nil { gaps.append("author") }
        if year == nil { gaps.append("year") }
        if title.isEmpty { gaps.append("title") }
        return gaps
    }

    public var isComplete: Bool { missing.isEmpty }
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
public func bibEntries(for items: [Item], known: [String: BookGuess] = [:]) -> [BibEntry] {
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
                        year: year, file: item.destination.path)
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

/// One entry, in the layout bibtex-tidy would leave behind: one field per line, aligned,
/// trailing commas.
///
/// Rendering per entry rather than per file is what lets the viewer highlight only what
/// is on screen: a collection of thousands would otherwise be tokenized in full on every
/// redraw.
public func bibtexBlock(_ entry: BibEntry) -> String {
    var fields: [(String, String)] = [("title", entry.title)]
    if let author = entry.author { fields.append(("author", author)) }
    if let year = entry.year { fields.append(("year", year)) }
    fields.append(("file", entry.file))

    let width = fields.map(\.0.count).max() ?? 5
    let body = fields.map { name, value in
        let padding = String(repeating: " ", count: width - name.count)
        return "  \(name)\(padding) = {\(bibtexEscape(value))},"
    }.joined(separator: "\n")

    return "@book{\(entry.key),\n\(body)\n}"
}

/// The whole file, for copying and saving.
public func bibtexDocument(_ entries: [BibEntry],
                           includeIncomplete: Bool = true,
                           order: BibOrder = .alphabetical) -> String {
    let ordered = bibtexOrdered(entries, includeIncomplete: includeIncomplete, order: order)
    guard !ordered.isEmpty else { return "" }
    return ordered.map(bibtexBlock).joined(separator: "\n\n") + "\n"
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
