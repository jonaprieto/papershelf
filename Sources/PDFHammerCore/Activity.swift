import Foundation

/// One thing that happened, recorded as it happened.
///
/// The log is a statement of fact, not a plan: entries are only added once something has
/// actually been decided or carried out, so a saved log can be read back as an account of
/// what the app did to a collection.
public struct LogEntry: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case scanned, previewed
        case confirmed, edited, skipped, removed
        case renamed, decrypted, moved, trashed, applied
        case failed
    }

    public let id: UUID
    public let at: Date
    public let kind: Kind
    /// The file this concerns, as a path relative to its source where possible.
    public let subject: String
    public let detail: String

    public init(id: UUID = UUID(), at: Date = Date(), kind: Kind,
                subject: String, detail: String = "") {
        self.id = id
        self.at = at
        self.kind = kind
        self.subject = subject
        self.detail = detail
    }
}

private let logStamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

/// Renders the log as fixed-width columns: timestamp, what happened, to what.
///
/// Deliberately greppable rather than pretty. A log is read when something has gone
/// wrong, and at that point being able to pipe it through grep matters more than
/// alignment.
public func logText(_ entries: [LogEntry]) -> String {
    guard !entries.isEmpty else { return "" }
    let width = entries.map { $0.kind.rawValue.count }.max() ?? 0
    return entries.map { entry in
        let kind = entry.kind.rawValue.padding(toLength: width, withPad: " ", startingAt: 0)
        let tail = entry.detail.isEmpty ? "" : "  \(entry.detail)"
        return "\(logStamp.string(from: entry.at))  \(kind)  \(entry.subject)\(tail)"
    }.joined(separator: "\n") + "\n"
}
