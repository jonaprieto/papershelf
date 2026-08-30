import Foundation

/// Where a planned name came from, said in pieces.
///
/// The reviewer's job is to agree or disagree with a name, and that is much easier when
/// the name is not a single opaque string. This reads the name the plan produced back
/// apart into the ingredients it was built from, and says the one or two things about it
/// that are worth knowing and can actually be checked: whether the year came from the
/// document rather than the filename, and which copy markers were dropped on the way.
///
/// Nothing here guesses. A part is only claimed when it can be found in the name, and a
/// note is only made when the evidence for it is in the item.
public struct NameProvenance: Equatable, Sendable {
    /// One ingredient: what it is, and what it contributed.
    public struct Part: Equatable, Sendable {
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public var parts: [Part]
    /// Short sentences about how the name was arrived at. Empty when there is nothing
    /// true to say, which is most files.
    public var notes: [String]

    public init(parts: [Part] = [], notes: [String] = []) {
        self.parts = parts
        self.notes = notes
    }

    public var isEmpty: Bool { parts.isEmpty && notes.isEmpty }
}

/// Copy markers a downloaded or duplicated file carries, and that the rename drops.
///
/// Matched case-insensitively against whole words, so a book actually called "Final Cut"
/// keeps its title. `(2)` and friends are matched as they are written.
private let copyMarkers = ["final", "copy", "draft", "v2", "v3", "new", "latest"]

/// A four-digit year, or a year and month, at the very start of a name.
private func leadingDate(of stem: String) -> (value: String, rest: String)? {
    let pattern = #"^((?:19|20)\d{2}(?:-\d{2})?)(?:[-_ ]+(.*))?$"#
    guard let match = stem.range(of: pattern, options: .regularExpression) else { return nil }
    let matched = String(stem[match])
    // The regular expression matched the whole string, so the pieces are taken by hand
    // rather than through capture groups, which `range(of:options:)` does not hand back.
    let separators = CharacterSet(charactersIn: "-_ ")
    guard let split = matched.rangeOfCharacter(from: separators,
                                               options: [],
                                               range: matched.index(matched.startIndex, offsetBy: 4)..<matched.endIndex)
    else {
        return (matched, "")
    }
    // A `YYYY-MM` date keeps its own dash: the first separator after it is the one that
    // ends the date, not the one inside it.
    var end = split.lowerBound
    if matched.distance(from: matched.startIndex, to: end) == 4,
       matched.count >= 7,
       matched[matched.index(matched.startIndex, offsetBy: 5)].isNumber {
        let monthEnd = matched.index(matched.startIndex, offsetBy: 7)
        end = monthEnd
    }
    let value = String(matched[matched.startIndex..<end])
    let rest = String(matched[end...]).trimmingCharacters(in: separators)
    return (value, rest)
}

/// Whether a name carries a year of its own anywhere in it.
private func carriesAYear(_ text: String) -> Bool {
    text.range(of: #"(?:19|20)\d{2}"#, options: .regularExpression) != nil
}

/// The words a name is made of, lowercased, with punctuation as the boundary.
private func words(of text: String) -> [String] {
    text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
}

/// What the planned name for `item` was built out of.
public func nameProvenance(for item: Item, guess: BookGuess? = nil) -> NameProvenance {
    let newStem = (item.destinationName as NSString).deletingPathExtension
    let oldStem = (item.sourceName as NSString).deletingPathExtension
    guard !newStem.isEmpty else { return NameProvenance() }

    var parts: [NameProvenance.Part] = []
    var rest = newStem

    if let date = leadingDate(of: newStem) {
        parts.append(NameProvenance.Part(label: "date", value: date.value))
        rest = date.rest
    }

    // An author is claimed only when the name actually starts with one. The rename writes
    // a surname, so that is what is looked for: the guess's, or the surname out of the
    // document's own author field.
    let statedAuthor = guess?.author ?? item.documentInfo["Author"]
    if let surname = surnameSlug(statedAuthor), !surname.isEmpty,
       rest.lowercased().hasPrefix(surname) {
        parts.append(NameProvenance.Part(label: "author", value: surname))
        rest = String(rest.dropFirst(surname.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
    }

    if !rest.isEmpty {
        parts.append(NameProvenance.Part(label: "title", value: rest))
    }

    return NameProvenance(parts: parts, notes: notes(new: newStem, old: oldStem, item: item))
}

/// The surname a rename would write, as it would be written: lowercased, one word.
private func surnameSlug(_ author: String?) -> String? {
    guard let author, !author.isEmpty else { return nil }
    // "Angrist, Joshua D." names the surname first; "Joshua D. Angrist" names it last.
    let surname = author.contains(",")
        ? author.components(separatedBy: ",").first
        : author.components(separatedBy: " ").last
    guard let surname else { return nil }
    return words(of: surname).first
}

/// The one or two things worth saying about how this name was arrived at.
private func notes(new: String, old: String, item: Item) -> [String] {
    var notes: [String] = []

    if carriesAYear(new), !carriesAYear(old) {
        // The date came from somewhere other than the name. Which somewhere is a fact the
        // item carries, so it is said rather than implied.
        if item.metadataDate != nil {
            notes.append("Year read from the document, not the filename \u{2014} "
                         + "the name carried none.")
        } else if item.modifiedDate != nil {
            notes.append("Year taken from the file's own date \u{2014} neither the name "
                         + "nor the document said.")
        }
    }

    let before = Set(words(of: old))
    let after = Set(words(of: new))
    let dropped = copyMarkers.filter { before.contains($0) && !after.contains($0) }
    // Numbered copies -- `(2)`, `(3)` -- read as markers only inside brackets, so a book
    // with a 2 in its title does not lose one.
    let numbered = old.ranges(of: #"\((\d+)\)"#).map { String(old[$0]) }
        .filter { !new.contains($0) }
    let markers = dropped.map { $0.uppercased() } + numbered
    if !markers.isEmpty {
        notes.append("\(listed(markers)) dropped as copy marker\(markers.count == 1 ? "" : "s").")
    }

    return notes
}

/// "A", "A and B", "A, B and C".
private func listed(_ items: [String]) -> String {
    guard items.count > 1 else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
}

private extension String {
    /// Every match of a regular expression, as ranges. `range(of:options:)` finds one.
    func ranges(of pattern: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var searched = startIndex..<endIndex
        while let next = range(of: pattern, options: .regularExpression, range: searched) {
            found.append(next)
            guard next.upperBound < endIndex else { break }
            searched = next.upperBound..<endIndex
        }
        return found
    }
}
