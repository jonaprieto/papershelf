import XCTest
@testable import PaperShelfCore

final class SearchTests: XCTestCase {

    private func subject(name: String, folder: String = "bank", status: String = "renamed",
                         size: Int = 1_000, pages: Int = 10, text: String? = nil,
                         tags: [String] = []) -> Searchable {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        let source = root.appendingPathComponent(folder).appendingPathComponent("ORIGINAL " + name)
        var item = Item(root: root, source: source,
                        destination: root.appendingPathComponent(folder).appendingPathComponent(name),
                        status: Status(rawValue: status) ?? .renamed)
        item.byteCount = size
        item.pageCount = pages
        return Searchable(item: item, text: text, tags: tags)
    }

    /// A paper is from the year it was written, not the year its filename happens to
    /// start with. The metadata date and the file's own date both count.
    func testYearMatchesTheNameTheMetadataOrTheFile() {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        let source = root.appendingPathComponent("smith-causality.pdf")
        var item = Item(root: root, source: source, destination: source, status: .renamed)
        item.metadataDate = DateComponents(calendar: .current, year: 2019, month: 3, day: 2).date
        item.modifiedDate = DateComponents(calendar: .current, year: 2024, month: 7, day: 9).date
        let file = Searchable(item: item)

        XCTAssertTrue(matches(file, Query("year:2019")), "the year the PDF says it was made")
        XCTAssertTrue(matches(file, Query("year:2024")), "the year the file was written")
        XCTAssertFalse(matches(file, Query("year:1999")))
    }

    /// A shelf lists files without opening them, so a page count is often unknown. An
    /// unknown count is not zero: `pages<10` must not sweep up everything unread.
    func testAnUnknownPageCountMatchesNoPagesTerm() {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        let source = root.appendingPathComponent("unread.pdf")
        let item = Item(root: root, source: source, destination: source, status: .renamed)
        let unread = Searchable(item: item)

        XCTAssertFalse(matches(unread, Query("pages<10")))
        XCTAssertFalse(matches(unread, Query("pages>10")))
        XCTAssertFalse(matches(unread, Query("pages:0")))

        // What the library read on an earlier pass stands in for the file itself.
        let known = Searchable(item: item, pageCount: 240)
        XCTAssertTrue(matches(known, Query("pages>100")))
        XCTAssertFalse(matches(known, Query("pages<100")))
    }

    func testTitleAndAuthorComeFromTheDocumentOrTheLibrary() {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        let source = root.appendingPathComponent("q3-final-v2.pdf")
        var item = Item(root: root, source: source, destination: source, status: .renamed)
        item.documentInfo = ["Title": "Causal Inference in Statistics",
                             "Author": "Judea Pearl"]
        let read = Searchable(item: item)

        XCTAssertTrue(matches(read, Query("title:causal")))
        XCTAssertTrue(matches(read, Query("author:pearl")))
        XCTAssertFalse(matches(read, Query("author:hume")))
        XCTAssertFalse(matches(read, Query("q3 author:hume")), "terms are still joined with and")

        // Nothing has opened this one, so only what the library kept can answer.
        let plain = Item(root: root, source: source, destination: source, status: .renamed)
        let unread = Searchable(item: plain)
        XCTAssertFalse(matches(unread, Query("title:causal")), "unknown is not a match")
        let remembered = Searchable(item: plain, title: "Causal Inference in Statistics",
                                    author: "Judea Pearl")
        XCTAssertTrue(matches(remembered, Query("title:causal")))
        XCTAssertTrue(matches(remembered, Query("author:judea")))
    }

    /// `abstract:` is the opening of a document, which is where a paper says what it is.
    func testAbstractSearchesTheOpeningOnly() {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        let source = root.appendingPathComponent("paper.pdf")
        let item = Item(root: root, source: source, destination: source, status: .renamed)
        let opening = "A survey of stochastic epidemic models."
        let deepInside = String(repeating: "body text. ", count: 400) + "hapax legomenon"
        let file = Searchable(item: item, text: opening + " " + deepInside)

        XCTAssertTrue(matches(file, Query("abstract:stochastic")))
        XCTAssertTrue(matches(file, Query("text:\"hapax legomenon\"")))
        XCTAssertFalse(matches(file, Query("abstract:\"hapax legomenon\"")),
                       "past the opening is not the abstract")
    }

    /// The catalogue asks the projection for what a file says about itself and the library
    /// for what the document says inside itself. The split has to be exact.
    func testAQuerySplitsIntoWhatEachHalfCanAnswer() {
        let query = Query("author:pearl text:\"do calculus\" abstract:causal pages>100")

        XCTAssertEqual(query.storedTerms.map { $0.field }, ["text", "abstract"])
        XCTAssertEqual(query.localTerms.map { $0.field }, ["author", "pages"])
        XCTAssertTrue(query.needsText)
        XCTAssertFalse(Query("author:pearl pages>100").needsText)
    }

