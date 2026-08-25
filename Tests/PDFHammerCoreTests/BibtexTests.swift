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

extension BibtexTests {

    private var sample: String {
        """
        @book{hofstadter:1979:geb,
          title  = {Gödel, Escher, Bach},
          author = {Hofstadter},
          year   = {1979},
          file   = {/tmp/geb.pdf},
        }
        """
    }

    /// The invariant that matters: highlighting must not change a single character of
    /// what is about to be copied or saved.
    func testTokensRebuildTheInputExactly() {
        for text in [sample, "", "\n\n", "not a bib file at all", "@book{nokey\n}", "  weird = value"] {
            XCTAssertEqual(bibtexTokens(text).map(\.text).joined(), text)
        }
    }

    func testTokensAreClassified() {
        let tokens = bibtexTokens(sample)
        func first(_ kind: BibTokenKind) -> String? {
            tokens.first { $0.kind == kind }?.text.trimmingCharacters(in: .whitespaces)
        }
        XCTAssertEqual(first(.entryType), "@book")
        XCTAssertEqual(first(.key), "hofstadter:1979:geb")
        XCTAssertEqual(first(.field), "title")
        XCTAssertEqual(first(.value), "Gödel, Escher, Bach")
    }

    func testBracesInsideAValueStayInTheValue() {
        let tokens = bibtexTokens("  title  = {a \\{b\\} c},")
        XCTAssertEqual(tokens.first { $0.kind == .value }?.text, "a \\{b\\} c")
    }
}

extension BibtexTests {

    /// The lazily-rendered blocks must add up to exactly the file that gets saved.
    func testBlocksJoinIntoTheDocument() {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        func at(_ path: String) -> Item {
            Item(root: root, source: root.appendingPathComponent(path),
                 destination: root.appendingPathComponent(path), status: .renamed)
        }
        let entries = bibEntries(for: [at("b/1991-bbb.pdf"), at("a/1990-aaa.pdf")])

        for order in BibOrder.allCases {
            let blocks = bibtexOrdered(entries, order: order).map { bibtexBlock($0) }
            XCTAssertEqual(blocks.joined(separator: "\n\n") + "\n",
                           bibtexDocument(entries, order: order))
        }
    }
}

extension BibtexTests {

    private func longEntry() -> BibEntry {
        BibEntry(itemKey: "/tmp/a.pdf", key: "hofstadter:1979:geb",
                 title: "Godel Escher Bach an Eternal Golden Braid a Metaphorical Fugue on Minds and Machines",
                 author: "Hofstadter", year: "1979", file: "/tmp/a.pdf")
    }

    func testValuesWrapAtTheLineWidth() {
        let block = bibtexBlock(longEntry(), style: BibStyle(lineWidth: 80))
        for line in block.components(separatedBy: "\n") {
            XCTAssertLessThanOrEqual(line.count, 80, "line over budget: \(line)")
        }
        XCTAssertTrue(block.contains("\n"), "the long title should have wrapped")

        // Off means one line per field, however long.
        let unwrapped = bibtexBlock(longEntry(), style: BibStyle(lineWidth: 0))
        XCTAssertEqual(unwrapped.components(separatedBy: "\n").count, 6)
    }

    /// Breaking a path to satisfy a column is worse than going over it.
    func testAWordLongerThanTheBudgetIsLeftWhole() {
        let path = "/Users/someone/Library/CloudStorage/Provider-account/shelf/a-very-long-file-name.pdf"
        let entry = BibEntry(itemKey: path, key: "k", title: "T", author: nil, year: nil, file: path)
        let block = bibtexBlock(entry, style: BibStyle(lineWidth: 40))
        XCTAssertTrue(block.contains(path), "the path must survive intact")
    }

