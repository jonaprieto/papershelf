import SwiftUI
import PDFHammerCore

/// What is happening right now, apart from what is on the shelf.
///
/// It was thirty published fields on one object handed to every row, so a scan tick, an
/// AI request or a line in the log invalidated every card and every row on screen. These
/// fields change many times a second while work runs and are read by exactly two places —
/// the status bar and the busy overlay — so they publish on their own.
@MainActor
final class Activity: ObservableObject {
    @Published var done = 0
    @Published var total = 0
    @Published var found = 0
    /// The file being worked on, for the overlay to name.
    @Published var current = ""
    @Published private(set) var log: [LogEntry] = []
    /// The watcher folding in files it just noticed.
    @Published var absorbing = false
    @Published var lastAbsorbed = 0
    /// True while what is on screen came from the last launch rather than from a scan.
    @Published var showingCached = false

    func note(_ kind: LogEntry.Kind, subject: String, detail: String = "") {
        log.append(LogEntry(kind: kind, subject: subject, detail: detail))
    }

    func clearLog() { log = [] }

    func reset() {
        done = 0
        total = 0
        found = 0
        current = ""
        absorbing = false
        lastAbsorbed = 0
        showingCached = false
    }
}

/// What the model has been asked, and what it said.
///
/// Its own object for the reason the redesign named: a single request flipping `thinking`
/// for one file used to invalidate every row on screen, because the flag lived on the same
/// object the rows were handed.
@MainActor
final class Identifications: ObservableObject {
    /// What the model has said about a file, by `Item.key`. Keeps author and year, which a
    /// filename cannot carry, so a bibliography can use them.
    @Published private(set) var guesses: [String: BookGuess] = [:]
    @Published private(set) var thinking: Set<String> = []
    @Published var error: String?

    func isThinking(_ item: Item) -> Bool { thinking.contains(item.key) }

    /// Marks a file as being asked about, or says it already is.
    func begin(_ key: String) -> Bool {
        guard !thinking.contains(key) else { return false }
        thinking.insert(key)
        return true
    }

    func end(_ key: String) { thinking.remove(key) }

    func record(_ guess: BookGuess, for key: String) { guesses[key] = guess }

    func forget(_ key: String) { guesses[key] = nil }

    func forgetEverything() {
        guesses = [:]
        thinking = []
        error = nil
    }
}
