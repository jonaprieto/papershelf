import XCTest
@testable import PaperShelfCore
@testable import PaperShelf

/// Three places asked the filesystem on the main actor about paths that can sit on a
/// network volume: the sources after an edit in Settings, the opened documents outside
/// every source, and the tabs from last time. A dead mount answers those calls with its
/// own timeout, so each of them could hold the window. These check the answers are still
/// right now that the questions are asked elsewhere, and that a question which never comes
/// back does not hold anything.
final class OffMainFilesystemTests: XCTestCase {

    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root.appendingPathComponent("source/inner"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("elsewhere"),
                               withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func paper(_ relative: String) throws -> String {
        let url = root.appendingPathComponent(relative)
        try Data("%PDF-1.4".utf8).write(to: url)
        return url.path
    }

    /// Editing the sources in Settings kept only the folders that answered `fileExists` at
    /// that instant, which both blocked on the filesystem and forgot an unmounted volume.
    func testStoredSourcesKeepAFolderThatIsNotThereRightNow() {
        let text = "/Volumes/brain/papers\n\(root.path)"
        XCTAssertEqual(storedSources(text).map(\.path), ["/Volumes/brain/papers", root.path],
                       "a source that cannot be reached this second was dropped")
    }

    func testOpenedDocumentsOutsideSourcesAreStillWorkedOutCorrectly() async throws {
        let outside = try paper("elsewhere/read.pdf")
        let inside = try paper("source/inner/filed.pdf")
        let gone = root.appendingPathComponent("elsewhere/deleted.pdf").path

        let kept = await Shelves.outsideSources([gone, inside, outside],
                                                sources: [root.appendingPathComponent("source")])
        XCTAssertEqual(kept.map(\.path), [outside],
                       "a missing file, or one already under a source, reached the Opened list")
    }

    /// Order is the library's, most recently opened first, and is not the order the
    /// concurrent questions happen to come back in.
    func testOpenedDocumentsKeepTheirOrder() async throws {
        let paths = try (0..<12).map { try paper("elsewhere/\($0).pdf") }
        let kept = await Shelves.outsideSources(paths, sources: [])
        XCTAssertEqual(kept.map(\.path), paths)
    }

    func testTabsFromLastTimeAreOnlyTheOnesStillThere() async throws {
        let present = try paper("elsewhere/open.pdf")
        let missing = root.appendingPathComponent("elsewhere/renamed-away.pdf").path
        let json = try JSONSerialization.data(withJSONObject: [
            "panes": [[present, missing]], "active": [0], "activePane": 0,
        ])
        let stored = try JSONDecoder().decode(StoredDeck.self, from: json)
        let found = await ResultsPane.presentKeys(in: stored)
        XCTAssertEqual(found, [present])
    }

    /// The part none of the above can show: a question that does not come back is given up
    /// on, so a file on a dead mount costs the deadline rather than the mount's timeout.
    func testAnAnswerThatNeverComesBackIsReplacedByTheFallback() async {
        let started = Date()
        let answer = await answered(within: 0.2, otherwise: "as written") {
            Thread.sleep(forTimeInterval: 5)
            return "resolved"
        }
        XCTAssertEqual(answer, "as written")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}
