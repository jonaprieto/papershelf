import Foundation
import PaperShelfCore

/// Reading the shelf's text into the library, so a search can ask about what is inside a
/// document rather than only what its name says.
///
/// This is the one pass in the app that deliberately opens every file, so it is opt-in,
/// interruptible, and resumable: it asks the library what it already has, does only what
/// is left, and writes as it goes. Stopping it halfway loses nothing but the file in
/// flight. A file it cannot open is counted once and left alone; on a disk that has
/// stopped answering, that is the difference between one failed read per file and one per
/// launch, forever.
extension Runner {
    func indexText(passwords: [String]) {
        guard Library.shared != nil, !results.isEmpty, !activity.indexing else { return }
        let snapshot = results
        indexGeneration &+= 1
        let generation = indexGeneration
        activity.indexing = true
        activity.indexed = 0
        activity.indexTotal = 0
        activity.indexFailures = 0

        indexTask = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.finishIndexing(generation) } }
            guard let library = Library.shared,
                  let rows = try? await library.textIndexRows() else { return }

            let byPath = Dictionary(rows.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            let modified = Dictionary(snapshot.map { ($0.key, $0.modifiedDate) },
                                      uniquingKeysWith: { first, _ in first })
            let work = snapshot.compactMap { item -> (id: String, url: URL)? in
                guard let row = byPath[item.key] else { return nil }
                guard needsIndexing(extractedAt: row.extractedAt,
                                    fileModified: modified[item.key] ?? nil,
                                    format: row.format) else { return nil }
                return (row.documentID, item.currentURL)
            }
            guard !work.isEmpty else { return }
            await MainActor.run { self?.activity.indexTotal = work.count }

            // In batches, so a run that is stopped or crashes keeps what it has read, and
            // so fourteen thousand documents are not fourteen thousand transactions.
            let batchSize = 50
            var index = 0
            while index < work.count {
                guard !Task.isCancelled else { return }
                let slice = Array(work[index..<min(index + batchSize, work.count)])
                let read = await Self.readText(slice, passwords: passwords)
                guard !Task.isCancelled else { return }
                // `setExtractedText` is one transaction for the whole batch, so either
                // every document read here lands in the library or none of them do. A
                // rolled-back write leaves the batch exactly as unsearchable as a read
                // failure, so it counts the same way rather than as indexed.
                var wrote = true
                do {
                    try await library.setExtractedText(read.stored)
                } catch {
                    wrote = false
                }
                await MainActor.run {
                    guard let self, self.indexGeneration == generation else { return }
                    self.activity.indexed += wrote ? slice.count : 0
                    self.activity.indexFailures += wrote ? read.failures : slice.count
                    self.activity.current = read.last
                }
                index += batchSize
            }
        }
    }

    func stopIndexing() {
        indexGeneration &+= 1
        indexTask?.cancel()
        indexTask = nil
        activity.indexing = false
        activity.current = ""
    }

    /// One batch, read across every core. Extraction is the whole cost here and it is all
    /// disk and PDFKit, neither of which belongs on the main actor.
    nonisolated static func readText(
        _ work: [(id: String, url: URL)], passwords: [String]
    ) async -> (stored: [(documentID: String, markdown: String, format: TextFormat)], failures: Int, last: String) {
        await Task.detached(priority: .utility) {
            var stored = [(documentID: String, markdown: String, format: TextFormat)]()
            var failures = 0
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: work.count) { index in
                let job = work[index]
                // Nil means the file would not open, which is what the caller counts as
                // a failure worth retrying.
                let result = indexedMarkdown(of: job.url, passwords: passwords)
                lock.lock()
                if let result {
                    stored.append((documentID: job.id, markdown: result.text, format: result.format))
                } else {
                    failures += 1
                }
                lock.unlock()
            }
            return (stored, failures, work.last?.url.lastPathComponent ?? "")
        }.value
    }

    @MainActor
    private func finishIndexing(_ generation: Int) {
        guard indexGeneration == generation else { return }
        activity.indexing = false
        activity.current = ""
        indexTask = nil
        Task { await refreshIndexedCount() }
    }

    /// How much of the shelf can answer a text query, for the search bar to say so.
    func refreshIndexedCount() async {
        guard let library = Library.shared else { return }
        setIndexedTextCount((try? await library.indexedTextCount()) ?? 0)
    }
}
