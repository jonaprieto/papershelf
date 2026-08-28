import SwiftUI
import PDFHammerCore

/// The four questions about a collection that are asked often enough to be worth a row
/// each: what is there, what is open, what just arrived, and what has not been filed.
///
/// They are not searches. `Unfiled` cannot be typed into a search box because "has no
/// tags" is not a term the query language has, and "opened but not finished" is a fact
/// about the reader rather than about the file.
enum SmartList: String, CaseIterable, Identifiable, Codable {
    case all, reading, recent, unfiled
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Documents"
        case .reading: return "Reading Now"
        case .recent: return "Recently Added"
        case .unfiled: return "Unfiled"
        }
    }

    var icon: String {
        switch self {
        case .all: return "books.vertical"
        case .reading: return "book"
        case .recent: return "clock"
        case .unfiled: return "tray"
        }
    }

    var explanation: String {
        switch self {
        case .all: return "Everything the sources hold"
        case .reading: return "Opened past the first page and not finished"
        case .recent: return "Seen for the first time in the last two weeks"
        case .unfiled: return "Carrying no tag at all"
        }
    }
}

/// Which paths belong to each list, and which list the shelf is showing.
///
/// One object because two views need the same answer: the sidebar counts the rows and the
/// results pane filters by them, and two copies of that query would disagree the moment a
/// file was tagged.
@MainActor
final class Shelves: ObservableObject {
    static let shared = Shelves()

    @Published var current: SmartList = .all
    @Published private(set) var reading: Set<String> = []
    @Published private(set) var recent: Set<String> = []
    @Published private(set) var unfiled: Set<String> = []
    /// Bumped whenever the sets change, so a cached filter knows to recompute.
    @Published private(set) var revision = 0

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
        let (a, b, c) = await (beingRead, added, untagged)
        reading = a ?? []
        recent = b ?? []
        unfiled = c ?? []
        revision &+= 1
    }

    /// Whether a file is in a list. Both of its paths are asked about: a renamed file is
    /// still the file that was being read, and the shelf may hold either name.
    func contains(_ item: Item, in list: SmartList) -> Bool {
        switch list {
        case .all: return true
        case .reading: return matches(item, reading)
        case .recent: return matches(item, recent)
        case .unfiled: return matches(item, unfiled)
        }
    }

    func count(_ list: SmartList, among items: [Item]) -> Int {
        guard list != .all else { return items.count }
        return items.reduce(0) { $0 + (contains($1, in: list) ? 1 : 0) }
    }

    private func matches(_ item: Item, _ paths: Set<String>) -> Bool {
        paths.contains(item.key) || paths.contains(item.currentURL.resolvingSymlinksInPath().path)
    }
}
