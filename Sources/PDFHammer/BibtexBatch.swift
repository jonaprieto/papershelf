import SwiftUI
import PDFHammerCore

/// Running "improve with AI" over many entries at once.
///
/// Doing this one entry at a time is fine for a paper and unbearable for a shelf, which is
/// the case this app is for. It is deliberately not automatic: every document is a billed
/// request, so it is asked for, it says how many, and it can be stopped.
@MainActor
final class BibtexBatch: ObservableObject {
    static let shared = BibtexBatch()

    struct Progress: Equatable {
        var done: Int
        var total: Int
        var improved: Int
        var unchanged: Int
        var failed: Int
    }

    @Published private(set) var progress: Progress?
    @Published private(set) var lastSummary: String?

    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// `entries` is what to work on, already narrowed by the caller: this does not decide
    /// what is worth improving, it does what it was asked.
    func run(_ entries: [BibEntry], client: AIClient, passwords: [String],
             library: Library?, kept: KeptBibtex, standard: BibStandard,
             text: @escaping (BibEntry) -> String) {
        guard progress == nil, !entries.isEmpty else { return }
        progress = Progress(done: 0, total: entries.count, improved: 0, unchanged: 0, failed: 0)
        lastSummary = nil

        task = Task { [weak self] in
            for entry in entries {
                if Task.isCancelled { break }
                let current = text(entry)
                let url = URL(fileURLWithPath: entry.file)
                // Reading the pages is the slow part and does not need the main actor.
                let excerpt = await Task.detached(priority: .utility) {
                    openingText(of: url, passwords: passwords, pages: 3)
                }.value

                do {
                    let reply = try await client.ask(
                        system: bibtexImproveInstruction,
                        user: bibtexImprovePrompt(entry: current,
                                                  filename: url.lastPathComponent,
                                                  excerpt: excerpt),
                        feature: .bibtex)
                    guard let improved = extractBibtexEntry(from: reply) else {
                        self?.tick(failed: true)
                        continue
                    }
                    if improved == current {
                        self?.tick(unchanged: true)
                        continue
                    }
                    await self?.keep(improved, for: entry, library: library, kept: kept)
                    self?.tick(improved: true)
                } catch {
                    if Task.isCancelled { break }
                    self?.tick(failed: true)
                }
            }
            self?.finish()
        }
    }

    private func tick(improved: Bool = false, unchanged: Bool = false, failed: Bool = false) {
        guard var current = progress else { return }
        current.done += 1
        if improved { current.improved += 1 }
        if unchanged { current.unchanged += 1 }
        if failed { current.failed += 1 }
        progress = current
    }

    /// Each answer is kept as it arrives rather than at the end, so a run that is
    /// cancelled or interrupted still leaves behind everything it already paid for.
    private func keep(_ entry: String, for bib: BibEntry, library: Library?,
                      kept: KeptBibtex) async {
        kept.remember(entry, at: [bib.itemKey, bib.file])
        guard let library else { return }
        for path in [bib.itemKey, bib.file] {
            guard let id = try? await library.document(atPath: path)?.id else { continue }
            try? await library.storeBibtex(entry, forDocument: id, origin: "the model")
            let places = (try? await library.locations(forDocument: id))?.map(\.path) ?? []
            kept.remember(entry, at: places)
            return
        }
    }

    private func finish() {
        if let done = progress {
            var parts: [String] = ["\(done.improved) improved"]
            if done.unchanged > 0 { parts.append("\(done.unchanged) already right") }
            if done.failed > 0 { parts.append("\(done.failed) failed") }
            lastSummary = parts.joined(separator: ", ")
        }
        progress = nil
        task = nil
    }
}
