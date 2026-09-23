import XCTest
@testable import PaperShelf

/// The About window draws these, so what this returns is what a reader sees.
final class ChangelogBlocksTests: XCTestCase {
    func testHeadingsKeepTheirLevelAndLoseTheirHashes() {
        let blocks = changelogBlocks("# Changelog\n\n## [1.16.1] - 2026-09-22\n\n### Performance\n")
        XCTAssertEqual(blocks, [.heading(level: 1, text: "Changelog"),
                                .heading(level: 2, text: "[1.16.1] - 2026-09-22"),
                                .heading(level: 3, text: "Performance")])
    }

    /// The file is wrapped where its author wrapped it. Drawn line for line, a sentence
    /// breaks there and again where the window ends, which is what made the entries ragged.
    func testAWrappedBulletBecomesOneBullet() {
        let blocks = changelogBlocks("""
        - Count the shelves in one walk of the collection,
          and remember what each path resolves to.
        - Open every folder that holds a paper.
        """)
        XCTAssertEqual(blocks, [
            .bullet("Count the shelves in one walk of the collection, and remember what each path resolves to."),
            .bullet("Open every folder that holds a paper."),
        ])
    }

    func testABlankLineEndsABlock() {
        let blocks = changelogBlocks("First paragraph\nstill the first.\n\nSecond one.\n")
        XCTAssertEqual(blocks, [.paragraph("First paragraph still the first."),
                                .paragraph("Second one.")])
    }

    func testAHeadingEndsWhateverCameBeforeItWithoutABlankLine() {
        let blocks = changelogBlocks("- A bullet\n## Next version\n")
        XCTAssertEqual(blocks, [.bullet("A bullet"), .heading(level: 2, text: "Next version")])
    }

    /// The real file, so a changelog this cannot read is a failing test rather than an
    /// empty page in the About window.
    func testTheShippedChangelogReadsAsHeadingsAndBullets() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let markdown = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let blocks = changelogBlocks(markdown)
        XCTAssertEqual(blocks.first, .heading(level: 1, text: "Changelog"))
        XCTAssertTrue(blocks.contains { $0 == .heading(level: 2, text: "[1.16.1] - 2026-09-22") })
        XCTAssertGreaterThan(blocks.filter { if case .bullet = $0 { return true } else { return false } }.count, 20)
        XCTAssertFalse(blocks.contains { block in
            if case let .paragraph(text) = block { return text.hasPrefix("#") || text.hasPrefix("- ") }
            return false
        }, "No markup should survive into a paragraph")
    }
}
