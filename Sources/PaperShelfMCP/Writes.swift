import Foundation
import PaperShelfCore

/// Runs an async body to completion and hands back its result, for the tools that have to
/// reach `Library`, which is an actor.
///
/// The server's read loop is synchronous and stays that way: reads go through
/// `LibraryReader`, which is a plain synchronous SQLite connection in the hot path of every
/// request. Only the handful of tools that write cross into the actor, and each of them
/// does a few statements. Making the whole loop async to avoid a semaphore on four tools
/// would be a large change for nothing.
///
/// ponytail: one semaphore per write call, which is fine at four write tools. If the write
/// side grows, make `Server.run` async and delete this.
///
/// `Box` cannot be declared inside `blocking` itself: Swift does not allow a nested type
/// declaration inside a generic function, even one that (like this one) does not otherwise
/// depend on the function's own generic parameter beyond its own. It is declared once at
/// file scope, generic over the same `T`, instead.
private final class Box<T>: @unchecked Sendable {
    var value: Result<T, Error>?
}

func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = Box<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do { box.value = .success(try await body()) } catch { box.value = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    guard let value = box.value else {
        throw ToolFailure("the library did not answer")
    }
    return try value.get()
}

/// A read-write connection to the library the app owns.
///
/// `Library.init` opens with `SQLITE_OPEN_CREATE`, which would conjure an empty library on
/// a machine where nobody has indexed one. That is not this process's call to make, so the
/// file has to exist first. WAL, which is the file's own journal mode, is what makes this
/// safe beside a running app: a reader never blocks a writer and a writer never blocks a
/// reader.
func openLibraryForWriting() throws -> Library {
    let url: URL
    if let overridden = ProcessInfo.processInfo.environment["PAPERSHELF_LIBRARY_PATH"] {
        url = URL(fileURLWithPath: overridden)
    } else if let standard = libraryDatabaseURL() {
        url = standard
    } else {
        throw ToolFailure("there is no Application Support directory to hold a library")
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw ToolFailure("No library has been indexed yet. Open PaperShelf and add a "
            + "folder to the library first.")
    }
    do {
        return try Library(url: url)
    } catch {
        throw ToolFailure("could not open the library for writing: \(error)")
    }
}

/// Folds the renames `apply_file_changes` just carried out into the library, the way the
/// GUI app folds a real run's renames in, in `Runner.syncLibrary`
/// (`PaperShelf/LibrarySync.swift`). `process(jobs:options:)` (`PaperShelfCore/Hammer.swift`)
/// only ever touches files on disk; the comment on `Item.currentURL` there is explicit that
/// it deliberately never calls the library itself, and that whichever caller actually asked
/// for the move is the one that has to record it afterward. `apply_file_changes` used to be
/// the one caller that did not, so `locations.path` kept naming a file by the name it had
/// before the move until somebody happened to open PaperShelf and it rescanned the folder --
/// which needs the app to be running at all -- and until then, `resolveDocument` would hand
/// a since-moved path to `list_highlights`, `read_document` and `read_page`, none of which
/// had any way to tell a stale path from a correct one.
///
/// Best-effort and silent about its own failures to the caller, the same as the app's own
/// version: the files have already moved by the time this runs, so a library that has not
/// been indexed yet, or a lookup or write that fails, means the library's bookkeeping falls
/// behind, not that the rename itself should be reported as having failed. `note` records
/// what happened to stderr, for whoever is watching the server's diagnostics, rather than
/// silently swallowing it outright.
func recordMoves(_ items: [Item]) {
    let moved = items.filter(\.carriedOut)
    guard !moved.isEmpty else { return }
    guard let library = try? openLibraryForWriting() else { return }
    for item in moved {
        let current = item.currentURL.resolvingSymlinksInPath().path
        // `item.key` is resolved the same way (see its own doc comment), so this only
        // skips a job that did not actually change the path a lookup would use, such as
        // a decrypt-in-place that rewrites a file under its own existing name.
        guard current != item.key else { continue }
        do {
            guard let record = try blocking({ try await library.document(atPath: item.key) })
            else {
                // The library never knew this file under its old name -- indexed by hand
                // outside PaperShelf, say -- so there is nothing on record to attach the
                // new path to. A future scan in the app indexes it fresh under the new
                // name, the same as any other file the library has not met yet.
                continue
            }
            try blocking { try await library.recordLocation(current, forDocument: record.id) }
        } catch {
            note("apply_file_changes: could not update the library for \(current): \(error)")
        }
    }
}
