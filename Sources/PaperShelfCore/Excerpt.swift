import Foundation

/// A passage worth quoting back, and where it came from.
public struct Excerpt: Sendable, Equatable {
    public var text: String
    /// Nil when the stored text carries no marker before this passage, which is what text
    /// written before page markers existed looks like.
    public var page: Int?

    public init(text: String, page: Int?) {
        self.text = text
        self.page = page
    }
}

private let pageMarker = "## Page "

/// The page a position in page-marked Markdown falls on.
///
/// The marker's own number is read rather than markers counted. `indexedMarkdown` and
/// `markdownFromPDF` both skip a page with no text entirely, its marker included, so in a
/// book with one blank page the nth marker is not page n. Counting would be quietly wrong
/// on exactly the documents nobody checks.
public func pageNumber(in markdown: String, before offset: String.Index) -> Int? {
    guard let marker = markdown.range(of: pageMarker, options: .backwards,
                                      range: markdown.startIndex..<offset) else { return nil }
    let digits = markdown[marker.upperBound...].prefix { $0.isNumber }
    return Int(digits)
}

/// The passages in `markdown` that match `phrase`, each with the page it is on.
///
/// Matching is case and diacritic insensitive, which is what a reader means by a phrase.
/// When the phrase does not appear verbatim the longest word in it is tried instead: FTS5
/// ranks on tokens, so a document can legitimately match a phrase it does not contain in
/// that exact order, and a hit with no quotable passage is worse than a slightly wider one.
public func excerpts(in markdown: String, matching phrase: String,
                     limit: Int = 2, radius: Int = 160) -> [Excerpt] {
    guard limit > 0 else { return [] }
    let needles = [phrase.trimmingCharacters(in: .whitespacesAndNewlines)]
        + [longestWord(in: phrase)].compactMap { $0 }
    for needle in needles where !needle.isEmpty {
        let found = passages(in: markdown, matching: needle, limit: limit, radius: radius)
        if !found.isEmpty { return found }
    }
    return []
}

private func longestWord(in phrase: String) -> String? {
    phrase.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map(String.init)
        .filter { $0.count >= 4 }
        .max(by: { $0.count < $1.count })
}

private func passages(in markdown: String, matching needle: String,
                      limit: Int, radius: Int) -> [Excerpt] {
    var found: [Excerpt] = []
    var searchFrom = markdown.startIndex
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    while found.count < limit,
          let match = markdown.range(of: needle, options: options,
                                     range: searchFrom..<markdown.endIndex) {
        let page = pageNumber(in: markdown, before: match.lowerBound)
        let rawStart = markdown.index(match.lowerBound, offsetBy: -radius,
                                      limitedBy: markdown.startIndex) ?? markdown.startIndex
        let rawEnd = markdown.index(match.upperBound, offsetBy: radius,
                                    limitedBy: markdown.endIndex) ?? markdown.endIndex
        // A character-counted radius can stop partway through a marker line rather than
        // before or after it. `cleaned(_:)` only ever drops whole lines, so a boundary left
        // there would leak a fragment such as "ge 2" into the quote instead of the digit-free
        // prose the marker is meant to be invisible around. Pulling back to the marker's own
        // edge keeps the window from ever bisecting one; the match itself is never given up
        // for this, in case the match lies inside a marker line rather than beside it.
        let start = min(excludingMarker(rawStart, in: markdown, keepingBefore: false), match.lowerBound)
        let end = max(excludingMarker(rawEnd, in: markdown, keepingBefore: true), match.upperBound)
        found.append(Excerpt(text: cleaned(String(markdown[start..<end])), page: page))
        searchFrom = match.upperBound
    }
    return found
}

/// `index`, moved outside the `## Page N` line it falls inside, if any.
///
/// Moving always shrinks the window rather than grows it, since growing toward the marker's
/// far side could just as easily run into a second one on a short enough page. `keepingBefore`
/// picks which edge of the marker's line to stop at: `false` is for a window's start, which
/// should land just past the line (later, toward the match); `true` is for a window's end,
/// which should land just before it (earlier, toward the match).
private func excludingMarker(_ index: String.Index, in markdown: String, keepingBefore: Bool) -> String.Index {
    let lineStart = markdown.range(of: "\n", options: .backwards,
                                   range: markdown.startIndex..<index)?.upperBound ?? markdown.startIndex
    let lineEnd = markdown.range(of: "\n", range: index..<markdown.endIndex)?.lowerBound ?? markdown.endIndex
    guard markdown[lineStart..<lineEnd].hasPrefix(pageMarker) else { return index }
    return keepingBefore ? lineStart : lineEnd
}

/// A marker is structure, not prose: a quote that carries one reads as though the document
/// said "## Page 7". Whitespace is collapsed for the same reason, since a PDF's own line
/// breaks are set for a page width nobody is reading this at.
private func cleaned(_ passage: String) -> String {
    passage
        .split(separator: "\n")
        .filter { !$0.hasPrefix(pageMarker) }
        .joined(separator: " ")
        .split(separator: " ", omittingEmptySubsequences: true)
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