    /// A misspelt field is not a bare word people meant to type: `autor:pearl` finds
    /// nothing and, without being told, looks like a search that simply failed.
    func testATypoInAFieldNameIsReportable() {
        XCTAssertEqual(Query.unknownFields(in: "autor:pearl"), ["autor"])
        XCTAssertEqual(Query.unknownFields(in: "title:causality autor:pearl"), ["autor"])
        XCTAssertTrue(Query.unknownFields(in: "author:pearl pages>100").isEmpty)
        XCTAssertTrue(Query.unknownFields(in: "10:30").isEmpty, "not everything with a colon is a field")
        XCTAssertTrue(Query.unknownFields(in: "plain words").isEmpty)
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

    func testTagFieldIsRecognisedByTheParser() {
        let query = Query("tag:reading status:locked")
        XCTAssertEqual(query.terms.count, 2)
        XCTAssertEqual(query.terms[0].field, "tag")
        XCTAssertEqual(query.terms[0].value, "reading")
    }

    /// Mirrors `testTextTermsNeedTextToHaveBeenRead`: a tag nobody resolved is not a match
    /// nobody can rule out, it is simply not there yet.
    func testTagsMatchByPrefixAndFailWhenUnresolved() {
        let tagged = subject(name: "a.pdf", tags: ["Reading", "Bank"])
        let untagged = subject(name: "b.pdf")
        XCTAssertTrue(matches(tagged, Query("tag:reading")), "case-insensitive")
        XCTAssertTrue(matches(tagged, Query("tag:read")), "a prefix is enough")
        XCTAssertFalse(matches(tagged, Query("tag:invoice")))
        XCTAssertFalse(matches(untagged, Query("tag:reading")), "no tags means no match, not a pass")
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

extension SearchTests {

    /// Byte comparison must not lose what String comparison gets right: an accent written
    /// as one code point has to match one written as two.
    func testComposedAndDecomposedAccentsMatchEachOther() {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        let composed = "señor"                    // ñ as one scalar
        let decomposed = "sen\u{0303}or"          // n followed by a combining tilde
        XCTAssertNotEqual(composed.unicodeScalars.count, decomposed.unicodeScalars.count)

        let item = Item(root: root, source: root.appendingPathComponent(composed + ".pdf"),
                        destination: root.appendingPathComponent(composed + ".pdf"),
                        status: .renamed)
        let subject = Searchable(item: item, text: decomposed)

        XCTAssertTrue(matches(subject, Query(composed)))
        XCTAssertTrue(matches(subject, Query(decomposed)))
        XCTAssertTrue(matches(subject, Query("text:\(composed)")))
        XCTAssertTrue(matches(subject, Query("text:\(decomposed)")))
    }

    func testByteScanAgreesWithTheObviousImplementation() {
        let samples = ["", "a", "abc", "the quick brown fox", "ααβγ", "señor muñoz", "🙂 ok"]
        for haystack in samples {
            for needle in samples {
                XCTAssertEqual(contains(normalised(haystack), normalised(needle)),
                               haystack.lowercased().contains(needle.lowercased()) || needle.isEmpty,
                               "\(haystack) / \(needle)")
            }
        }
    }

    // MARK: - The search the Tags panel writes

    /// The sidebar's Tags panel scopes the catalogue by writing a search rather than
    /// carrying a second notion of scope, so what it writes has to parse back to exactly
    /// that tag.
    func testTagSearchRoundTripsAMultiWordTag() {
        let query = Query(Query.tagSearch("to read"))
        XCTAssertEqual(query.terms.count, 1)
        XCTAssertEqual(query.terms.first?.field, "tag")
        XCTAssertEqual(query.terms.first?.value, "to read")
    }

    func testTagSearchRoundTripsAPlainTag() {
        let query = Query(Query.tagSearch("reading"))
        XCTAssertEqual(query.terms.first?.field, "tag")
        XCTAssertEqual(query.terms.first?.value, "reading")
    }
}

/// A query is a row of chips, and a chip can be taken back on its own.
final class QueryChipTests: XCTestCase {

    func testEachPieceIsItsOwnChip() {
        XCTAssertEqual(Query.chips("methods pages>100 status:locked"),
                       ["methods", "pages>100", "status:locked"])
    }

    /// Splitting drops the quotes that held the value together. Put back as typed, or the
    /// remaining query means something else the moment a chip beside it is removed.
    func testAQuotedValueKeepsItsQuotes() {
        XCTAssertEqual(Query.chips("text:\"structural model\" methods"),
                       ["text:\"structural model\"", "methods"])
    }

    func testABareQuotedPhraseKeepsItsQuotes() {
        XCTAssertEqual(Query.chips("\"causal inference\""), ["\"causal inference\""])
    }

    func testRemovingAChipLeavesTheRestParsingTheSameWay() {
        let text = "text:\"structural model\" methods pages>100"
        let left = Query.removing("methods", from: text)
        XCTAssertEqual(left, "text:\"structural model\" pages>100")
        XCTAssertEqual(Query(left).terms.count, 2)
        XCTAssertEqual(Query(left).terms.first?.value, "structural model")
    }

    func testRemovingTheOnlyChipEmptiesTheQuery() {
        XCTAssertEqual(Query.removing("methods", from: "methods"), "")
    }
}

/// A palette that lists titles makes a person open each one to find out which sentence
/// matched, so a hit carries the passage and the page it came from.
final class TextHitTests: XCTestCase {

    func testThePageIsReadBackOffTheMarkerTheExtractedTextCarries() {
        XCTAssertEqual(pageMarker(in: "…<!-- page:12 --> A directed path…"), 12)
        XCTAssertEqual(pageMarker(in: "<!-- page:1 --> a <!-- page:44 --> b"), 44,
                       "the last marker before the end of the snippet is the page it ends on")
    }

    /// A snippet cut mid-page carries no marker. That is a hit whose page is unknown,
    /// which is worth saying; page 1 would be a guess dressed as a fact.
    func testASnippetWithNoMarkerHasNoPage() {
        XCTAssertNil(pageMarker(in: "…composed entirely of arrows…"))
    }

    func testTheMarkersComeOutAndTheWhitespaceCollapses() {
        XCTAssertEqual(tidySnippet("<!-- page:12 -->\n  A directed   path\n\n is composed…"),
                       "A directed path is composed…")
    }

    func testASnippetOfNothingIsEmptyRatherThanWhitespace() {
        XCTAssertEqual(tidySnippet("   \n  "), "")
    }
}
