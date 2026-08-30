import XCTest
@testable import PaperShelfCore

final class MarkdownTests: XCTestCase {

    private let moment = Date(timeIntervalSince1970: 1_756_000_000)

    func testNotesGroupByPageAndQuoteProperly() {
        let text = markdownNotes(
            title: "Verifying Strong Eventual Consistency",
            source: "/tmp/shelf/2017-verifying.pdf",
            marks: [
                MarkExport(page: 2, quoted: "strong eventual consistency", note: "",
                           meaning: "Definition or key term"),
                MarkExport(page: 1, quoted: "Data replication is used", note: "the premise",
                           meaning: "Worth remembering"),
            ],
            date: moment
        )
        XCTAssertTrue(text.hasPrefix("# Verifying Strong Eventual Consistency\n"))
        XCTAssertTrue(text.contains("## Page 1"))
        XCTAssertTrue(text.contains("## Page 2"))
        // Earlier pages first, whatever order the marks arrived in.
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "## Page 1")).lowerBound,
                          try XCTUnwrap(text.range(of: "## Page 2")).lowerBound)
        XCTAssertTrue(text.contains("> Data replication is used"))
        XCTAssertTrue(text.contains("the premise"))
        XCTAssertTrue(text.contains("*Worth remembering*"))
    }

    func testEmptyNotesSaySoRatherThanProducingAStub() {
        let text = markdownNotes(title: "Book", source: "/tmp/a.pdf", marks: [], date: moment)
        XCTAssertTrue(text.contains("No highlights or notes"))
        XCTAssertFalse(text.contains("## Page"))
    }

    /// A line must not be able to turn itself into a heading, a list item or a quote.
    func testEscapingProtectsStructureAndNotMuchElse() {
        XCTAssertEqual(markdownEscape("# not a heading"), "\\# not a heading")
        XCTAssertEqual(markdownEscape("- not a bullet"), "\\- not a bullet")
        XCTAssertEqual(markdownEscape("> not a quote"), "\\> not a quote")
        // Mid-line punctuation is left alone: readable beats defensive.
        XCTAssertEqual(markdownEscape("a * b - c # d"), "a * b - c # d")
        // In a table a pipe would end the cell, and a newline the row.
        XCTAssertEqual(markdownEscape("a|b", inTable: true), "a\\|b")
        XCTAssertEqual(markdownEscape("a\nb", inTable: true), "a b")
    }

    func testCatalogueIsAWellFormedTable() {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        var item = Item(root: root, source: root.appendingPathComponent("bank/a.pdf"),
                        destination: root.appendingPathComponent("bank/2017-verifying.pdf"),
                        status: .renamed)
        item.pageCount = 28
        item.byteCount = 452_000
        let known = [item.key: BookGuess(title: "Verifying", author: "Gomes", year: "2017")]

        let text = markdownCatalogue([item], known: known, date: moment)
        let rows = text.split(separator: "\n").filter { $0.hasPrefix("|") }
        XCTAssertEqual(rows.count, 3, "header, divider, one file")
        // Every row has the same number of cells, or the table will not render.
        let widths = Set(rows.map { $0.components(separatedBy: "|").count })
        XCTAssertEqual(widths.count, 1)
        XCTAssertTrue(text.contains("2017-verifying.pdf"))
        XCTAssertTrue(text.contains("Gomes"))
        XCTAssertTrue(text.contains("28"))
    }

    func testBibliographyReadsAsProse() {
        let entries = [
            BibEntry(itemKey: "b", key: "gomes:2017:verifying", title: "Verifying",
                     author: "Gomes", year: "2017", file: "/tmp/b.pdf"),
            BibEntry(itemKey: "a", key: "abelson:1985:structure", title: "Structure",
                     author: nil, year: nil, file: "/tmp/a.pdf"),
        ]
        let text = markdownBibliography(entries, date: moment)
        XCTAssertTrue(text.contains("- Gomes. **Verifying** (2017)"))
        XCTAssertTrue(text.contains("- **Structure**"), "a missing author is simply absent")
        // Sorted by key, so abelson precedes gomes.
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "Structure")).lowerBound,
                          try XCTUnwrap(text.range(of: "Verifying")).lowerBound)
    }
}
