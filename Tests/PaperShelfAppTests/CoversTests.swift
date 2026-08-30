import XCTest
import AppKit
@testable import PaperShelf
@testable import PaperShelfCore

/// A shelf of fourteen thousand files on a disk that has stopped serving its own bytes is
/// the case this store has to survive: every render fails, and it must fail once per file
/// rather than once per scroll.
@MainActor
final class CoversTests: XCTestCase {
    private func item(_ path: String) -> Item {
        let url = URL(fileURLWithPath: path)
        return libraryItem(for: Job(root: url.deletingLastPathComponent(), file: url),
                           options: Options(passwords: [], recursive: true, dryRun: true))
    }

    func testAFileThatCannotBeDrawnIsRememberedRatherThanRetried() async {
        let covers = Covers()
        let missing = item("/nowhere/\(UUID().uuidString).pdf")

        XCTAssertFalse(covers.couldNotRender(missing))
        let first = await covers.cover(for: missing, passwords: [], height: 200)
        XCTAssertNil(first)
        XCTAssertTrue(covers.couldNotRender(missing))

        // Asking again answers from what is already known: no second render, still nil.
        let second = await covers.cover(for: missing, passwords: [], height: 200)
        XCTAssertNil(second)

        // A source coming back is the one thing that makes it worth trying again.
        covers.forget()
        XCTAssertFalse(covers.couldNotRender(missing))
    }
}
