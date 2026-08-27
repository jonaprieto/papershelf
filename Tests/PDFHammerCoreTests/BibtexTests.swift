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
        let block = bibtexBlock(longEntry(), style: BibStyle(lineWidth: 80, omit: []))
        for line in block.components(separatedBy: "\n") {
            XCTAssertLessThanOrEqual(line.count, 80, "line over budget: \(line)")
        }
        XCTAssertTrue(block.contains("\n"), "the long title should have wrapped")

        // Off means one line per field, however long.
        let unwrapped = bibtexBlock(longEntry(), style: BibStyle(lineWidth: 0, omit: []))
        XCTAssertEqual(unwrapped.components(separatedBy: "\n").count, 6)
    }

    /// Breaking a path to satisfy a column is worse than going over it.
    func testAWordLongerThanTheBudgetIsLeftWhole() {
        let path = "/Users/someone/Library/CloudStorage/Provider-account/shelf/a-very-long-file-name.pdf"
        let entry = BibEntry(itemKey: path, key: "k", title: "T", author: nil, year: nil, file: path)
        let block = bibtexBlock(entry, style: BibStyle(lineWidth: 40, omit: []))
        XCTAssertTrue(block.contains(path), "the path must survive intact")
    }

    func testStyleOptions() {
        let entry = longEntry()

        let quoted = bibtexBlock(entry, style: BibStyle(lineWidth: 0, delimiter: .quotes, omit: []))
        XCTAssertTrue(quoted.contains("= \"Hofstadter\","))

        let noComma = bibtexBlock(entry, style: BibStyle(lineWidth: 0, trailingComma: false, omit: []))
        XCTAssertTrue(noComma.contains("{/tmp/a.pdf}\n}"), "last field should have no comma")

        let sorted = bibtexBlock(entry, style: BibStyle(lineWidth: 0, sortFields: true, omit: []))
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

    func testTheFileFieldIsOmittedByDefault() {
        // A source PDF's local path has no business in a bibliography meant for a
        // paper, so the default field filter leaves it out; asking for it back works.
        let entry = bibEntries(for: [bare("1979-x.pdf")])[0]
        XCTAssertFalse(bibtexBlock(entry).contains("file"))
        XCTAssertTrue(bibtexBlock(entry, style: BibStyle(omit: [])).contains("file"))
    }
}

extension BibtexTests {

    // MARK: - Required-field validation

    /// Only what a filename plus an AI guess can ever supply: title, author, year.
    private func minimalEntry(_ type: BibType) -> BibEntry {
        BibEntry(itemKey: "k", key: "k", title: "T", author: "A", year: "2020",
                 file: "/tmp/a.pdf", type: type)
    }

    /// Every field this app can hold a value for, so every requirement group in every
    /// standard has something to point at.
    private func fullEntry(_ type: BibType) -> BibEntry {
        BibEntry(itemKey: "k", key: "k", title: "T", author: "A", editor: "E", year: "2020",
                 month: "jan", journal: "J", booktitle: "B", publisher: "P", institution: "I",
                 school: "S", pages: "1--2", doi: "10.1/x", url: "https://example.com",
                 file: "/tmp/a.pdf", type: type)
    }

    func testAFullyPopulatedEntryValidatesUnderBothStandards() {
        for type in BibType.allCases {
            for standard in BibStandard.allCases {
                XCTAssertTrue(fullEntry(type).isValid(for: standard),
                              "\(type) should validate under \(standard.label) once every field is set")
            }
        }
    }

    func testRequiredFieldValidationPerEntryType() {
        // Classic BibTeX and biblatex disagree about what several of these types need,
        // which is exactly what makes checking against both worthwhile.
        XCTAssertEqual(minimalEntry(.book).gaps(for: .classic), ["publisher"])
        XCTAssertEqual(minimalEntry(.book).gaps(for: .biblatex), [])

        XCTAssertEqual(minimalEntry(.article).gaps(for: .classic), ["journal"])
        XCTAssertEqual(minimalEntry(.article).gaps(for: .biblatex), ["journal"])

        XCTAssertEqual(minimalEntry(.inproceedings).gaps(for: .classic), ["booktitle"])
        XCTAssertEqual(minimalEntry(.inproceedings).gaps(for: .biblatex), ["booktitle"])

        XCTAssertEqual(minimalEntry(.incollection).gaps(for: .classic), ["booktitle", "publisher"])
        XCTAssertEqual(minimalEntry(.incollection).gaps(for: .biblatex), ["editor", "booktitle"])

        XCTAssertEqual(minimalEntry(.report).gaps(for: .classic), ["institution"])
        XCTAssertEqual(minimalEntry(.report).gaps(for: .biblatex), ["institution"])

        XCTAssertEqual(minimalEntry(.thesis).gaps(for: .classic), ["school"])
        XCTAssertEqual(minimalEntry(.thesis).gaps(for: .biblatex), ["institution"])

        XCTAssertEqual(minimalEntry(.misc).gaps(for: .classic), [])
        XCTAssertEqual(minimalEntry(.misc).gaps(for: .biblatex), [])

        XCTAssertEqual(minimalEntry(.online).gaps(for: .classic), [])
        XCTAssertEqual(minimalEntry(.online).gaps(for: .biblatex), ["doi"])

        XCTAssertFalse(minimalEntry(.book).isValid(for: .classic))
        XCTAssertTrue(minimalEntry(.misc).isValid(for: .classic))
    }
}

extension BibtexTests {

