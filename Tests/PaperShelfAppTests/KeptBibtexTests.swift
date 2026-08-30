import XCTest
import PaperShelfCore
@testable import PaperShelf

/// The overlay that decides whether the entry you kept is the entry you see.
///
/// Getting this wrong is what produced a bibliography reporting thirty entries missing an
/// author while one of them had a complete record kept beside it: the match is by path,
/// and a document is known at more than one path once it has been renamed.
@MainActor
final class KeptBibtexTests: XCTestCase {

    private func entry(itemKey: String, file: String) -> BibEntry {
        BibEntry(itemKey: itemKey, key: "k", title: "A Title", file: file)
    }

    private func store(_ pairs: [String: String]) -> KeptBibtex {
        let kept = KeptBibtex()
        for (path, text) in pairs { kept.remember(text, at: [path]) }
        return kept
    }

    func testAnEntryWithNothingKeptFallsBackToTheGeneratedOne() {
        let kept = store([:])
        XCTAssertNil(kept.text(for: entry(itemKey: "/a/one.pdf", file: "/a/one.pdf")))
    }

    /// Before it is applied, the file is still at the path the item started from.
    func testAKeptEntryIsFoundByTheItemsOwnPath() {
        let kept = store(["/a/one.pdf": "@book{k}"])
        XCTAssertEqual(kept.text(for: entry(itemKey: "/a/one.pdf", file: "/a/renamed.pdf")),
                       "@book{k}")
    }

    /// After it is applied, only the new path is on disk, and that is what got indexed.
    func testAKeptEntryIsFoundByThePathTheFileMovedTo() {
        let kept = store(["/a/renamed.pdf": "@article{k}"])
        XCTAssertEqual(kept.text(for: entry(itemKey: "/a/one.pdf", file: "/a/renamed.pdf")),
                       "@article{k}")
    }

    /// Another document's entry must never be shown against this one.
    func testAnUnrelatedPathDoesNotMatch() {
        let kept = store(["/somewhere/else.pdf": "@book{other}"])
        XCTAssertNil(kept.text(for: entry(itemKey: "/a/one.pdf", file: "/a/one.pdf")))
    }

    func testForgettingRemovesIt() {
        let kept = store(["/a/one.pdf": "@book{k}"])
        kept.forget(["/a/one.pdf"])
        XCTAssertNil(kept.text(for: entry(itemKey: "/a/one.pdf", file: "/a/one.pdf")))
    }

    /// The gap check has to read the kept text, not the entry that was generated: this is
    /// the bug exactly, an entry generated without an author while the kept one had four.
    func testGapsAreJudgedFromTheKeptTextWhenThereIsOne() {
        let generated = entry(itemKey: "/a/one.pdf", file: "/a/one.pdf")
        XCTAssertEqual(bibGaps(generated, kept: store([:]), standard: .biblatex),
                       ["author", "year"])

        let complete = """
            @article{k, title = {A Title}, author = {Gomes, Victor}, year = {2017},
                     journal = {Proc. ACM Program. Lang.}}
            """
        XCTAssertEqual(bibGaps(generated, kept: store(["/a/one.pdf": complete]),
                               standard: .biblatex), [])
    }

    /// Kept text that does not parse is not quietly called valid.
    func testUnreadableKeptTextIsReportedRatherThanPassed() {
        let generated = entry(itemKey: "/a/one.pdf", file: "/a/one.pdf")
        let gaps = bibGaps(generated, kept: store(["/a/one.pdf": "not an entry"]),
                           standard: .biblatex)
        XCTAssertFalse(gaps.isEmpty)
    }
}
