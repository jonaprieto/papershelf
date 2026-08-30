import XCTest
@testable import PaperShelfCore

/// The pattern reaches Plan and Apply.
///
/// It did not, for as long as the editor existed: `render` had every piece and nothing
/// called it, the sidebar footer said so out loud ("Not used yet: Plan and Apply still use
/// Name rules below"), and a person could arrange chips all afternoon and rename nothing.
/// These cover the wiring, and the two things that had to stay true once it was wired —
/// that the tidying rules still decide how each piece is written, and that the three date
/// switches still mean something.
final class PatternPipelineTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/tmp/pattern-pipeline")

    private func item(
        _ name: String,
        metadataDate: Date? = nil,
        modifiedDate: Date? = nil,
        documentInfo: [String: String] = [:]
    ) -> Item {
        let source = root.appendingPathComponent(name)
        return Item(root: root, source: source, destination: source, status: .renamed,
                    metadataDate: metadataDate, modifiedDate: modifiedDate,
                    documentInfo: documentInfo)
    }

    private func date(_ year: Int, _ month: Int) -> Date {
        DateComponents(calendar: .current, year: year, month: month, day: 15).date!
    }

    private func options(pattern: NamePattern? = nil,
                         rules: NameRules = .standard,
                         useFolderNames: Bool = true,
                         useMetadataDate: Bool = true,
                         useFileDate: Bool = false) -> Options {
        Options(passwords: [], recursive: true, dryRun: true,
                useFolderNames: useFolderNames,
                useMetadataDate: useMetadataDate,
                useFileDate: useFileDate,
                rules: rules,
                pattern: pattern)
    }

    // MARK: The wiring itself

    func testPatternDecidesTheName() {
        let pattern = NamePattern(parsing: "[author:surname]-[year]-[title]")
        let guess = BookGuess(title: "Causality", author: "Judea Pearl", year: "2009")
        let renamed = restyled(item("causality_2ed_pearl.pdf"), options: options(pattern: pattern), guess: guess)
        XCTAssertEqual(renamed.destinationName, "pearl-2009-causality.pdf")
    }

    func testProcessUsesTheSamePatternAsPlan() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName("pattern-process"), isDirectory: true)
        let file = directory.appendingPathComponent("Causality.pdf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeTextPDF(at: file, text: "Causality")

        let pattern = NamePattern(parsing: "[title]-reviewed")
        let result = try XCTUnwrap(process(
            jobs: [Job(root: directory, file: file)],
            options: options(pattern: pattern)
        ).first)
        XCTAssertEqual(result.destinationName, "causality-reviewed.pdf")
    }

    func testLibraryItemDefersPDFMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName("library-item"), isDirectory: true)
        let file = directory.appendingPathComponent("Reading Notes.pdf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeTextPDF(at: file, text: "Reading Notes")

        let result = libraryItem(for: Job(root: directory, file: file), options: options())
        XCTAssertNil(result.pageCount)
        XCTAssertEqual(result.destinationName, "reading-notes.pdf")
    }

    /// The regression guard. With no pattern set, every file must be named exactly the way
    /// it was before any of this existed.
    func testNoPatternMeansTheOrdinaryRename() {
        // `.standard` leaves separators as it finds them, so the underscore survives —
        // which is the point: this is the untouched behaviour, not a tidier one.
        let plain = restyled(item("Cuenta_ABC123_2024-06.pdf"), options: options())
        XCTAssertEqual(plain.destinationName, "2024-06-cuenta_abc123.pdf")
    }

    /// An empty pattern is the absence of an instruction, not an instruction to produce
    /// empty names — the text field starts empty and must not rename everything to
    /// "untitled.pdf" on the way to being typed into.
    func testAnEmptyPatternFallsBackRatherThanProducingNothing() {
        let empty = NamePattern(parsing: "")
        let renamed = restyled(item("Cuenta_ABC123_2024-06.pdf"), options: options(pattern: empty))
        XCTAssertEqual(renamed.destinationName, "2024-06-cuenta_abc123.pdf")
    }

    /// A pattern whose every token comes out empty has nothing to say about this file, so
    /// the ordinary rules get their turn instead of the file keeping a name nobody chose.
    func testAPatternThatResolvesToNothingHandsBack() {
        let pattern = NamePattern(parsing: "[publisher]-[journal]")
        let renamed = restyled(item("reporte-anual-2024.pdf"), options: options(pattern: pattern))
        XCTAssertEqual(renamed.destinationName, "2024-reporte-anual.pdf")
    }

    // MARK: The rules still decide how each piece is written

    func testTidyingRulesApplyToWhatThePatternProduces() {
        let pattern = NamePattern(parsing: "[title]")
        let rules = NameRules(casing: .lowercase, separator: .underscore,
                              stripSymbols: true, stripDiacritics: true,
                              asciiOnly: false, dropLeadingArticles: false,
                              maxLength: 0, datePosition: .prefix, dateFormat: .dashed)
        let renamed = restyled(item("Extracto Señor_Acme 66 (1).pdf"),
                               options: options(pattern: pattern, rules: rules))
        XCTAssertEqual(renamed.destinationName, "extracto_senor_acme_66_1.pdf")
    }

    func testCasingRuleReachesAPatternedName() {
        let pattern = NamePattern(parsing: "[title]")
        let rules = NameRules(casing: .uppercase, separator: .dash,
                              stripSymbols: false, stripDiacritics: false,
                              asciiOnly: false, dropLeadingArticles: false,
                              maxLength: 0, datePosition: .prefix, dateFormat: .dashed)
        let renamed = restyled(item("quiet-report.pdf"), options: options(pattern: pattern, rules: rules))
        XCTAssertEqual(renamed.destinationName, "QUIET-REPORT.pdf")
    }

    // MARK: The date switches still mean something

    /// The bug this closes before it could exist: wiring the pattern in without threading
    /// these would have left three switches in Settings that changed nothing.
    func testMetadataDateIsUsedOnlyWhenItsSwitchIsOn() {
        let pattern = NamePattern(parsing: "[date]-[title]")
        let scanned = item("scan.pdf", metadataDate: date(2019, 4))

        let withDate = restyled(scanned, options: options(pattern: pattern, useMetadataDate: true))
        XCTAssertEqual(withDate.destinationName, "2019-04-scan.pdf")

        let without = restyled(scanned, options: options(pattern: pattern, useMetadataDate: false))
        XCTAssertEqual(without.destinationName, "scan.pdf")
    }

    func testFileDateIsUsedOnlyWhenItsSwitchIsOn() {
        let pattern = NamePattern(parsing: "[date]-[title]")
        let touched = item("notes.pdf", modifiedDate: date(2022, 11))

        XCTAssertEqual(
            restyled(touched, options: options(pattern: pattern, useFileDate: true)).destinationName,
            "2022-11-notes.pdf")
        XCTAssertEqual(
            restyled(touched, options: options(pattern: pattern, useFileDate: false)).destinationName,
            "notes.pdf")
    }

    /// A date the filename states is not a fallback and is never subject to a switch: it
    /// is the only date the document itself asserts. An annual statement for 2024 is
    /// routinely generated in 2025.
    func testADateInTheFilenameSurvivesEverySwitchBeingOff() {
        let pattern = NamePattern(parsing: "[date]-[title]")
        let stated = item("reporte-anual-2024.pdf", metadataDate: date(2025, 2))
        let renamed = restyled(stated, options: options(pattern: pattern,
                                                        useFolderNames: false,
                                                        useMetadataDate: false,
                                                        useFileDate: false))
        XCTAssertEqual(renamed.destinationName, "2024-reporte-anual.pdf")
    }

    // MARK: What the editor shows is what the run produces

    /// The preview and the rename must agree, or the chips are a decoration of a different
    /// algorithm. Same pattern, same rules, same fallbacks, same answer.
    func testThePreviewAgreesWithWhatPlanWouldDo() {
        let pattern = NamePattern(parsing: "[author:surname]-[year]-[title:max20]")
        let guess = BookGuess(title: "The Elements of Statistical Learning",
                              author: "Trevor Hastie", year: "2009")
        let file = item("Hastie_ESLII_print12.pdf")
        let rules = NameRules.standard

        let shown = preview(pattern, for: file, guess: guess, under: root,
                            rules: rules, fallbacks: .all).renderedName
        let done = restyled(file, options: options(pattern: pattern, rules: rules), guess: guess)
            .destinationName
        XCTAssertEqual(shown, done)
    }
}
