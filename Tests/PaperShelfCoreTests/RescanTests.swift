import XCTest
@testable import PaperShelfCore

/// The watcher walks what changed rather than the whole source. What it has to get right
/// is that the plan afterwards is the plan a full walk would have produced.
final class RescanTests: XCTestCase {

    private let fm = FileManager.default
    private var source: URL!

    override func setUpWithError() throws {
        source = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("library")
        try fm.createDirectory(at: source.appendingPathComponent("a/deep"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("b"),
                               withIntermediateDirectories: true)
        for path in ["top.pdf", "a/one.pdf", "a/deep/two.pdf", "b/three.pdf"] {
            try write(path)
        }
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: source.deletingLastPathComponent())
    }

    private func write(_ relative: String) throws {
        try Data("%PDF-1.4".utf8).write(to: source.appendingPathComponent(relative))
    }

    private func full() -> [Job] { collectJobs(roots: [source], recursive: true) }

    /// Walks the changed places the way the runner does, then merges.
    private func rescan(_ previous: [Job], _ changed: [ChangedPlace]) -> [Job] {
        let scopes = changed.map(\.url).filter { fm.fileExists(atPath: $0.path) }
        let found = collectJobs(roots: scopes, recursive: true)
        return mergeRescan(previous: previous, found: found, changed: changed, roots: [source])
    }

    private func names(_ jobs: [Job]) -> [String] { jobs.map(\.key) }

    func testAFileSavedIntoAFolderArrivesAndNothingElseMoves() throws {
        let before = full()
        try write("a/new.pdf")
        let after = rescan(before, [.file(source.appendingPathComponent("a/new.pdf"))])
        XCTAssertEqual(names(after), names(full()), "the partial walk disagreed with a full one")
    }

    func testAFileDeletedIsGoneEvenThoughThereIsNothingToWalk() throws {
        let before = full()
        try fm.removeItem(at: source.appendingPathComponent("b/three.pdf"))
        let after = rescan(before, [.file(source.appendingPathComponent("b/three.pdf"))])
        XCTAssertEqual(names(after), names(full()))
    }

    /// A folder renamed is reported as the folder, twice, and never as the files inside it.
    func testARenamedFolderTakesItsFilesWithIt() throws {
        let before = full()
        let old = source.appendingPathComponent("a")
        let new = source.appendingPathComponent("renamed")
        try fm.moveItem(at: old, to: new)
        let after = rescan(before, [.folder(old), .folder(new)])
        XCTAssertEqual(names(after), names(full()))
        XCTAssertFalse(after.contains { $0.key.contains("/a/") }, "a file stayed at its old path")
    }

    /// A walk rooted at a changed folder names that folder as the root of what it finds.
    /// The tree and every relative path come from `root`, so it has to be the source.
    func testWhatArrivesBelongsToTheSourceNotToTheFolderWalked() throws {
        let before = full()
        try write("a/deep/arrived.pdf")
        let after = rescan(before, [.folder(source.appendingPathComponent("a/deep"))])
        let arrived = try XCTUnwrap(after.first { $0.file.lastPathComponent == "arrived.pdf" })
        XCTAssertEqual(Item.identity(of: arrived.root), Item.identity(of: source))
    }

    /// Order is a full scan's, so a new file lands among its neighbours rather than last.
    func testTheMergedPlanIsInScanOrder() throws {
        let before = full()
        try write("a/aaa.pdf")
        let after = rescan(before, [.file(source.appendingPathComponent("a/aaa.pdf"))])
        XCTAssertEqual(names(after), names(full()))
    }

    /// The comparison a rescan makes to tell what vanished: a job for a file that has gone
    /// must still have the key the item made from it has.
    func testAJobKeepsItsKeyOnceItsFileHasGone() throws {
        let paper = URL(fileURLWithPath: "/private" + source.path).appendingPathComponent("top.pdf")
        let job = Job(root: source, file: paper)
        let item = Item(root: source, source: paper, destination: paper, status: .renamed)
        try fm.removeItem(at: paper)
        XCTAssertEqual(Job(root: source, file: paper).key, job.key)
        XCTAssertEqual(job.key, item.key)
    }
}
