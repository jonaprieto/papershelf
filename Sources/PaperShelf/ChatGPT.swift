import SwiftUI
import AppKit
import PaperShelfCore

/// Handing a passage to the ChatGPT app.
///
/// The app registers a `codex://` scheme (its bundle identifier is com.openai.codex; there
/// is no `chatgpt://`), and `threads/new?prompt=` opens a new conversation with the text in
/// the composer. It does not send it: the person decides that, which is the right way round
/// for something that leaves the machine.
///
/// An existing conversation cannot be targeted. The app only addresses a thread by an
/// identifier it assigned itself, so there is no way to say "the one I have open". Copying
/// is the only route into a conversation already in progress, which is why both are offered.
enum ChatGPTHandoff {

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "codex://threads/new")!) != nil
    }

    /// A passage, with enough around it that the answer is about the right document.
    static func prompt(quoted: String, note: String, page: Int?, title: String) -> String {
        var out = "From \(title)"
        if let page { out += ", page \(page)" }
        out += ":\n\n"
        out += quoted.split(separator: "\n").map { "> " + $0 }.joined(separator: "\n")
        if !note.isEmpty { out += "\n\nMy note: \(note)" }
        out += "\n\n"
        return out
    }

    /// The complete current export, ready to become context in a new conversation.
    static func notesPrompt(title: String, markdown: String) -> String {
        "These are my current highlights and notes from \(title). Use them as context "
            + "for this conversation:\n\n" + markdown
    }

    /// Opens a new conversation with the passage already in the composer.
    @discardableResult
    static func open(_ prompt: String) -> Bool {
        var allowed = CharacterSet.urlQueryAllowed
        // These are legal in a query by RFC 3986 and ambiguous in practice, so they are
        // escaped rather than left for the receiving app to guess at.
        allowed.remove(charactersIn: "+&=?#")
        guard let encoded = prompt.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "codex://threads/new?prompt=\(encoded)")
        else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// For a conversation already open, which no deep link can reach.
    static func copy(_ prompt: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
    }
}
