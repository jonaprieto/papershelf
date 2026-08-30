import Foundation
import PDFKit
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

        // `document(atPath:)` below and the `recordLocation` it feeds are two separate
        // awaits on the `Library` actor, not one atomic call, so two `syncLibrary` calls
        // racing each other -- a real run finishing while the watcher's own sync for an
        // earlier batch is still in flight, say -- can interleave: the second call's
        // lookup lands in the gap before the first call's write, finds the document still
        // on record at its old path, and folds the new path into `indexDocuments` as a
        // second document, while the first call goes on to attach the original row's tags
        // and notes to a path that no longer exists. A `Library` method cannot fix this by
        // itself, since the race is between two awaits, not inside either one; `syncLibrary`
        // has to serialize its own callers instead. `syncGate` below does exactly that: it
        // is held for the whole body, so a second call's lookup can only start once the first
        // call's write has already landed. Released explicitly at the bottom rather than
        // through `defer`: this function never throws and has no other early return, so
        // there is only the one path out, and `defer` cannot itself `await` the release.
        await Runner.syncGate.acquire()

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
        await Runner.syncGate.release()
    }

    private static func logSyncFailure(_ error: Error, path: String) {
        Logger(subsystem: "com.jonaprieto.pdfhammer", category: "library")
            .error("library sync failed for \(path, privacy: .public), leaving it for the next sync: \(String(describing: error), privacy: .public)")
    }

    /// A minimal mutual-exclusion lock for `syncLibrary`, above. Not an `AsyncSemaphore`
    /// from a library, and not built to be reused elsewhere: it exists solely so that
    /// method's body runs one call at a time, and an `actor` is already exactly that --
    /// its own isolation serializes access to the two `var`s below, which is all a queue
    /// of waiters needs.
    private actor SyncGate {
        private var locked = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        /// Returns immediately if nothing else holds the gate; otherwise waits until
        /// whoever does calls `release()`.
        func acquire() async {
            guard locked else {
                locked = true
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        /// Hands the gate to the next waiter, if any, or opens it back up.
        func release() {
            guard waiters.isEmpty else {
                waiters.removeFirst().resume()
                return
            }
            locked = false
        }
    }

    private static let syncGate = SyncGate()
}

/// Files into a project, wherever they were dragged from.
///
/// A path only becomes a document when a scan or a sync has written it down, and
/// `Library.addMembers` can only file documents. Dropping a PDF the library has not met
/// yet -- one from Finder, or from a source scanned but not yet synced -- was therefore a
/// drop that did nothing and said nothing. Anything missing is indexed here first, with
/// what the file itself says, which is what the next sync would have written anyway.
@discardableResult
func addToProject(_ paths: [String], project id: Int64, library: Library) async throws -> Int {
    var wanted: [String] = []
    var missing: [Library.IndexInput] = []
    for path in pdfsUnder(paths) {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var known = (try? await library.document(atPath: path)) ?? nil
        if known == nil, resolved != path {
            known = (try? await library.document(atPath: resolved)) ?? nil
        }
        if known != nil {
            wanted.append(path)
        } else if FileManager.default.fileExists(atPath: resolved) {
            missing.append(indexInput(for: URL(fileURLWithPath: resolved)))
            wanted.append(resolved)
        }
    }
    guard !wanted.isEmpty else { return 0 }
    if !missing.isEmpty { _ = try await library.indexDocuments(missing) }
    return try await library.addMembers(paths: wanted, toProject: id)
}

/// The PDFs a drop actually means.
///
/// A folder dropped on a project means the documents in it: dropping one used to file the
/// folder itself, which is not a document and cannot be read or quoted, and then report
/// success. Anything that is not a PDF is left out for the same reason. Folders are
/// walked all the way down, since that is what a folder of papers looks like, and the
/// order is kept so a drop of several files files them in the order they were dragged.
func pdfsUnder(_ paths: [String]) -> [String] {
    var found: [String] = []
    var seen: Set<String> = []
    func take(_ path: String) {
        // Compared resolved, kept as it came: a folder walked by the enumerator gives
        // /private/var while the file dragged from the same place gives /var, and a paper
        // reached both ways is one paper, not two.
        guard seen.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath().path).inserted
        else { return }
        found.append(path)
    }
    for path in paths {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else {
            // A path with nothing behind it is left to the caller to skip: it may still be
            // a document the library knows under a name that has since moved.
            take(path)
            continue
        }
        guard isFolder.boolValue else {
            if path.lowercased().hasSuffix(".pdf") { take(path) }
            continue
        }
        let inside = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let entry = inside?.nextObject() as? URL {
            guard entry.pathExtension.lowercased() == "pdf" else { continue }
            take(entry.path)
        }
    }
    return found
}

/// Keeps this Markdown as what the library knows the document says, so a search can find
/// it and a project can quote it.
///
/// The library files documents, not paths, so a file it has never met is indexed here
/// first, the same way filing one into a project does. Answers false when the file could
/// not be recorded at all, which is the only case the caller can do anything about.
@discardableResult
func storeAsDocumentText(_ markdown: String, for url: URL, library: Library) async -> Bool {
    let resolved = url.resolvingSymlinksInPath().path
    var known = (try? await library.document(atPath: url.path)) ?? nil
    if known == nil, resolved != url.path {
        known = (try? await library.document(atPath: resolved)) ?? nil
    }
    if known == nil {
        guard FileManager.default.fileExists(atPath: resolved),
              let records = try? await library.indexDocuments([indexInput(for: URL(fileURLWithPath: resolved))]),
              let first = records.first
        else { return false }
        known = first
    }
    guard let document = known else { return false }
    return ((try? await library.setExtractedText(markdown, forDocument: document.id)) != nil)
}

/// What a scan records about one file: its size, its pages, and whatever the PDF says
/// about itself. The same fields `syncLibrary` writes, read straight off the disk.
func indexInput(for url: URL) -> Library.IndexInput {
    let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let document = PDFDocument(url: url)
    var info: [String: String] = [:]
    if let attributes = document?.documentAttributes {
        for key in [PDFDocumentAttribute.titleAttribute, .authorAttribute, .subjectAttribute,
                    .creatorAttribute, .producerAttribute, .keywordsAttribute] {
            guard let value = attributes[key] else { continue }
            let text = (value as? String) ?? (value as? [String])?.joined(separator: ", ") ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { info[key.rawValue] = trimmed }
        }
    }
    return Library.IndexInput(path: url.path, byteCount: byteCount,
                              pageCount: document?.pageCount, title: info["Title"],
                              author: info["Author"], documentInfo: info)
}
