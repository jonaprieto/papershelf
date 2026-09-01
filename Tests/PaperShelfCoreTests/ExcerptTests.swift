import XCTest
@testable import PaperShelfCore

final class ExcerptTests: XCTestCase {
    /// A page with no text is skipped entirely, its marker included, so the third marker
    /// in a document is not page three. Counting markers would report page 3 here where
    /// the passage is on page 7.
    private let withAGap = """
        ## Page 1

        The opening remarks.

        ## Page 2

        Nothing of consequence.

        ## Page 7

        The categorical imperative is the only thing that binds without condition.

        """

    func testThePageComesFromTheMarkerNotFromCounting() throws {
        let offset = try XCTUnwrap(withAGap.range(of: "categorical imperative")).lowerBound
        XCTAssertEqual(pageNumber(in: withAGap, before: offset), 7)
    }

    func testTextBeforeAnyMarkerHasNoPage() throws {
        let markdown = "a preface with no marker at all"
        let offset = try XCTUnwrap(markdown.range(of: "preface")).lowerBound
        XCTAssertNil(pageNumber(in: markdown, before: offset))
    }

    func testAnExcerptCarriesItsPageAndOmitsTheMarker() {
        let found = excerpts(in: withAGap, matching: "categorical imperative")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.page, 7)
        XCTAssertTrue(found.first?.text.contains("only thing that binds") == true)
        XCTAssertFalse(found.first?.text.contains("## Page") == true,
                       "a marker is structure, not something to quote")
    }

    func testMatchingIgnoresCase() {
        XCTAssertEqual(excerpts(in: withAGap, matching: "CATEGORICAL Imperative").count, 1)
    }

    func testTheLimitIsHonoured() {
        let repeated = (1...5).map { "## Page \($0)\n\nthe same phrase here\n" }.joined()
        XCTAssertEqual(excerpts(in: repeated, matching: "same phrase", limit: 2).count, 2)
        XCTAssertEqual(excerpts(in: repeated, matching: "same phrase", limit: 5).count, 5)
    }

    /// FTS5 matches on tokens, so a phrase that ranked a document can still be absent from
    /// it verbatim. Falling back to the longest word is the difference between a hit with
    /// a quote and a hit with nothing to show.
    func testAPhraseThatIsNotVerbatimFallsBackToItsLongestWord() {
        let found = excerpts(in: withAGap, matching: "imperative binds")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.page, 7)
    }

    func testNothingMatchesGivesNothing() {
        XCTAssertTrue(excerpts(in: withAGap, matching: "phenomenology").isEmpty)
    }

    /// `cleaned(_:)` only drops whole lines, so a radius that stops partway through a
    /// marker's own line (rather than before or after it) would otherwise leak a fragment
    /// like "ge 2" into the quote. A radius of 10 here lands the window's start exactly
    /// inside "## Page 2": the match is 10 characters past its "2".
    func testAWindowThatWouldSplitAMarkerExcludesItInstead() {
        let markdown = "## Page 1\n\n" + String(repeating: "X", count: 20)
            + "\n\n## Page 2\n\nthe needle is here\n\n"
        let found = excerpts(in: markdown, matching: "needle", radius: 10)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.page, 2)
        XCTAssertEqual(found.first?.text, "the needle is here",
                      "a bisected marker (e.g. \"ge 2\") must not survive into the quote")
    }
}
