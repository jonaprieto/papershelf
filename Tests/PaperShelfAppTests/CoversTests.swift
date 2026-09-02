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

    func testEachPDFContrastHasItsOwnRenderedThumbnail() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("covers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let pdf = folder.appendingPathComponent("paper.pdf")
        try makeTextPDF(at: pdf, text: "contrast")
        let paper = item(pdf.path)
        let covers = Covers()

        let normal = await covers.cover(for: paper, passwords: [], height: 200,
                                        appearance: .normal, isDark: true)
        let inverted = await covers.cover(for: paper, passwords: [], height: 200,
                                          appearance: .whiteOnBlack, isDark: true)
        let tinted = await covers.cover(for: paper, passwords: [], height: 200,
                                        appearance: .tint, isDark: true)

        XCTAssertNotNil(normal)
        XCTAssertNotNil(inverted)
        XCTAssertNotNil(tinted)
        XCTAssertNotEqual(normal?.tiffRepresentation, inverted?.tiffRepresentation)
        XCTAssertNotEqual(normal?.tiffRepresentation, tinted?.tiffRepresentation)

        let normalAgain = await covers.cover(for: paper, passwords: [], height: 200,
                                             appearance: .normal, isDark: true)
        XCTAssertEqual(normal?.tiffRepresentation, normalAgain?.tiffRepresentation)
    }
}
