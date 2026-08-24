import XCTest
@testable import PDFHammerCore

final class BibtexTests: XCTestCase {

    private func item(_ name: String) -> Item {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        return Item(root: root, source: root.appendingPathComponent(name),
                    destination: root.appendingPathComponent(name), status: .renamed)
    }

    func testFieldsAreReadOutOfANormalizedName() {
        let entries = bibEntries(for: [item("1979-godel-escher-bach.pdf")])
        XCTAssertEqual(entries.first?.title, "godel escher bach")
        XCTAssertEqual(entries.first?.year, "1979")
        XCTAssertNil(entries.first?.author, "a filename does not state an author")
        XCTAssertEqual(entries.first?.missing, ["author"])
    }

    func testAKnownGuessWins() {
        let known = ["/tmp/shelf/1979-godel-escher-bach.pdf":
                        BookGuess(title: "Gödel, Escher, Bach", author: "Hofstadter", year: "1979")]
        let entries = bibEntries(for: [item("1979-godel-escher-bach.pdf")], known: known)
        XCTAssertEqual(entries.first?.author, "Hofstadter")
        XCTAssertEqual(entries.first?.key, "hofstadter:1979:godel")
        XCTAssertTrue(entries.first?.isComplete == true)
    }

    func testDuplicateKeysAreDisambiguated() {
        let known = [
            "/tmp/shelf/a.pdf": BookGuess(title: "Essays One", author: "Davis", year: "2019"),
            "/tmp/shelf/b.pdf": BookGuess(title: "Essays Two", author: "Davis", year: "2019"),
            "/tmp/shelf/c.pdf": BookGuess(title: "Essays Three", author: "Davis", year: "2019"),
        ]
        let keys = bibEntries(for: [item("a.pdf"), item("b.pdf"), item("c.pdf")], known: known).map(\.key)
        XCTAssertEqual(keys, ["davis:2019:essays", "davis:2019:essaysa", "davis:2019:essaysb"])
        XCTAssertEqual(Set(keys).count, 3)
    }

    func testEscapingProtectsBibtexSyntax() {
        XCTAssertEqual(bibtexEscape("100% {pure} C&A_x"), "100\\% \\{pure\\} C\\&A\\_x")
        XCTAssertEqual(bibtexEscape("a\\b"), "a\\textbackslash{}b")
    }

    func testDocumentIsSortedAndAligned() throws {
        let known = ["/tmp/shelf/1979-godel-escher-bach.pdf":
                        BookGuess(title: "GEB", author: "Hofstadter", year: "1979")]
        let document = bibtexDocument(bibEntries(
            for: [item("2019-zzz.pdf"), item("1979-godel-escher-bach.pdf")], known: known))

        XCTAssertTrue(document.contains("@book{hofstadter:1979:geb,"))
        XCTAssertTrue(document.contains("  title  = {GEB},"), "fields should be padded to align")

        // Sorted by citation key. An author-less entry keys on its year, and digits sort
        // ahead of letters, so 2019:zzz precedes hofstadter:1979:geb.
        let zzz = try XCTUnwrap(document.range(of: "@book{2019:zzz,"))
        let hofstadter = try XCTUnwrap(document.range(of: "@book{hofstadter:1979:geb,"))
        XCTAssertLessThan(zzz.lowerBound, hofstadter.lowerBound)
    }

    func testIncompleteEntriesCanBeLeftOut() {
        let known = ["/tmp/shelf/a.pdf": BookGuess(title: "Complete", author: "Someone", year: "2020")]
        let entries = bibEntries(for: [item("a.pdf"), item("mystery.pdf")], known: known)
        XCTAssertEqual(entries.filter(\.isComplete).count, 1)
        XCTAssertTrue(bibtexDocument(entries, includeIncomplete: false).contains("Complete"))
        XCTAssertFalse(bibtexDocument(entries, includeIncomplete: false).contains("mystery"))
        XCTAssertTrue(bibtexDocument(entries).contains("mystery"))
    }

    func testEmptySelectionGivesAnEmptyDocument() {
        XCTAssertEqual(bibtexDocument([]), "")
    }

    func testFolderOrderGroupsByDirectory() throws {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        func at(_ path: String) -> Item {
            Item(root: root, source: root.appendingPathComponent(path),
                 destination: root.appendingPathComponent(path), status: .renamed)
        }
        let entries = bibEntries(for: [at("zeta/1990-aaa.pdf"), at("alpha/1991-bbb.pdf"), at("alpha/1992-ccc.pdf")])

        let byKey = bibtexDocument(entries, order: .alphabetical)
        XCTAssertLessThan(try XCTUnwrap(byKey.range(of: "1990:aaa")).lowerBound,
                          try XCTUnwrap(byKey.range(of: "1991:bbb")).lowerBound)

        // By folder, alpha/ comes first even though its keys sort later.
        let byFolder = bibtexDocument(entries, order: .folder)
        XCTAssertLessThan(try XCTUnwrap(byFolder.range(of: "1991:bbb")).lowerBound,
                          try XCTUnwrap(byFolder.range(of: "1990:aaa")).lowerBound)
    }
}