    func testStyleOptions() {
        let entry = longEntry()

        let quoted = bibtexBlock(entry, style: BibStyle(lineWidth: 0, delimiter: .quotes))
        XCTAssertTrue(quoted.contains("= \"Hofstadter\","))

        let noComma = bibtexBlock(entry, style: BibStyle(lineWidth: 0, trailingComma: false))
        XCTAssertTrue(noComma.contains("{/tmp/a.pdf}\n}"), "last field should have no comma")

        let sorted = bibtexBlock(entry, style: BibStyle(lineWidth: 0, sortFields: true))
        let names = sorted.components(separatedBy: "\n").dropFirst().dropLast()
            .map { $0.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0] }
        XCTAssertEqual(names, ["author", "file", "title", "year"])

        let omitted = bibtexBlock(entry, style: BibStyle(lineWidth: 0, omit: ["file"]))
        XCTAssertFalse(omitted.contains("file"))

        let shouty = BibEntry(itemKey: "k", key: "k", title: "AN OCR TITLE", author: "SMITH",
                              year: "1999", file: "/tmp/a.pdf")
        XCTAssertTrue(bibtexBlock(shouty, style: BibStyle(lineWidth: 0, dropAllCaps: true))
            .contains("{an ocr title}"))
        // A mixed-case title is left exactly as it is.
        XCTAssertTrue(bibtexBlock(entry, style: BibStyle(lineWidth: 0, dropAllCaps: true))
            .contains("{Hofstadter}"))
    }

    func testAlignmentCanBeTurnedOff() {
        let ragged = bibtexBlock(longEntry(), style: BibStyle(lineWidth: 0, align: false))
        XCTAssertTrue(ragged.contains("  title = {"))
        XCTAssertTrue(ragged.contains("  year = {1979},"))
    }
}

extension BibtexTests {

    // MARK: - Entry types

    private func bare(_ name: String) -> Item {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        return Item(root: root, source: root.appendingPathComponent(name),
                    destination: root.appendingPathComponent(name), status: .renamed)
    }

    func testTheTypeDecidesWhatCountsAsMissing() {
        // A name gives a title and a year, never an author.
        let item = bare("1979-godel-escher-bach.pdf")

        XCTAssertEqual(bibEntries(for: [item], type: .book).first?.missing, ["author"])
        XCTAssertEqual(bibEntries(for: [item], type: .article).first?.missing, ["author"])
        XCTAssertEqual(bibEntries(for: [item], type: .report).first?.missing, ["author"])
        // Misc asks for a title and nothing else, so this is complete.
        XCTAssertEqual(bibEntries(for: [item], type: .misc).first?.missing, [])
        XCTAssertTrue(bibEntries(for: [item], type: .misc).first?.isComplete == true)
        // Online wants a year but not an author.
        XCTAssertEqual(bibEntries(for: [item], type: .online).first?.missing, [])
    }

    func testMissingYearIsReportedWhenTheTypeWantsOne() {
        let undated = bare("no-date-here.pdf")
        XCTAssertEqual(Set(bibEntries(for: [undated], type: .book).first?.missing ?? []),
                       ["author", "year"])
        XCTAssertEqual(bibEntries(for: [undated], type: .online).first?.missing, ["year"])
        XCTAssertEqual(bibEntries(for: [undated], type: .misc).first?.missing, [])
    }

    func testTheTypeIsWrittenOut() {
        for type in BibType.allCases {
            let entry = bibEntries(for: [bare("1979-x.pdf")], type: type)[0]
            XCTAssertTrue(bibtexBlock(entry).hasPrefix("@\(type.keyword){"),
                          "\(type) should write @\(type.keyword)")
        }
        // techreport is spelled out even though the option is called report.
        XCTAssertEqual(BibType.report.keyword, "techreport")
    }

    func testTheFileFieldCanBeLeftOut() {
        let entry = bibEntries(for: [bare("1979-x.pdf")])[0]
        XCTAssertTrue(bibtexBlock(entry).contains("file"))
        XCTAssertFalse(bibtexBlock(entry, style: BibStyle(omit: ["file"])).contains("file"))
    }
}
