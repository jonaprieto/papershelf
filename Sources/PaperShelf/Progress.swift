import SwiftUI
import PaperShelfCore

/// What is happening right now, apart from what is on the shelf.
///
/// It was thirty published fields on one object handed to every row, so a scan tick, an
/// AI request or a line in the log invalidated every card and every row on screen. These
/// fields change many times a second while work runs and are read by exactly two places —
/// the status bar and the busy overlay — so they were split onto an object of their own.
///
/// Observation would now keep a scan tick off a card that does not read these, so the
/// split is no longer what saves the shelf. It stays because these two readers are the
/// only ones, and an object whose readers are named is easier to reason about than thirty
/// more properties on `Runner`.
@MainActor
@Observable
final class Activity {
    var done = 0
    var total = 0
    var found = 0
    /// The file being worked on, for the overlay to name.
    var current = ""
    private(set) var log: [LogEntry] = []
    /// The watcher folding in files it just noticed.
    var absorbing = false
    var lastAbsorbed = 0
    /// True while what is on screen came from the last launch rather than from a scan.
    var showingCached = false
    /// Reading documents' text so it can be searched. Deliberately not a `phase`: the
    /// shelf stays usable while it runs, and going busy would blank it.
    var indexing = false
    var indexed = 0
    var indexTotal = 0
    /// Files the indexer could not open. Counted rather than listed: on a failing disk
    /// this is every file, and a list of fourteen thousand names says nothing a number
    /// does not.
    var indexFailures = 0

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
        indexing = false
        indexed = 0
        indexTotal = 0
        indexFailures = 0
    }
}

/// What the model has been asked, and what it said.
///
/// Its own object for the reason the redesign named: a single request flipping `thinking`
/// for one file used to invalidate every row on screen, because the flag lived on the same
/// object the rows were handed.
@MainActor
@Observable
final class Identifications {
    /// What the model has said about a file, by `Item.key`. Keeps author and year, which a
    /// filename cannot carry, so a bibliography can use them.
    private(set) var guesses: [String: BookGuess] = [:]
    private(set) var thinking: Set<String> = []
    var error: String?

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