    // MARK: - Correctness

    func testTitleCapitalsSurviveARoundTrip() throws {
        let entry = BibEntry(itemKey: "k", key: "k", title: "Gödel, Escher, Bach", file: "/tmp/a.pdf")
        let block = bibtexBlock(entry, style: BibStyle(lineWidth: 0, protectCapitals: true))

        // Every capitalized word but the first is individually brace-protected...
        XCTAssertTrue(block.contains("{Escher,}"))
        XCTAssertTrue(block.contains("{Bach}"))
        XCTAssertFalse(block.contains("{Gödel,}"), "the first word needs no protection")

        // ...and stripping those protective braces reproduces the title exactly.
        let value = try XCTUnwrap(bibtexTokens(block).first { $0.kind == .value }?.text)
        let stripped = value.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        XCTAssertEqual(stripped, entry.title)
    }

    func testAuthorListsCanonicalize() {
        XCTAssertEqual(canonicalAuthorList("Ludwig van Beethoven"), "van Beethoven, Ludwig")
        XCTAssertEqual(canonicalAuthorList("Jean de la Fontaine and Donald Knuth"),
                       "de la Fontaine, Jean and Knuth, Donald")
        XCTAssertEqual(canonicalAuthorList("Beethoven, Ludwig"), "Beethoven, Ludwig")
        XCTAssertEqual(canonicalAuthorList("Gates, Jr, Henry Louis"), "Gates, Jr, Henry Louis")

        let entry = BibEntry(itemKey: "k", key: "k", title: "T", author: "Ludwig van Beethoven",
                             file: "/tmp/a.pdf")
        let block = bibtexBlock(entry, style: BibStyle(lineWidth: 0, canonicalizeAuthors: true))
        XCTAssertTrue(block.contains("{van Beethoven, Ludwig}"))
    }

    func testPageRangesUseTheDoubleDash() {
        XCTAssertEqual(bibtexPageRange("7-33"), "7--33")
        XCTAssertEqual(bibtexPageRange("7--33"), "7--33")
        XCTAssertEqual(bibtexPageRange("7,41,73-97"), "7,41,73--97")
        XCTAssertEqual(bibtexPageRange("43+"), "43+")

        let entry = BibEntry(itemKey: "k", key: "k", title: "T", pages: "7-33", file: "/tmp/a.pdf")
        let block = bibtexBlock(entry, style: BibStyle(lineWidth: 0, normalizePageRanges: true))
        XCTAssertTrue(block.contains("pages = {7--33},"))
    }

    func testMonthsCanBeWrittenAsMacros() {
        XCTAssertEqual(bibtexMonthMacro("July"), "jul")
        XCTAssertEqual(bibtexMonthMacro("7"), "jul")
        XCTAssertEqual(bibtexMonthMacro("07"), "jul")
        XCTAssertEqual(bibtexMonthMacro("jul"), "jul")
        XCTAssertNil(bibtexMonthMacro("not a month"))

        let entry = BibEntry(itemKey: "k", key: "k", title: "T", month: "July", file: "/tmp/a.pdf")
        let asGiven = bibtexBlock(entry, style: BibStyle(lineWidth: 0))
        XCTAssertTrue(asGiven.contains("month = {July},"))

        let macro = bibtexBlock(entry, style: BibStyle(lineWidth: 0, monthStyle: .macro))
        XCTAssertTrue(macro.contains("month = jul,"), "a macro needs no braces")
    }

    func testUnicodeCanBeEscapedOrPreserved() {
        let entry = BibEntry(itemKey: "k", key: "k", title: "Café François", file: "/tmp/a.pdf")

        let preserved = bibtexBlock(entry, style: BibStyle(lineWidth: 0))
        XCTAssertTrue(preserved.contains("Café François"))

        let escaped = bibtexBlock(entry, style: BibStyle(lineWidth: 0, unicodeHandling: .escape))
        XCTAssertTrue(escaped.contains("Caf\\'{e} Fran\\c{c}ois"))
    }

    func testNumericFieldsAreWrittenBare() {
        let entry = BibEntry(itemKey: "k", key: "k", title: "T", year: "1979", file: "/tmp/a.pdf")
        XCTAssertTrue(bibtexBlock(entry, style: BibStyle(lineWidth: 0)).contains("= {1979},"))
        let numeric = bibtexBlock(entry, style: BibStyle(lineWidth: 0, numericFields: true))
        XCTAssertTrue(numeric.contains("= 1979,"))
        XCTAssertFalse(numeric.contains("{1979}"), "a numeric field should carry no braces")
    }

    func testEmptyFieldsAreDroppedByDefault() {
        let entry = BibEntry(itemKey: "k", key: "k", title: "T", author: "", file: "/tmp/a.pdf")
        XCTAssertFalse(bibtexBlock(entry).contains("author"))
        XCTAssertTrue(bibtexBlock(entry, style: BibStyle(dropEmptyFields: false)).contains("author"))
    }

    func testFieldOrderPromotesNamedFieldsFirst() {
        let entry = BibEntry(itemKey: "k", key: "k", title: "T", author: "A", year: "2020",
                             file: "/tmp/a.pdf")
        let block = bibtexBlock(entry, style: BibStyle(lineWidth: 0, omit: [], fieldOrder: ["year", "title"]))
        let names = block.components(separatedBy: "\n").dropFirst().dropLast()
            .map { $0.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0] }
        XCTAssertEqual(names, ["year", "title", "author", "file"])
    }
}
