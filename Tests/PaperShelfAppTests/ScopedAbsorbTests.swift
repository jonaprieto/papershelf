import XCTest
@testable import PaperShelfCore
@testable import PaperShelf

/// The runner walks only where the watcher saw a change. Getting that wrong does not show
/// as a slow rescan; it shows as papers silently leaving the shelf, taking the decisions
/// made about them with them. These drive a real runner over real files.
@MainActor
final class ScopedAbsorbTests: XCTestCase {

    private let fm = FileManager.default
    private var source: URL!
    private let options = Options(passwords: [], recursive: true, dryRun: true)

    override func setUpWithError() throws {
        source = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: source.appendingPathComponent("inbox"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("archive"),
                               withIntermediateDirectories: true)
        for name in ["archive/one.pdf", "archive/two.pdf", "inbox/three.pdf"] {
            try makePDF(at: source.appendingPathComponent(name), password: nil)
        }
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: source)
    }

    private func keys(_ runner: Runner) -> Set<String> { Set(runner.results.map(\.key)) }

    /// A shelf built the ordinary way, with its jobs in step with what is on it.
    private func scannedRunner() async throws -> Runner {
        let runner = Runner()
        runner.libraryPreview(roots: [source], options: options, fingerprint: "f")
        let deadline = Date().addingTimeInterval(20)
        while runner.results.count < 3, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(runner.results.count, 3, "the shelf never finished its first scan")
        return runner
    }

    func testAPaperSavedIntoOneFolderArrivesAndTheRestStay() async throws {
        let runner = try await scannedRunner()
        let before = keys(runner)
        let arrived = source.appendingPathComponent("inbox/four.pdf")
        try makePDF(at: arrived, password: nil)
        // Written where nothing reported a change. Only a walk of the whole source would
        // find it, which is how this tells a scoped absorb from one that quietly walked
        // everything: both would pass every other assertion here.
        let unreported = source.appendingPathComponent("archive/unreported.pdf")
        try makePDF(at: unreported, password: nil)

        await runner.absorbChanges(roots: [source], options: options, fingerprint: "f",
                                   changed: [.file(arrived)])
        XCTAssertTrue(before.isSubset(of: keys(runner)), "papers outside the change left the shelf")
        XCTAssertTrue(keys(runner).contains(Item.identity(of: arrived)), "the new paper never arrived")
        XCTAssertFalse(keys(runner).contains(Item.identity(of: unreported)),
                       "the absorb walked the whole source instead of the place that changed")
        XCTAssertEqual(runner.results.count, 4)
    }

    func testAPaperDeletedIsTakenOff() async throws {
        let runner = try await scannedRunner()
        let gone = source.appendingPathComponent("archive/two.pdf")
        try fm.removeItem(at: gone)
        await runner.absorbChanges(roots: [source], options: options, fingerprint: "f",
                                   changed: [.file(gone)])
        XCTAssertEqual(runner.results.count, 2)
        XCTAssertFalse(keys(runner).contains(Item.identity(of: gone)))
    }

    /// Straight after launch a cached shelf is on screen while the walk behind it is still
    /// going, so the runner has items but no jobs. A scoped merge into no jobs would keep
    /// only what the changed place holds and drop every other paper; the runner has to see
    /// that and walk everything instead.
    func testACachedShelfIsNotEmptiedByAScopedChange() async throws {
        let scanned = try await scannedRunner()
        saveRunCache(RunCache(fingerprint: "cached", items: scanned.results))
        let runner = Runner()
        XCTAssertTrue(runner.showCached(fingerprint: "cached"))
        XCTAssertEqual(runner.results.count, 3)

        let arrived = source.appendingPathComponent("inbox/four.pdf")
        try makePDF(at: arrived, password: nil)
        await runner.absorbChanges(roots: [source], options: options, fingerprint: "cached",
                                   changed: [.file(arrived)])
        XCTAssertEqual(runner.results.count, 4,
                       "papers the scoped walk never looked at vanished from a cached shelf")
    }
}
