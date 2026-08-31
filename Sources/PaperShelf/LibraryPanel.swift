import SwiftUI
import AppKit
import PaperShelfCore

/// What the library holds, for the one line that says so.
///
/// This was a sidebar tab: a summary, a search box and a link to the projects, all of
/// which now live where they are used. The search is the toolbar's field, the projects
/// are a sidebar section, the database is in Settings, and the count is a phrase in the
/// status bar — which is where a fact about the whole library belongs, beside the rest of
/// what is true right now.
@MainActor
@Observable
final class LibraryStatus {
    static let shared = LibraryStatus()

    private(set) var summary: LibrarySummary?

    private init() {}

    func refresh() async {
        guard let library = Library.shared else { return }
        summary = try? await library.summary()
    }

    /// "1,284 documents · 96% indexed", or nil when the library could not be opened.
    var label: String? {
        guard let summary else { return nil }
        let documents = summary.documents.formatted()
        guard summary.documents > 0 else { return "Library empty" }
        let indexed = Int((Double(summary.withText) / Double(summary.documents) * 100).rounded())
        let search = indexed == 0 ? "text search not ready" : "\(indexed)% text searchable"
        return "Library · \(documents) document\(summary.documents == 1 ? "" : "s") · \(search)"
    }
}
