import XCTest
@testable import PaperShelf
@testable import PaperShelfCore

/// What the bibliography bar says about the entries that are not ready.
///
/// The sentence is the whole point of the summary: "3 entries need an author" is
/// something a person can act on, "3 incomplete" is something they have to go and
/// investigate, and the two cost the same to say.
final class BibliographyBarTests: XCTestCase {

    private func gaps(_ entries: [(String, [String])],
                      standard: BibStandard = .biblatex) -> BibGaps {
        BibGaps(byEntry: entries.map { (key: $0.0, itemKey: "/tmp/\($0.0).pdf", missing: $0.1) },
                standard: standard)
    }

    func testItNamesTheFieldWhenEverythingIsShortOfTheSameOne() {
        let one = gaps([("boyd:2004:convex", ["author"])])
        XCTAssertEqual(one.sentence, "1 entry needs an author")

        let three = gaps([("boyd:2004:convex", ["author"]),
                          ("?:1991:does", ["author"]),
                          ("?:2024:reporte", ["author"])])
        XCTAssertEqual(three.sentence, "3 entries need an author")
        XCTAssertEqual(three.count, 3)
    }

    /// "a" or "an" by the field itself, since the fields a standard requires are not a
    /// list this app gets to choose.
    func testTheArticleFollowsTheFieldName() {
        XCTAssertEqual(gaps([("x", ["title"])]).sentence, "1 entry needs a title")
        XCTAssertEqual(gaps([("x", ["editor"])]).sentence, "1 entry needs an editor")
    }

    /// Different entries missing different things cannot be named, so it says what they
    /// have in common instead: the standard they do not satisfy.
    func testMixedGapsFallBackToTheStandard() {
        let mixed = gaps([("a", ["author"]), ("b", ["year"])])
        XCTAssertEqual(mixed.sentence, "2 entries are missing fields biblatex requires")
        XCTAssertNil(mixed.sharedField)

        let bibtex = gaps([("a", ["author"]), ("b", ["year"])], standard: .classic)
        XCTAssertEqual(bibtex.sentence, "2 entries are missing fields Classic BibTeX requires")
    }

    /// An entry short of two things is still one entry, and the bar counts entries.
    func testAnEntryMissingSeveralFieldsIsCountedOnce() {
        let both = gaps([("?:1991:does", ["author", "year"])])
        XCTAssertEqual(both.count, 1)
        XCTAssertNil(both.sharedField, "two fields are not one shared field")
        XCTAssertTrue(both.sentence.hasPrefix("1 entry is missing fields"))
    }

    func testNothingMissingIsNothingToSay() {
        XCTAssertTrue(gaps([]).isEmpty)
        XCTAssertEqual(gaps([]).count, 0)
    }
}

/// How the entry list is laid out: one heading per folder, in the order the entries are
/// already in, so the order chosen in the bar is the order that is read.
final class BibliographyGroupingTests: XCTestCase {

    private func entry(_ key: String, folder: String) -> (BibEntry, String) {
        let path = "/tmp/\(folder)/\(key).pdf"
        return (BibEntry(itemKey: path, key: key, title: key, author: nil, year: nil, file: path),
                folder)
    }

    func testEntriesAreGroupedByFolderInTheOrderTheyArrive() {
        let rows = [entry("pearl", folder: "causal"), entry("angrist", folder: "causal"),
                    entry("koller", folder: "seminar"), entry("gelman", folder: "causal")]
        let byEntry = Dictionary(uniqueKeysWithValues: rows.map { ($0.0.key, $0.1) })

        let groups = bibGroups(rows.map(\.0)) { byEntry[$0.key] ?? "" }

        XCTAssertEqual(groups.map(\.name), ["causal", "seminar"], "first appearance decides")
        XCTAssertEqual(groups[0].entries.map(\.key), ["pearl", "angrist", "gelman"])
        XCTAssertEqual(groups[1].entries.map(\.key), ["koller"])
    }

    func testEveryEntryLandsInExactlyOneGroup() {
        let rows = (0..<20).map { entry("k\($0)", folder: $0 % 3 == 0 ? "a" : "b") }
        let byEntry = Dictionary(uniqueKeysWithValues: rows.map { ($0.0.key, $0.1) })

        let groups = bibGroups(rows.map(\.0)) { byEntry[$0.key] ?? "" }

        XCTAssertEqual(groups.reduce(0) { $0 + $1.entries.count }, 20)
        XCTAssertEqual(Set(groups.map(\.name)), ["a", "b"])
    }

    func testNoEntriesIsNoGroups() {
        XCTAssertTrue(bibGroups([]) { _ in "anywhere" }.isEmpty)
    }
}
