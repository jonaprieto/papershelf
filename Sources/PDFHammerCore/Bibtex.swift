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

/// Renders entries as a .bib file, in the layout bibtex-tidy would leave behind: one
/// field per line, aligned, trailing commas, entries sorted by key.
public func bibtexDocument(_ entries: [BibEntry], includeIncomplete: Bool = true) -> String {
    let usable = includeIncomplete ? entries : entries.filter(\.isComplete)
    guard !usable.isEmpty else { return "" }

    return usable.sorted { $0.key < $1.key }.map { entry -> String in
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
    }.joined(separator: "\n\n") + "\n"
}
