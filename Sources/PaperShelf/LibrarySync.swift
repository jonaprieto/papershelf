import Foundation
import PaperShelfCore
import os

/// Where `Runner` (defined in `App.swift`) meets the library.
///
/// This is an extension, not the class itself: `Runner` already exists, with its own
/// state and its own `preview`/`apply`/`absorbChanges`, and this file adds to it rather
/// than duplicating it. `Library.shared` is what makes that possible without any
/// constructor wiring: it is a process-wide singleton (see `Library.swift`), so a
/// method added here can reach the library without `Runner`'s own initialiser knowing
/// anything about it.
///
/// To finish connecting the two, one line belongs at the end of each of `preview`,
/// `apply`, and `absorbChanges` in `App.swift`, right after the existing call to
/// `finish(...)`: `Task { await self.syncLibrary(with: out) }` (`merged` in
/// `absorbChanges`). That line is not added here because it lands inside `Runner`'s own
/// file, which this task does not own.
extension Runner {

    /// Reconciles one finished batch of results into the library.
    ///
    /// A file that `process()` actually moved (renamed, decrypted in place, sent to a
    /// folder) keeps its identity: once the destination is known to be the same
    /// document as the source, `Library.recordLocation` attaches the new path to the
    /// existing row instead of `indexDocuments` inventing a second one. That is what
    /// keeps a rename from orphaning the user's tags, notes, and project membership
    /// (see the comment on `Item.currentURL` in `Hammer.swift`, and the type-level
    /// comment on `Library`). Everything else is a file simply seen at its current
    /// path, whether that is a first-time discovery or one already on record, and is
    /// folded into the library with a single batched call to `indexDocuments`.
    ///
    /// Silent on failure: a library that cannot be reached (see `Library.shared`) or a
    /// write that fails leaves the file on disk exactly as `process()` left it, and the
    /// next successful sync catches the library back up. Nothing about tagging, notes,
    /// or identity is a precondition for the app's actual job of renaming and converting
    /// PDFs, so a hiccup here must not surface as a failure of the run itself.
    func syncLibrary(with items: [Item]) async {
        guard let library = Library.shared else { return }

        var moved: [(item: Item, newPath: String)] = []
        var seen: [Library.IndexInput] = []
        for item in items where item.status != .failed {
            let current = item.currentURL.resolvingSymlinksInPath().path
            if item.carriedOut, current != item.key {
                moved.append((item, current))
            } else {
                seen.append(Library.IndexInput(
                    path: current, byteCount: item.byteCount, pageCount: item.pageCount,
                    title: item.documentInfo["Title"], author: item.documentInfo["Author"],
                    documentInfo: item.documentInfo))
            }
        }

        for move in moved {
            // The move is only "the same document under a new path" if the library
            // already knew it under the old one. If it did not (the library was down
            // when the file first appeared, say), there is nothing to attach the new
            // path to, so it is indexed as freshly seen instead of silently dropped.
            //
            // A lookup or write that *throws* is a real database failure (a full disk,
            // a corrupt file), not "path unknown", and must never be folded into that
            // same fallback: doing so would index the new path as a brand-new document
            // while the original row's tags and notes stay attached, untouched, to the
            // now-stale old path, silently orphaning them, which is exactly the bug
            // `recordLocation` exists to prevent. On a genuine failure this item is
            // skipped instead; the next successful sync catches it up.
            do {
                if let record = try await library.document(atPath: move.item.key) {
                    try await library.recordLocation(move.newPath, forDocument: record.id)
                } else {
                    seen.append(Library.IndexInput(
                        path: move.newPath, byteCount: move.item.byteCount, pageCount: move.item.pageCount,
                        title: move.item.documentInfo["Title"], author: move.item.documentInfo["Author"],
                        documentInfo: move.item.documentInfo))
                }
            } catch {
                Runner.logSyncFailure(error, path: move.newPath)
            }
        }
        if !seen.isEmpty {
            _ = try? await library.indexDocuments(seen)
        }
    }

    private static func logSyncFailure(_ error: Error, path: String) {
        Logger(subsystem: "com.jonaprieto.pdfhammer", category: "library")
            .error("library sync failed for \(path, privacy: .public), leaving it for the next sync: \(String(describing: error), privacy: .public)")
    }
}
