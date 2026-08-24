import Foundation
import PDFKit

/// What a model is asked to pull out of a book's opening pages.
public struct BookGuess: Sendable, Equatable {
    public var title: String
    public var author: String?
    public var year: String?

    public init(title: String, author: String? = nil, year: String? = nil) {
        self.title = title
        self.author = author
        self.year = year
    }
}

/// Instruction sent as the system message. Kept blunt: a model that invents an author is
/// worse than one that leaves the field out, because the invention lands in a filename.
public let bookGuessInstruction = """
You identify books and documents from their opening pages.
Reply with one JSON object and nothing else: {"title": string, "author": string or null, \
"year": string or null}.
Use the work's own title, not the publisher's or the series'. Use the surname only for \
the author. Use the year of this edition if it is stated.
If the text does not say, use null. Never guess, and never invent a value to fill a field.
"""

/// The user message: the filename first, since it is often the only real clue when the
/// first page is a scanned image with no text layer.
public func bookGuessPrompt(filename: String, excerpt: String, limit: Int = 1800) -> String {
    let trimmed = excerpt
        .replacingOccurrences(of: "\u{0}", with: " ")
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    let clipped = trimmed.count > limit ? String(trimmed.prefix(limit)) : trimmed
    return """
    Filename: \(filename)

    Opening text:
    \(clipped.isEmpty ? "(none, the pages carry no text layer)" : clipped)
    """
}

/// Reads the model's reply. Tolerates a code fence and any prose around the object,
/// because models add both however firmly you ask them not to.
public func parseBookGuess(_ reply: String) -> BookGuess? {
    guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end
    else { return nil }
    let json = String(reply[start...end])
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    func text(_ key: String) -> String? {
        switch object[key] {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // Models write the string "null" surprisingly often.
            return trimmed.isEmpty || trimmed.lowercased() == "null" ? nil : trimmed
        case let value as Int: return String(value)
        default: return nil
        }
    }

    guard let title = text("title") else { return nil }
    return BookGuess(title: title, author: text("author"), year: text("year"))
}

/// Builds a filename from a guess, through the same rules everything else goes through.
///
/// The year leads, so `normalizedName` reads it as the date rather than picking a number
/// out of the title: for `1984` published in `1949`, the prefix must be 1949.
public func filename(for guess: BookGuess, rules: NameRules = .standard) -> String {
    let parts = [guess.year, guess.title, guess.author]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard !parts.isEmpty else { return "" }
    return normalizedName(for: parts.joined(separator: " ") + ".pdf", rules: rules)
}

/// Text from the opening pages, for sending to a model. Returns an empty string for a
/// scan with no text layer, which is a normal outcome rather than a failure.
public func openingText(of url: URL, passwords: [String], pages: Int = 3) -> String {
    guard let document = PDFDocument(url: url) else { return "" }
    if document.isLocked {
        for password in passwords where document.unlock(withPassword: password) { break }
    }
    var collected = ""
    for index in 0..<min(pages, document.pageCount) {
        guard let text = document.page(at: index)?.string else { continue }
        collected += text + "\n"
        if collected.count > 4000 { break }
    }
    return collected
}


/// Model families that cannot answer a chat request, by the words their names carry.
private let nonChatMarkers = [
    "embedding", "whisper", "tts", "dall-e", "moderation", "audio", "realtime",
    "image", "search", "similarity", "edit", "davinci", "babbage", "transcribe",
]

/// Whether a model id is worth offering. Deliberately permissive: an OpenAI-compatible
/// endpoint names its models whatever it likes, and hiding one the user has is worse than
/// listing one they cannot use.
public func looksLikeChatModel(_ id: String) -> Bool {
    let lowered = id.lowercased()
    return !nonChatMarkers.contains { lowered.contains($0) }
}
