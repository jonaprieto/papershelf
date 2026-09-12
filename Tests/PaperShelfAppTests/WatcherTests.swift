import XCTest
@testable import PaperShelf

/// A source folder that is also a working directory never stops changing, and every burst
/// of changes used to cost a full rescan of it. These check that the churn a build makes
/// is not mistaken for a paper arriving, and that a paper arriving still is.
final class WatcherTests: XCTestCase {

    private let roots = ["/library", "/Users/someone/.papers"]

    func testOnlyPDFsAndFoldersReachTheScan() {
        XCTAssertTrue(FolderWatcher.mayChangeScan("/library/a/paper.pdf", isDirectory: false,
                                                  under: roots))
        XCTAssertTrue(FolderWatcher.mayChangeScan("/library/a/Paper.PDF", isDirectory: false,
                                                  under: roots))
        // A folder moved in carries what is under it, and FSEvents does not report those
        // files separately.
        XCTAssertTrue(FolderWatcher.mayChangeScan("/library/a/papers", isDirectory: true,
                                                  under: roots))
        XCTAssertFalse(FolderWatcher.mayChangeScan("/library/a/notes.txt", isDirectory: false,
                                                   under: roots))
    }

    /// The whole point: a build writing into `.build`, and Git writing into `.git`, cannot
    /// produce a file a scan would find, because the walk skips hidden entries.
    func testTheChurnOfBuildingAndCommittingIsIgnored() {
        for path in ["/library/project/.build/x86_64/debug/Thing.o",
                     "/library/project/.build/x86_64/debug",
                     "/library/project/.git/objects/ab/cdef",
                     "/library/project/.git/index.lock"] {
            XCTAssertFalse(FolderWatcher.mayChangeScan(path, isDirectory: path.hasSuffix("debug"),
                                                       under: roots),
                           "\(path) woke the watcher")
        }
        // Even a PDF written inside one: the scan would not find it either.
        XCTAssertFalse(FolderWatcher.mayChangeScan("/library/p/.build/manual.pdf",
                                                   isDirectory: false, under: roots))
    }

    /// Hidden is judged below the root, not along the whole path. A source that itself
    /// lives under a dotted folder is still a source.
    func testARootUnderADottedFolderIsStillWatched() {
        XCTAssertTrue(FolderWatcher.mayChangeScan("/Users/someone/.papers/new.pdf",
                                                  isDirectory: false, under: roots))
        XCTAssertFalse(FolderWatcher.mayChangeScan("/Users/someone/.papers/.cache/new.pdf",
                                                   isDirectory: false, under: roots))
    }

    func testSomethingOutsideEverySourceIsNotOurs() {
        XCTAssertFalse(FolderWatcher.mayChangeScan("/elsewhere/paper.pdf", isDirectory: false,
                                                   under: roots))
        // A sibling whose name merely starts the same way is outside too.
        XCTAssertFalse(FolderWatcher.mayChangeScan("/library-old/paper.pdf", isDirectory: false,
                                                   under: roots))
    }

    /// And the stream itself: the predicate above is only worth anything if the callback
    /// actually consults it. A real build's worth of writing into a hidden folder must
    /// leave the watcher quiet, and one PDF must wake it.
    func testTheStreamStaysQuietForHiddenChurnAndWakesForAPaper() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        let hidden = root.appendingPathComponent(".build/debug")
        try fm.createDirectory(at: hidden, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let wakings = Wakings()
        let watcher = FolderWatcher(settle: 0.2) { wakings.record() }
        defer { watcher.stop() }
        watcher.watch([root])
        // Making the folders is itself a change, and FSEvents' own latency means the
        // stream opens on the tail of it. Let that arrive and start counting after.
        Thread.sleep(forTimeInterval: 2)
        wakings.reset()

        for index in 0..<200 {
            try Data("object".utf8).write(to: hidden.appendingPathComponent("\(index).o"))
        }
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(wakings.count, 0, "a build's worth of hidden writes triggered a rescan")

        try Data("%PDF-1.4".utf8).write(to: root.appendingPathComponent("paper.pdf"))
        let deadline = Date().addingTimeInterval(10)
        while wakings.count == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertGreaterThan(wakings.count, 0, "a paper arriving did not reach the scan")
    }
}

/// The watcher reports from its own queue, so the count it is judged by needs a lock.
private final class Wakings: @unchecked Sendable {
    private let lock = NSLock()
    private var wakings = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return wakings
    }

    func record() {
        lock.lock()
        defer { lock.unlock() }
        wakings += 1
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        wakings = 0
    }
}
