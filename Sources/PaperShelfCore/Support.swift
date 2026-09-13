import Foundation

/// The app, MCP server, plugin manifest and About screen all derive their release identity
/// from this value, with tests holding the other copies level with it.
public let paperShelfVersion = "1.15.0"

/// Whether a folder answers at all, given a moment to do so.
///
/// A source that has gone away does not always fail quickly. An unplugged disk answers
/// `stat` at once, but a network volume whose server stopped replying does not answer it
/// at all: the call waits for that mount's own timeout, which on a dead share is the
/// better part of a minute. The window cannot spend that, and neither can a scan, so the
/// question is asked with a deadline and anything still thinking when it passes is called
/// unreachable for now. It is asked again on the next pass, which is what already happens
/// when a drive is plugged back in.
///
public func reachable(_ url: URL, timeout: TimeInterval = 0.75) async -> Bool {
    let path = url.path
    return await answered(within: timeout) { FileManager.default.fileExists(atPath: path) }
}

/// Runs a blocking question on a background queue and gives up on it after `timeout`,
/// answering `false`.
///
/// Separate from `reachable` so the deadline can be tested against a question that is
/// slow on purpose, which no path on a healthy filesystem is.
///
/// The abandoned call is left to finish in its own time. There is no way to take a
/// blocked `stat` back, and nothing waits on it.
public func answered(within timeout: TimeInterval,
                     asking question: @escaping @Sendable () -> Bool) async -> Bool {
    let answered = FirstAnswer()
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            let answer = question()
            if answered.claim() { continuation.resume(returning: answer) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            if answered.claim() { continuation.resume(returning: false) }
        }
    }
}

/// Whichever of the two gets there first resumes the continuation, and only one may.
private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

/// Set only inside a test process: a folder of its own for everything that would otherwise
/// land beside the real library.
///
/// A full `swift test` rewrote `highlight-profile.json` and appended to `diagnostics.log`
/// in the folder somebody keeps their library in, because any test that touched a
/// preference, the diagnostics log or the highlight profile before another had set an
/// override reached the real one. An override each test has to remember is one some test
/// forgets, and a `static let` like `Library.shared` or `AppDiagnostics.shared` keeps
/// whatever the first test to touch it happened to have set up. So the process decides,
/// once, by whether XCTest is loaded into it. The app and the MCP server never load it.
///
/// Per process, so two test runs at once do not share a library. `PAPERSHELF_SUPPORT_PATH`
/// still wins, for a test that wants a folder it controls.
private let testProcessSupportRoot: URL? = {
    guard NSClassFromString("XCTestCase") != nil else { return nil }
    return FileManager.default.temporaryDirectory
        .appendingPathComponent("PaperShelfTests-\(ProcessInfo.processInfo.processIdentifier)",
                                isDirectory: true)
}()

/// Where the app keeps what it must not lose: the library, the last run, anything else
/// that outlives a launch.
///
/// The folder used to be called "PDF Hammer", which is what the app used to be called. A
/// rename that simply started writing somewhere else would leave a person's library,
/// their tags, their notes and their reading positions in a directory nothing opens any
/// more, which reads as the app having forgotten everything. So the old folder is moved
/// to the new name the first time this is asked for, once, and only when there is nothing
/// at the new name to overwrite.
public func supportDirectory(named name: String = "PaperShelf",
                             legacy: String = "PDF Hammer") -> URL? {
    // The escape hatch `libraryDatabaseURL` has, for the things beside the library that
    // live in the same folder: the diagnostics log, the run cache, saved web articles.
    // `PAPERSHELF_LIBRARY_PATH` moved the library and left those behind, so a run pointed
    // at a scratch collection still wrote into the folder somebody keeps their real one
    // in. `HOME` does not do this job: `applicationSupportDirectory` resolves through the
    // user record rather than the environment, which is a thing worth knowing once.
    if let overridden = ProcessInfo.processInfo.environment["PAPERSHELF_SUPPORT_PATH"],
       !overridden.isEmpty {
        let folder = URL(fileURLWithPath: overridden)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    if let root = testProcessSupportRoot {
        return supportDirectory(in: root, named: name, legacy: legacy)
    }
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask).first else { return nil }
    return supportDirectory(in: base, named: name, legacy: legacy)
}

/// The same, against a given base directory, so the move can be tested without touching
/// the Application Support folder of whoever is running the tests.
public func supportDirectory(in base: URL, named name: String = "PaperShelf",
                             legacy: String = "PDF Hammer") -> URL {
    let manager = FileManager.default
    let folder = base.appendingPathComponent(name, isDirectory: true)
    let old = base.appendingPathComponent(legacy, isDirectory: true)

    if !manager.fileExists(atPath: folder.path), manager.fileExists(atPath: old.path) {
        // A failed move is not worth interrupting anyone over: the new folder is created
        // below either way, and the old one is left exactly where it was rather than
        // half-copied. Someone can still find it; nothing is destroyed to make room.
        try? manager.moveItem(at: old, to: folder)
    }
    try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}
