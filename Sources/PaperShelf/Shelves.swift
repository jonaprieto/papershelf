import SwiftUI
import PaperShelfCore

/// The four questions about a collection that are asked often enough to be worth a row
/// each: what is there, what is open, what just arrived, and what has not been filed.
///
/// They are not searches. `Unfiled` cannot be typed into a search box because "has no
/// tags" is not a term the query language has, and "opened but not finished" is a fact
/// about the reader rather than about the file.
enum SmartList: String, CaseIterable, Identifiable, Codable, Equatable {
    case all, reading, recent, unfiled, opened
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Documents"
        case .reading: return "Reading Now"
        case .recent: return "Recently Added"
        case .unfiled: return "Unfiled"
        case .opened: return "Opened"
        }
    }

    var icon: String {
        switch self {
        case .all: return "books.vertical"
        case .reading: return "book"
        case .recent: return "clock"
        case .unfiled: return "tray"
        case .opened: return "clock.arrow.circlepath"
        }
    }

    var explanation: String {
        switch self {
        case .all: return "Everything the sources hold"
        case .reading: return "Opened past the first page and not finished"
        case .recent: return "Seen for the first time in the last two weeks"
        case .unfiled: return "Carrying no tag at all"
        case .opened: return "Read from outside your sources"
        }
    }
}

/// Which paths belong to each list, and which list the shelf is showing.
///
/// One object because two views need the same answer: the sidebar counts the rows and the
/// results pane filters by them, and two copies of that query would disagree the moment a
/// file was tagged.
@MainActor
@Observable
final class Shelves {
    static let shared = Shelves()

    var current: SmartList = .all
    private(set) var reading: Set<String> = []
    private(set) var recent: Set<String> = []
    private(set) var unfiled: Set<String> = []
    /// Documents that have been opened and whose files sit under no source, newest first.
    ///
    /// A list rather than a set, and of URLs rather than paths, because this one is not a
    /// filter over what the shelf scanned: those files are in no folder the app scans, so
    /// the shelf is pointed at them directly.
    private(set) var openedElsewhere: [URL] = []
    /// Bumped whenever the sets change, so a cached filter knows to recompute.
    private(set) var revision = 0

    /// How far back "recently added" reaches. Two weeks: long enough that a weekend's
    /// downloads are still there on Monday, short enough that the list is not the shelf.
    static let recentDays = 14

    private init() {}

    func refresh() async {
        guard let library = Library.shared else { return }
        let since = Date().addingTimeInterval(-Double(Shelves.recentDays) * 86_400)
        async let beingRead = try? library.pathsBeingRead()
        async let added = try? library.pathsFirstSeen(since: since)
        async let untagged = try? library.pathsWithoutTags()
        async let read = try? library.openedPaths()
        let (a, b, c, d) = await (beingRead, added, untagged, read)
        reading = a ?? []
        recent = b ?? []
        unfiled = c ?? []
        openedElsewhere = (d ?? []).map { URL(fileURLWithPath: $0.path) }
            .filter { url in
                let path = url.resolvingSymlinksInPath().path
                return FileManager.default.fileExists(atPath: url.path)
                    && !sources.contains { path.hasPrefix($0.resolvingSymlinksInPath().path + "/") }
            }
        revision &+= 1
    }

    /// The folders the shelf is built from, so `refresh` can tell which opened documents
    /// are already on it. Set by the window that owns the sources.
    var sources: [URL] = []

    /// Whether a file is in a list. Both of its paths are asked about: a renamed file is
    /// still the file that was being read, and the shelf may hold either name.
    func contains(_ item: Item, in list: SmartList) -> Bool {
        switch list {
        case .all: return true
        case .reading: return matches(item, reading)
        case .recent: return matches(item, recent)
        case .unfiled: return matches(item, unfiled)
        // Everything the shelf holds while this list is showing was scanned because it is
        // on this list: the roots are the opened files themselves.
        case .opened: return true
        }
    }

    func count(_ list: SmartList, among items: [Item]) -> Int {
        guard list != .all else { return items.count }
        // Counted from the library rather than from what is on screen: these documents are
        // not among the shelf's items unless this list is the one showing.
        guard list != .opened else { return openedElsewhere.count }
        return items.reduce(0) { $0 + (contains($1, in: list) ? 1 : 0) }
    }

    private func matches(_ item: Item, _ paths: Set<String>) -> Bool {
        paths.contains(item.key) || paths.contains(item.currentURL.resolvingSymlinksInPath().path)
    }
}
