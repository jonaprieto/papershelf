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
