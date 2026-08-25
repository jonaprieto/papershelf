import XCTest
@testable import PDFHammerCore

final class SearchTests: XCTestCase {

    private func subject(name: String, folder: String = "bank", status: String = "renamed",
                         size: Int = 1_000, pages: Int = 10, text: String? = nil) -> Searchable {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        let source = root.appendingPathComponent(folder).appendingPathComponent("ORIGINAL " + name)
        var item = Item(root: root, source: source,
                        destination: root.appendingPathComponent(folder).appendingPathComponent(name),
                        status: Status(rawValue: status) ?? .renamed)
        item.byteCount = size
        item.pageCount = pages
        return Searchable(item: item, text: text)
    }

    func testBareWordsMatchEitherName() {
        let file = subject(name: "2024-06-extracto.pdf")
        XCTAssertTrue(matches(file, Query("extracto")))
        XCTAssertTrue(matches(file, Query("ORIGINAL")), "the old name is searchable too")
        XCTAssertFalse(matches(file, Query("neuromancer")))
    }

    /// A space means and, which is what everyone typing into a search box expects.
    func testTermsAreJoinedWithAnd() {
        let file = subject(name: "2024-06-extracto.pdf")
        XCTAssertTrue(matches(file, Query("extracto 2024")))
        XCTAssertFalse(matches(file, Query("extracto 1999")))
    }

    func testFieldsNarrow() {
        let file = subject(name: "2024-06-extracto.pdf", folder: "bank/2024", status: "locked")
        XCTAssertTrue(matches(file, Query("folder:bank")))
        XCTAssertFalse(matches(file, Query("folder:shelf")))
        XCTAssertTrue(matches(file, Query("status:locked")))
        XCTAssertTrue(matches(file, Query("status:lock")), "a prefix is enough")
        XCTAssertTrue(matches(file, Query("year:2024")))
        XCTAssertFalse(matches(file, Query("year:1999")))
    }

    func testComparisons() {
        let file = subject(name: "a.pdf", size: 5 << 20, pages: 120)
        XCTAssertTrue(matches(file, Query("size>1mb")))
        XCTAssertFalse(matches(file, Query("size>10mb")))
        XCTAssertTrue(matches(file, Query("size<10mb")))
        XCTAssertTrue(matches(file, Query("pages>100")))
        XCTAssertFalse(matches(file, Query("pages<100")))
        XCTAssertTrue(matches(file, Query("pages>100 size<10mb")))
    }

    func testByteSuffixes() {
        XCTAssertEqual(byteValue("2048"), 2048)
        XCTAssertEqual(byteValue("2k"), 2048)
        XCTAssertEqual(byteValue("1kb"), 1024)
        XCTAssertEqual(byteValue("1.5mb"), 1_572_864)
        XCTAssertNil(byteValue("enormous"))
    }

    func testQuotedRunsStayTogether() {
        let query = Query("text:\"quick brown\" folder:bank")
        XCTAssertEqual(query.terms.count, 2)
        XCTAssertEqual(query.terms[0].value, "quick brown")
        XCTAssertTrue(query.needsText)
        XCTAssertFalse(Query("folder:bank").needsText)
    }

    func testTextTermsNeedTextToHaveBeenRead() {
        let unread = subject(name: "a.pdf")
        let read = subject(name: "a.pdf", text: "The quick brown fox")
        // Not yet read means it cannot be said to match, rather than passing by default.
        XCTAssertFalse(matches(unread, Query("text:quick")))
        XCTAssertTrue(matches(read, Query("text:quick")))
        XCTAssertFalse(matches(read, Query("text:elephant")))
    }

    /// A search box that rejects input is worse than one that searches for the literal,
    /// so an unknown field is not an error: it becomes the text being looked for.
    func testUnknownFieldsAreTreatedAsPlainText() {
        let file = subject(name: "2024-06-c++-notes.pdf")

        let query = Query("nonsense:")
        XCTAssertEqual(query.terms.count, 1)
        XCTAssertNil(query.terms[0].field, "unknown fields are not fields")
        XCTAssertEqual(query.terms[0].value, "nonsense:")
        XCTAssertFalse(matches(file, query), "and so it matches only a name containing it")

        XCTAssertTrue(matches(file, Query("c++")), "punctuation in a bare word is fine")
        XCTAssertTrue(matches(file, Query("notes")))
        XCTAssertTrue(Query("   ").isEmpty)
    }
}
