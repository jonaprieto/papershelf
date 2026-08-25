import XCTest
import PDFKit
@testable import PDFHammerCore

final class HammerTests: XCTestCase {

    /// Fixtures are encrypted with this, not with anything real.
    private let fixturePassword = "correct-horse-battery"


    func testSpecExamples() {
        XCTAssertEqual(normalizedName(for: "Cuenta_ABC123_2024-06.pdf"), "2024-06-cuenta_abc123.pdf")
        XCTAssertEqual(normalizedName(for: "2024-broker-account-statement.pdf"), "2024-broker-account-statement.pdf")
        XCTAssertEqual(normalizedName(for: "reporte-anual-de-costos-2024.pdf"), "2024-reporte-anual-de-costos.pdf")
    }

    func testDatePrefixIsNotDuplicated() {
        XCTAssertEqual(normalizedName(for: "2024-06-cuenta_abc123.pdf"), "2024-06-cuenta_abc123.pdf")
    }

    func testMonthBeatsBareYear() {
        XCTAssertEqual(normalizedName(for: "2024 summary 2023-11.pdf"), "2023-11-2024-summary.pdf")
    }

    func testDigitRunIsNotSplit() {
        XCTAssertEqual(normalizedName(for: "invoice20240612.pdf"), "invoice20240612.pdf")
    }

    func testInvalidMonthFallsBackToYear() {
        XCTAssertEqual(normalizedName(for: "acme-2024-13-report.pdf"), "2024-acme-13-report.pdf")
    }

    func testFallbackUsedWhenNameHasNoDate() {
        let date = DateComponents(calendar: .current, year: 2021, month: 3, day: 9).date!
        XCTAssertEqual(normalizedName(for: "Bank Statement.pdf", fallbackPrefixes: [monthPrefix(date)]),
                       "2021-03-bank-statement.pdf")
    }

    func testFallbacksAreTriedInOrder() {
        XCTAssertEqual(normalizedName(for: "Bank Statement.pdf", fallbackPrefixes: ["", "2019-04", "2020-01"]),
                       "2019-04-bank-statement.pdf")
    }

    func testNoDateAnywhereJustSlugifies() {
        XCTAssertEqual(normalizedName(for: "Bank  Statement.pdf"), "bank-statement.pdf")
    }

    func testDateOnlyNameSurvives() {
        XCTAssertEqual(normalizedName(for: "2024-06.pdf"), "2024-06.pdf")
    }

    // MARK: - File operations

    func testBackupTreeMirrorsSubfolders() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let nested = root.appendingPathComponent("bank/2024")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)

        let pdf = nested.appendingPathComponent("Extracto_2024-06.pdf")
        try makePDF(at: pdf, password: nil)

        let jobs = collectJobs(roots: [root], recursive: true)
        XCTAssertEqual(jobs.count, 1)

        let results = process(jobs: jobs, options: Options(passwords: [], recursive: true, dryRun: false))
        XCTAssertEqual(results.first?.status, .renamed)
        XCTAssertEqual(results.first?.destinationName, "2024-06-extracto.pdf")
        XCTAssertTrue(fm.fileExists(atPath: nested.appendingPathComponent("2024-06-extracto.pdf").path))
        XCTAssertTrue(fm.fileExists(atPath:
            root.appendingPathComponent("original_pdfs/bank/2024/Extracto_2024-06.pdf").path))
        XCTAssertFalse(fm.fileExists(atPath: pdf.path))
    }

    func testPasswordIsRemoved() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let pdf = root.appendingPathComponent("Secret_2023-01.pdf")
        try makePDF(at: pdf, password: fixturePassword)

        let jobs = collectJobs(roots: [root], recursive: false)
        let results = process(jobs: jobs, options: Options(passwords: ["nope", fixturePassword],
                                                           recursive: false, dryRun: false))
        XCTAssertEqual(results.first?.status, .decrypted)

        let out = root.appendingPathComponent("2023-01-secret.pdf")
        let doc = try XCTUnwrap(loadPDF(out))
        XCTAssertFalse(doc.isEncrypted)
        XCTAssertFalse(doc.isLocked)
        XCTAssertEqual(doc.pageCount, 1)
    }

    func testWrongPasswordStillRenamesAndStaysLocked() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let pdf = root.appendingPathComponent("Secret_2023-02.pdf")
        try makePDF(at: pdf, password: "correct-horse")

        let jobs = collectJobs(roots: [root], recursive: false)
        let results = process(jobs: jobs, options: Options(passwords: ["wrong"],
                                                           recursive: false, dryRun: false))
        XCTAssertEqual(results.first?.status, .locked)

        let out = root.appendingPathComponent("2023-02-secret.pdf")
        let doc = try XCTUnwrap(loadPDF(out))
        XCTAssertTrue(doc.isLocked)
    }

    func testDryRunTouchesNothing() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let pdf = root.appendingPathComponent("Extracto_2024-06.pdf")
        try makePDF(at: pdf, password: nil)

        let jobs = collectJobs(roots: [root], recursive: false)
        let results = process(jobs: jobs, options: Options(passwords: [], recursive: false, dryRun: true))
        XCTAssertEqual(results.first?.destinationName, "2024-06-extracto.pdf")
        XCTAssertTrue(fm.fileExists(atPath: pdf.path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".pdf") }, ["Extracto_2024-06.pdf"])
    }

    func testCollidingNamesGetSuffixes() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        try makePDF(at: root.appendingPathComponent("Report_2024-06.pdf"), password: nil)
        try makePDF(at: root.appendingPathComponent("report-2024-06.pdf"), password: nil)

        let jobs = collectJobs(roots: [root], recursive: false)
        XCTAssertEqual(jobs.count, 2)
        let results = process(jobs: jobs, options: Options(passwords: [], recursive: false, dryRun: false))
        let names = Set(results.map(\.destinationName))
        XCTAssertEqual(names, ["2024-06-report.pdf", "2024-06-report-2.pdf"])
    }

    func testBackupDirectoryIsNeverReprocessed() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try makePDF(at: root.appendingPathComponent("Extracto_2024-06.pdf"), password: nil)

        let options = Options(passwords: [], recursive: true, dryRun: false)
        _ = process(jobs: collectJobs(roots: [root], recursive: true), options: options)
        let second = collectJobs(roots: [root], recursive: true)
        XCTAssertEqual(second.map(\.file.lastPathComponent), ["2024-06-extracto.pdf"])
    }

    // MARK: - Date shapes and metadata

    func testDayMonthYearInFilename() {
        XCTAssertEqual(normalizedName(for: "extracto_23_08_2026_acme66.pdf"),
                       "2026-08-extracto_acme66.pdf")
        XCTAssertEqual(normalizedName(for: "extracto_23_08_2026_acme66 (3).pdf"),
                       "2026-08-extracto_acme66-(3).pdf")
    }

    func testYearMonthDayInFilename() {
        XCTAssertEqual(normalizedName(for: "statement 2026-08-23 acme.pdf"),
                       "2026-08-statement-acme.pdf")
    }

    /// A date in the filename is the only one the document itself asserts. An annual
    /// statement for 2024 is routinely generated in 2025, so a timestamp taken off the
    /// file must never displace it.
    func testFilenameDateIsNeverDisplacedByAFallback() {
        XCTAssertEqual(normalizedName(for: "2024-broker-tax-report.pdf", fallbackPrefixes: ["2015-09"]),
                       "2024-broker-tax-report.pdf")
        XCTAssertEqual(normalizedName(for: "extracto_23_08_2026_acme66.pdf", fallbackPrefixes: ["2021-05"]),
                       "2026-08-extracto_acme66.pdf")
    }

    func testMetadataDateOnlyFillsAGap() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try makePDF(at: root.appendingPathComponent("Extracto_1999-01.pdf"), password: nil)
        try makePDF(at: root.appendingPathComponent("Sin Fecha.pdf"), password: nil)

        let results = process(
            jobs: collectJobs(roots: [root], recursive: true),
            options: Options(passwords: [], recursive: true, dryRun: true,
                             useFolderNames: false, useMetadataDate: true)
        )
        let bySource = Dictionary(uniqueKeysWithValues: results.map { ($0.sourceName, $0.destinationName) })

        // The fixtures were written moments ago, so their creation date is this month.
        let thisMonth = monthPrefix(Date())
        XCTAssertEqual(bySource["Extracto_1999-01.pdf"], "1999-01-extracto.pdf")
        XCTAssertEqual(bySource["Sin Fecha.pdf"], "\(thisMonth)-sin-fecha.pdf")
    }

    // MARK: - Folder context

    func testFolderDateFillsAMissingFilenameDate() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let nested = root.appendingPathComponent("bank/2024")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try makePDF(at: nested.appendingPathComponent("Extracto Marzo.pdf"), password: nil)

        let results = process(jobs: collectJobs(roots: [root], recursive: true),
                              options: Options(passwords: [], recursive: true, dryRun: true))
        XCTAssertEqual(results.first?.destinationName, "2024-extracto-marzo.pdf")
    }

    func testFolderNameReplacesAnUninformativeStem() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let nested = root.appendingPathComponent("2025-acme66")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try makePDF(at: nested.appendingPathComponent("scan001.pdf"), password: nil)
        try makePDF(at: nested.appendingPathComponent("Extracto Agosto.pdf"), password: nil)

        let results = process(jobs: collectJobs(roots: [root], recursive: true),
                              options: Options(passwords: [], recursive: true, dryRun: true))
        let bySource = Dictionary(uniqueKeysWithValues: results.map { ($0.sourceName, $0.destinationName) })
        XCTAssertEqual(bySource["scan001.pdf"], "2025-acme66-scan001.pdf")
        // A stem that already says something is left alone.
        XCTAssertEqual(bySource["Extracto Agosto.pdf"], "2025-extracto-agosto.pdf")
    }

    func testFolderContextWalksUpToTheSelectedRoot() {
        let root = URL(fileURLWithPath: "/tmp/pick")
        let file = root.appendingPathComponent("bank/2024/doc.pdf")
        let context = folderContext(for: file, under: root)
        XCTAssertEqual(context.prefix, "2024")
        XCTAssertEqual(context.slug, "bank")
    }

    func testFolderContextIsOffByRequest() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let nested = root.appendingPathComponent("2024")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try makePDF(at: nested.appendingPathComponent("Extracto Marzo.pdf"), password: nil)

        let results = process(jobs: collectJobs(roots: [root], recursive: true),
                              options: Options(passwords: [], recursive: true, dryRun: true,
                                               useFolderNames: false))
        XCTAssertEqual(results.first?.destinationName, "extracto-marzo.pdf")
    }

    // MARK: - Whitespace

    func testEveryKindOfWhitespaceIsRemoved() {
        // Non-breaking space, tab, and a plain space.
        XCTAssertEqual(normalizedName(for: "Extracto\u{00A0}Marzo\tAcme 66 2024.pdf"),
                       "2024-extracto-marzo-acme-66.pdf")
    }

    func testWithoutBackupTheOriginalIsReplacedInPlace() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let pdf = root.appendingPathComponent("Secret_2023-01.pdf")
        try makePDF(at: pdf, password: fixturePassword)

        let results = process(jobs: collectJobs(roots: [root], recursive: false),
                              options: Options(passwords: [fixturePassword], recursive: false,
                                               dryRun: false, backup: BackupSettings(enabled: false)))
        XCTAssertEqual(results.first?.status, .decrypted)
        XCTAssertFalse(fm.fileExists(atPath: pdf.path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("original_pdfs").path))

        let out = root.appendingPathComponent("2023-01-secret.pdf")
        let doc = try XCTUnwrap(loadPDF(out))
        XCTAssertFalse(doc.isEncrypted)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".pdf") },
                       ["2023-01-secret.pdf"])
    }

    func testRelativePathTracksSubfolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let nested = root.appendingPathComponent("bank/2024")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try makePDF(at: nested.appendingPathComponent("Extracto_2024-06.pdf"), password: nil)

        let results = process(jobs: collectJobs(roots: [root], recursive: true),
                              options: Options(passwords: [], recursive: true, dryRun: true))
        XCTAssertEqual(results.first?.relativePath, "bank/2024/Extracto_2024-06.pdf")
        XCTAssertEqual(results.first?.root, root)
    }

    // MARK: - Results tree

    private func fakeItems(_ root: URL, _ relativePaths: [String]) -> [Item] {
        relativePaths.map {
            Item(root: root, source: root.appendingPathComponent($0),
                 destination: root.appendingPathComponent($0), status: .renamed)
        }
    }

    func testTreeFlattensOneRootWithNoSubfolders() {
        let root = URL(fileURLWithPath: "/tmp/pick")
        let tree = buildTree(fakeItems(root, ["a.pdf", "b.pdf"]))
        XCTAssertEqual(tree.map(\.name), ["a.pdf", "b.pdf"])
        XCTAssertTrue(tree.allSatisfy { $0.itemKey != nil })
    }

    func testTreeKeepsNestedFolders() {
        let root = URL(fileURLWithPath: "/tmp/pick")
        let tree = buildTree(fakeItems(root, ["top.pdf", "bank/2024/x.pdf", "bank/2024/y.pdf", "bank/z.pdf"]))
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].name, "pick")
        XCTAssertEqual((tree[0].children ?? []).map(\.name), ["top.pdf", "bank"])

        let bank = tree[0].children?.first { $0.name == "bank" }
        XCTAssertEqual((bank?.children ?? []).map(\.name), ["2024", "z.pdf"])
        let year = bank?.children?.first { $0.name == "2024" }
        XCTAssertEqual((year?.children ?? []).map(\.name), ["x.pdf", "y.pdf"])
    }

    func testTreeKeepsBothRootsWhenTwoAreSelected() {
        let a = URL(fileURLWithPath: "/tmp/one")
        let b = URL(fileURLWithPath: "/tmp/two")
        let tree = buildTree(fakeItems(a, ["x.pdf"]) + fakeItems(b, ["y.pdf"]))
        XCTAssertEqual(tree.map(\.name), ["one", "two"])
    }

    // MARK: - Name rules

    func testDefaultsMatchTheOriginalBehaviour() {
        XCTAssertEqual(normalizedName(for: "Cuenta_ABC123_2024-06.pdf", rules: .standard),
                       "2024-06-cuenta_abc123.pdf")
    }

    func testSeparatorNormalisation() {
        let name = "Extracto Marzo_Acme 66-2024.pdf"
        XCTAssertEqual(normalizedName(for: name, rules: NameRules(separator: .dash)),
                       "2024-extracto-marzo-acme-66.pdf")
        XCTAssertEqual(normalizedName(for: name, rules: NameRules(separator: .underscore)),
                       "2024_extracto_marzo_acme_66.pdf")
    }

    func testSnakeCaseKeepsTheDatePrefixDashed() {
        XCTAssertEqual(normalizedName(for: "Extracto 2024-06.pdf", rules: NameRules(separator: .underscore)),
                       "2024-06_extracto.pdf")
    }

    func testStripSymbolsTurnsPunctuationIntoSeparators() {
        XCTAssertEqual(
            normalizedName(for: "extracto_23_08_2026_acme66 (1).pdf",
                           rules: NameRules(separator: .dash, stripSymbols: true)),
            "2026-08-extracto-acme66-1.pdf")
        XCTAssertEqual(
            normalizedName(for: "report!!! [final]#2 2024.pdf",
                           rules: NameRules(separator: .dash, stripSymbols: true)),
            "2024-report-final-2.pdf")
    }

    func testSymbolsAreKeptWhenTheRuleIsOff() {
        XCTAssertEqual(normalizedName(for: "report (1) 2024.pdf", rules: NameRules(separator: .dash)),
                       "2024-report-(1).pdf")
    }

    func testStripDiacritics() {
        XCTAssertEqual(
            normalizedName(for: "Extracto Señor Muñoz 2024.pdf",
                           rules: NameRules(separator: .dash, stripDiacritics: true)),
            "2024-extracto-senor-munoz.pdf")
        XCTAssertEqual(
            normalizedName(for: "Extracto Señor 2024.pdf", rules: NameRules(separator: .dash)),
            "2024-extracto-señor.pdf")
    }

    func testCasing() {
        XCTAssertEqual(normalizedName(for: "Extracto Marzo 2024.pdf",
                                      rules: NameRules(casing: .unchanged, separator: .dash)),
                       "2024-Extracto-Marzo.pdf")
        XCTAssertEqual(normalizedName(for: "Extracto Marzo 2024.pdf",
                                      rules: NameRules(casing: .uppercase, separator: .dash)),
                       "2024-EXTRACTO-MARZO.pdf")
    }

    func testStrippedNameCannotCollapseToNothing() {
        XCTAssertEqual(normalizedName(for: "!!! 2024.pdf", rules: NameRules(separator: .dash, stripSymbols: true)),
                       "2024.pdf")
        // Nothing survives the rules and there is no date to fall back on, so the
        // original name is left alone rather than reduced to ".pdf".
        XCTAssertEqual(normalizedName(for: "!!!.pdf", rules: NameRules(separator: .dash, stripSymbols: true)),
                       "!!!.pdf")
    }

    // MARK: - Typed names

    func testSanitizedFilename() {
        XCTAssertEqual(sanitizedFilename("2024-report"), "2024-report.pdf")
        XCTAssertEqual(sanitizedFilename("  spaced  "), "spaced.pdf")
        XCTAssertEqual(sanitizedFilename("a/b:c.pdf"), "a-b-c.pdf")
        XCTAssertEqual(sanitizedFilename(""), "untitled.pdf")
        XCTAssertEqual(sanitizedFilename("   "), "untitled.pdf")
        XCTAssertEqual(sanitizedFilename("../../etc/passwd"), "etc-passwd.pdf")
        XCTAssertEqual(sanitizedFilename(".hidden"), "hidden.pdf")
        XCTAssertEqual(sanitizedFilename("Already.PDF"), "Already.PDF")
        // A key built from a caller's URL still matches one from the filesystem.
        XCTAssertEqual(jobKeyRoundTrip(), true)
    }

    private func jobKeyRoundTrip() -> Bool {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let pdf = root.appendingPathComponent("x.pdf")
        fm.createFile(atPath: pdf.path, contents: Data())
        let jobs = collectJobs(roots: [root], recursive: true)
        return jobs.first?.key == pdf.resolvingSymlinksInPath().path
    }

    func testOverrideReplacesTheSuggestedName() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let pdf = root.appendingPathComponent("Secret_2023-01.pdf")
        try makePDF(at: pdf, password: fixturePassword)

        let jobs = collectJobs(roots: [root], recursive: true)
        let results = process(jobs: jobs,
                              options: Options(passwords: [fixturePassword], recursive: true, dryRun: false),
                              overrides: [jobs[0].key: "mi extracto/enero"])
        XCTAssertEqual(results.first?.status, .decrypted)
        XCTAssertEqual(results.first?.destinationName, "mi extracto-enero.pdf")
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("mi extracto-enero.pdf").path))
    }

    func testOverrideStillGetsACollisionSuffix() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try makePDF(at: root.appendingPathComponent("a.pdf"), password: nil)
        try makePDF(at: root.appendingPathComponent("b.pdf"), password: nil)

        let jobs = collectJobs(roots: [root], recursive: true)
        let overrides = Dictionary(uniqueKeysWithValues: jobs.map { ($0.key, "same") })
        let results = process(jobs: jobs,
                              options: Options(passwords: [], recursive: true, dryRun: false),
                              overrides: overrides)
        XCTAssertEqual(Set(results.map(\.destinationName)), ["same.pdf", "same-2.pdf"])
    }

    // MARK: - Deletion

    func testTrashedFileGoesToTheTrashNotOblivion() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try makePDF(at: root.appendingPathComponent("junk_2024-01.pdf"), password: nil)
        try makePDF(at: root.appendingPathComponent("keep_2024-02.pdf"), password: nil)

        let jobs = collectJobs(roots: [root], recursive: true)
        let doomed = try XCTUnwrap(jobs.first { $0.file.lastPathComponent.hasPrefix("junk") })

        let results = process(jobs: jobs,
                              options: Options(passwords: [], recursive: true, dryRun: false),
                              trashed: [doomed.key])
        let byName = Dictionary(uniqueKeysWithValues: results.map { ($0.sourceName, $0) })

        let trashed = try XCTUnwrap(byName["junk_2024-01.pdf"])
        XCTAssertEqual(trashed.status, .trashed)
        XCTAssertFalse(fm.fileExists(atPath: doomed.file.path))
        // Recoverable: the file still exists, at the URL the Trash gave back.
        XCTAssertTrue(fm.fileExists(atPath: trashed.destination.path))
        try? fm.removeItem(at: trashed.destination)

        XCTAssertEqual(byName["keep_2024-02.pdf"]?.status, .renamed)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("2024-02-keep.pdf").path))
    }

    func testDryRunNeverTrashesAnything() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let pdf = root.appendingPathComponent("junk_2024-01.pdf")
        try makePDF(at: pdf, password: nil)

        let jobs = collectJobs(roots: [root], recursive: true)
        let results = process(jobs: jobs,
                              options: Options(passwords: [], recursive: true, dryRun: true),
                              trashed: Set(jobs.map(\.key)))
        XCTAssertEqual(results.first?.status, .trashed)
        XCTAssertTrue(fm.fileExists(atPath: pdf.path))
    }

    // MARK: - Password list

    func testAddingAPasswordAlwaysAddsARow() {
        XCTAssertEqual(PasswordList.rows("").count, 1)
        // The case that used to dead-end: with the list emptied, Add did nothing.
        XCTAssertEqual(PasswordList.rows(PasswordList.adding(to: "")).count, 2)
        XCTAssertEqual(PasswordList.rows(PasswordList.adding(to: "a")).count, 2)
        XCTAssertEqual(PasswordList.rows(PasswordList.adding(to: "a\nb")).count, 3)
    }

    func testEditingAndRemovingRows() {
        XCTAssertEqual(PasswordList.setting(1, to: "beta", in: "a\nb"), "a\nbeta")
        XCTAssertEqual(PasswordList.setting(0, to: "no\nnewlines", in: "a"), "nonewlines")
        XCTAssertEqual(PasswordList.setting(9, to: "x", in: "a"), "a")
        XCTAssertEqual(PasswordList.removing(0, from: "a\nb"), "b")
        XCTAssertEqual(PasswordList.removing(9, from: "a"), "a")
        // Removing the last row leaves one blank row, never zero.
        XCTAssertEqual(PasswordList.rows(PasswordList.removing(0, from: "a")).count, 1)
    }

    func testActivePasswordsIgnoreBlanksPaddingAndDuplicates() {
        XCTAssertEqual(PasswordList.active("  a  \n\n b\n   "), ["a", "b"])
        XCTAssertEqual(PasswordList.active(""), [])
        XCTAssertEqual(PasswordList.active("a\nb\na\n a "), ["a", "b"])
    }

    func testAddingRowReusesATrailingBlankInsteadOfStacking() {
        // A fresh blank row is offered rather than a second one piled on top.
        let first = PasswordList.addingRow(to: "a")
        XCTAssertEqual(first.text, "a\n")
        XCTAssertEqual(first.focus, 1)

        let again = PasswordList.addingRow(to: first.text)
        XCTAssertEqual(again.text, first.text)
        XCTAssertEqual(again.focus, 1)

        // An emptied list still has one row to type into.
        XCTAssertEqual(PasswordList.addingRow(to: "").focus, 0)
        XCTAssertEqual(PasswordList.addingRow(to: "").text, "")
    }

    // MARK: - Folder scope

    func testItemsUnderFolderIncludesNestedButNotSiblings() {
        let root = URL(fileURLWithPath: "/tmp/pick")
        let list = fakeItems(root, [
            "bank/a.pdf",
            "bank/2024/b.pdf",
            "bank-old/c.pdf",
            "other.pdf",
        ])
        let bank = items(under: "/tmp/pick/bank", in: list).map(\.sourceName)
        XCTAssertEqual(Set(bank), ["a.pdf", "b.pdf"])
        XCTAssertEqual(items(under: "/tmp/pick/bank-old", in: list).map(\.sourceName), ["c.pdf"])
        XCTAssertEqual(items(under: "/tmp/pick", in: list).count, 4)
    }

    func testFolderPathOfAnItem() {
        let root = URL(fileURLWithPath: "/tmp/pick")
        let item = fakeItems(root, ["bank/2024/b.pdf"])[0]
        XCTAssertEqual(folderPath(of: item), "/tmp/pick/bank/2024")
        XCTAssertEqual(items(under: folderPath(of: item), in: [item]).count, 1)
    }

    // MARK: - Restyling without re-reading

    func testRestyleFollowsTheRulesWithoutOpeningAnything() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try makePDF(at: root.appendingPathComponent("Extracto Señor (1) 2024-06.pdf"), password: nil)

        let base = Options(passwords: [], recursive: true, dryRun: true, useFolderNames: false)
        let item = try XCTUnwrap(process(jobs: collectJobs(roots: [root], recursive: true),
                                         options: base).first)
        XCTAssertEqual(item.destinationName, "2024-06-extracto-señor-(1).pdf")

        var strict = base
        strict.rules = NameRules(separator: .dash, stripSymbols: true, stripDiacritics: true)
        XCTAssertEqual(restyled(item, options: strict).destinationName,
                       "2024-06-extracto-senor-1.pdf")

        var snake = base
        snake.rules = NameRules(separator: .underscore, stripSymbols: true)
        XCTAssertEqual(restyled(item, options: snake).destinationName,
                       "2024-06_extracto_señor_1.pdf")

        // Restyling is a pure recomputation: the file is untouched either way.
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Extracto Señor (1) 2024-06.pdf").path))
    }

    func testRestyleReusesTheCapturedDatesForGapFilling() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try makePDF(at: root.appendingPathComponent("Sin Fecha.pdf"), password: nil)

        let base = Options(passwords: [], recursive: true, dryRun: true, useFolderNames: false)
        let item = try XCTUnwrap(process(jobs: collectJobs(roots: [root], recursive: true),
                                         options: base).first)
        XCTAssertEqual(item.destinationName, "sin-fecha.pdf")
        XCTAssertNotNil(item.metadataDate)

        var withMetadata = base
        withMetadata.useMetadataDate = true
        XCTAssertEqual(restyled(item, options: withMetadata).destinationName,
                       "\(monthPrefix(Date()))-sin-fecha.pdf")
    }

    // MARK: - Duplicates

    func testDuplicateKeyIgnoresDatesAndCopyMarkers() {
        let same = [
            "Godel Escher Bach.pdf",
            "godel-escher-bach.pdf",
            "Godel Escher Bach (1).pdf",
            "Godel Escher Bach (2).pdf",
            "godel_escher_bach copy.pdf",
            "Godel Escher Bach 2024.pdf",
            "godel escher bach-2.pdf",
        ].map(duplicateKey(for:))
        XCTAssertEqual(Set(same).count, 1, "all spellings should collapse to one key")
        XCTAssertEqual(same[0], "godelescherbach")

        // A number that is part of the title must survive. Only a dash or underscore
        // with no space in front marks a copy.
        XCTAssertNotEqual(duplicateKey(for: "Catch 22.pdf"), duplicateKey(for: "Catch.pdf"))
        XCTAssertEqual(duplicateKey(for: "Catch 22.pdf"), duplicateKey(for: "catch-22-2.pdf"))
        XCTAssertNotEqual(duplicateKey(for: "Book One.pdf"), duplicateKey(for: "Book Two.pdf"))
    }

    func testIdenticalBytesAreFoundAndTheBiggestCopyIsKept() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("shelf"), withIntermediateDirectories: true)

        try makePDF(at: root.appendingPathComponent("Dune.pdf"), password: nil)
        let bytes = try Data(contentsOf: root.appendingPathComponent("Dune.pdf"))
        try bytes.write(to: root.appendingPathComponent("shelf/Dune (1).pdf"))
        // Same name shape, but genuinely different content and larger.
        try makePDF(at: root.appendingPathComponent("Neuromancer.pdf"), password: nil)

        let items = process(jobs: collectJobs(roots: [root], recursive: true),
                            options: Options(passwords: [], recursive: true, dryRun: true))
        let groups = duplicateGroups(in: items)

        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.kind, .identical)
        XCTAssertEqual(Set(group.items.map(\.sourceName)), ["Dune.pdf", "Dune (1).pdf"])
        // Same size, so the shorter name wins.
        XCTAssertEqual(group.keeper.sourceName, "Dune.pdf")
        XCTAssertEqual(group.extras.map(\.sourceName), ["Dune (1).pdf"])
    }

    func testDifferentContentIsNotADuplicateEvenAtTheSameSize() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // Same byte count, different bytes: size alone must not be trusted.
        let a = Data(repeating: 0x41, count: 4096)
        let b = Data(repeating: 0x42, count: 4096)
        try a.write(to: root.appendingPathComponent("Alpha.pdf"))
        try b.write(to: root.appendingPathComponent("Beta.pdf"))

        let items = process(jobs: collectJobs(roots: [root], recursive: true),
                            options: Options(passwords: [], recursive: true, dryRun: true))
        XCTAssertEqual(duplicateGroups(in: items).count, 0)
    }

    func testLikelyDuplicatesAreFoundByName() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // Same book, re-downloaded, so the bytes differ but the name barely does.
        try makePDF(at: root.appendingPathComponent("The Pragmatic Programmer.pdf"), password: nil)
        try makePDF(at: root.appendingPathComponent("the-pragmatic-programmer (1).pdf"), password: "x")
        try makePDF(at: root.appendingPathComponent("Refactoring.pdf"), password: nil)

        let items = process(jobs: collectJobs(roots: [root], recursive: true),
                            options: Options(passwords: [], recursive: true, dryRun: true))
        let groups = duplicateGroups(in: items)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.kind, .likely)
        XCTAssertEqual(groups.first?.items.count, 2)
    }

    func testAFileIsNeverInTwoGroups() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        try makePDF(at: root.appendingPathComponent("Dune.pdf"), password: nil)
        let bytes = try Data(contentsOf: root.appendingPathComponent("Dune.pdf"))
        try bytes.write(to: root.appendingPathComponent("Dune (1).pdf"))
        try bytes.write(to: root.appendingPathComponent("dune-2.pdf"))

        let items = process(jobs: collectJobs(roots: [root], recursive: true),
                            options: Options(passwords: [], recursive: true, dryRun: true))
        let groups = duplicateGroups(in: items)
        let keys = groups.flatMap { $0.items.map(\.key) }
        XCTAssertEqual(keys.count, Set(keys).count, "no file may appear in two groups")
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.items.count, 3)
    }

    // MARK: - Sources

    func testSourcesStayANonOverlappingSet() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let shelf = root.appendingPathComponent("shelf")
        let scifi = shelf.appendingPathComponent("scifi")
        try fm.createDirectory(at: scifi, withIntermediateDirectories: true)
        let book = scifi.appendingPathComponent("Dune.pdf")
        try makePDF(at: book, password: nil)

        // The same folder twice is one entry.
        XCTAssertEqual(mergedSources([], adding: [shelf, shelf]).count, 1)

        // A subfolder of something already selected is not added.
        XCTAssertEqual(mergedSources([shelf], adding: [scifi]).map(\.lastPathComponent), ["shelf"])

        // Nor is a file inside it.
        XCTAssertEqual(mergedSources([shelf], adding: [book]).map(\.lastPathComponent), ["shelf"])

        // Selecting the parent afterwards absorbs what was already there.
        XCTAssertEqual(mergedSources([scifi, book], adding: [shelf]).map(\.lastPathComponent), ["shelf"])

        // Siblings coexist, and a name that merely shares a prefix is not "inside".
        let other = root.appendingPathComponent("shelf-old")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertEqual(Set(mergedSources([shelf], adding: [other]).map(\.lastPathComponent)),
                       ["shelf", "shelf-old"])
    }

    func testOverlappingSourcesWouldOtherwiseSplitTheBackupLocation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let inner = root.appendingPathComponent("inner")
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        try makePDF(at: inner.appendingPathComponent("Extracto_2024-06.pdf"), password: nil)

        // Merged first, the file is attributed to the outer root only.
        let sources = mergedSources([], adding: [root, inner])
        XCTAssertEqual(sources.count, 1)
        let jobs = collectJobs(roots: sources, recursive: true)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.root.lastPathComponent, root.lastPathComponent)
    }

    // MARK: - Backup location

    func testBackupFolderCanBeRenamed() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("bank"), withIntermediateDirectories: true)
        try makePDF(at: root.appendingPathComponent("bank/Extracto_2024-06.pdf"), password: nil)

        let backup = BackupSettings(folderName: "originales")
        let options = Options(passwords: [], recursive: true, dryRun: false, backup: backup)
        _ = process(jobs: collectJobs(roots: [root], recursive: true, backup: backup), options: options)

        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("originales/bank/Extracto_2024-06.pdf").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("bank/2024-06-extracto.pdf").path))

        // And the renamed folder is skipped on a second run, as original_pdfs was.
        let again = collectJobs(roots: [root], recursive: true, backup: backup)
        XCTAssertEqual(again.map(\.file.lastPathComponent), ["2024-06-extracto.pdf"])
    }

    func testCustomBackupLocationKeepsRootsApart() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let one = base.appendingPathComponent("one")
        let two = base.appendingPathComponent("two")
        let vault = base.appendingPathComponent("vault")
        for dir in [one, two] {
            try fm.createDirectory(at: dir.appendingPathComponent("2024"), withIntermediateDirectories: true)
            try makePDF(at: dir.appendingPathComponent("2024/statement.pdf"), password: nil)
        }

        let backup = BackupSettings(customLocation: vault)
        let jobs = collectJobs(roots: [one, two], recursive: true, backup: backup)
        _ = process(jobs: jobs, options: Options(passwords: [], recursive: true, dryRun: false, backup: backup))

        // Same relative path under both roots, so the root name has to disambiguate.
        XCTAssertTrue(fm.fileExists(atPath: vault.appendingPathComponent("one/2024/statement.pdf").path))
        XCTAssertTrue(fm.fileExists(atPath: vault.appendingPathComponent("two/2024/statement.pdf").path))
    }

    func testUnsafeBackupNamesFallBackToTheDefault() {
        for bad in ["", "   ", "..", "../escape", "a/b", ".hidden", "with:colon"] {
            XCTAssertEqual(BackupSettings(folderName: bad).safeFolderName, defaultBackupFolderName,
                           "\(bad) must not be used as a folder name")
        }
        XCTAssertEqual(BackupSettings(folderName: " originales ").safeFolderName, "originales")
    }

    // MARK: - Case-only renames

    /// On a case-insensitive volume the old and new names are the same file, so nothing
    /// has collided and no suffix belongs on the result.
    func testLoweringTheCaseIsNotACollision() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try makePDF(at: root.appendingPathComponent("Bus-Oslo-Airport.pdf"), password: nil)

        let options = Options(passwords: [], recursive: true, dryRun: true,
                              rules: NameRules(separator: .dash))
        let preview = process(jobs: collectJobs(roots: [root], recursive: true), options: options)
        XCTAssertEqual(preview.first?.destinationName, "bus-oslo-airport.pdf")

        let applied = process(jobs: collectJobs(roots: [root], recursive: true),
                              options: Options(passwords: [], recursive: true, dryRun: false,
                                               rules: NameRules(separator: .dash)))
        XCTAssertEqual(applied.first?.destinationName, "bus-oslo-airport.pdf")
    }

    func testARealCollisionStillGetsASuffix() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try makePDF(at: root.appendingPathComponent("Report A 2024.pdf"), password: nil)
        try makePDF(at: root.appendingPathComponent("report-a-2024.pdf"), password: nil)

        let results = process(jobs: collectJobs(roots: [root], recursive: true),
                              options: Options(passwords: [], recursive: true, dryRun: false,
                                               rules: NameRules(separator: .dash)))
        XCTAssertEqual(Set(results.map(\.destinationName)), ["2024-report-a.pdf", "2024-report-a-2.pdf"])
    }
}

extension HammerTests {

    // MARK: - Moving files

    func testMoveSendsTheFileUnderItsNewName() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("inbox")
        let shelf = base.appendingPathComponent("shelf/scifi")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try makePDF(at: root.appendingPathComponent("Dune 1965.pdf"), password: nil)

        let jobs = collectJobs(roots: [root], recursive: true)
        let results = process(jobs: jobs,
                              options: Options(passwords: [], recursive: true, dryRun: false,
                                               useFolderNames: false,
                                               rules: NameRules(separator: .dash)),
                              moves: [jobs[0].key: shelf])

        XCTAssertEqual(results.first?.status, .moved)
        // The destination folder did not exist, and the file arrives normalized.
        XCTAssertTrue(fm.fileExists(atPath: shelf.appendingPathComponent("1965-dune.pdf").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Dune 1965.pdf").path))
        // Moving is not rewriting, so nothing is backed up.
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("original_pdfs").path))
    }

    func testMoveHonoursATypedNameAndAvoidsCollisions() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("inbox")
        let shelf = base.appendingPathComponent("shelf")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: shelf, withIntermediateDirectories: true)
        try makePDF(at: root.appendingPathComponent("a.pdf"), password: nil)
        try makePDF(at: root.appendingPathComponent("b.pdf"), password: nil)
        try makePDF(at: shelf.appendingPathComponent("taken.pdf"), password: nil)

        let jobs = collectJobs(roots: [root], recursive: true)
        let moves = Dictionary(uniqueKeysWithValues: jobs.map { ($0.key, shelf) })
        let overrides = Dictionary(uniqueKeysWithValues: jobs.map { ($0.key, "taken") })
        let results = process(jobs: jobs,
                              options: Options(passwords: [], recursive: true, dryRun: false),
                              overrides: overrides, moves: moves)

        XCTAssertEqual(Set(results.map(\.status)), [.moved])
        XCTAssertEqual(Set(results.map(\.destinationName)), ["taken-2.pdf", "taken-3.pdf"])
        // The file already sitting there is untouched.
        XCTAssertTrue(fm.fileExists(atPath: shelf.appendingPathComponent("taken.pdf").path))
    }

    func testDryRunMovesNothing() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("inbox")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try makePDF(at: root.appendingPathComponent("Dune 1965.pdf"), password: nil)

        let jobs = collectJobs(roots: [root], recursive: true)
        let shelf = base.appendingPathComponent("shelf")
        let results = process(jobs: jobs,
                              options: Options(passwords: [], recursive: true, dryRun: true),
                              moves: [jobs[0].key: shelf])
        XCTAssertEqual(results.first?.status, .moved)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Dune 1965.pdf").path))
        XCTAssertFalse(fm.fileExists(atPath: shelf.path))
    }
}

extension HammerTests {

    // MARK: - The newer name rules

    func testDatePositionAndFormat() {
        let name = "Extracto Marzo 2024-06.pdf"
        XCTAssertEqual(normalizedName(for: name, rules: NameRules(separator: .dash)),
                       "2024-06-extracto-marzo.pdf")
        XCTAssertEqual(normalizedName(for: name, rules: NameRules(separator: .dash, datePosition: .suffix)),
                       "extracto-marzo-2024-06.pdf")
        XCTAssertEqual(normalizedName(for: name, rules: NameRules(separator: .dash, dateFormat: .compact)),
                       "202406-extracto-marzo.pdf")
        XCTAssertEqual(normalizedName(for: name, rules: NameRules(separator: .dash,
                                                                 datePosition: .suffix,
                                                                 dateFormat: .compact)),
                       "extracto-marzo-202406.pdf")
    }

    func testLeadingArticlesCanBeDropped() {
        let rules = NameRules(separator: .dash, dropLeadingArticles: true)
        XCTAssertEqual(normalizedName(for: "The Pragmatic Programmer 1999.pdf", rules: rules),
                       "1999-pragmatic-programmer.pdf")
        XCTAssertEqual(normalizedName(for: "El Aleph 1945.pdf", rules: rules), "1945-aleph.pdf")
        // Only leading ones, and only whole words.
        XCTAssertEqual(normalizedName(for: "Theory of Games 1944.pdf", rules: rules),
                       "1944-theory-of-games.pdf")
        XCTAssertEqual(normalizedName(for: "A Tale of Two Cities.pdf", rules: rules),
                       "tale-of-two-cities.pdf")
    }

    func testMaxLengthCutsOnAWordBoundary() {
        let rules = NameRules(separator: .dash, maxLength: 20)
        // The limit applies to the slug, never to the date or the extension. Twenty
        // characters reaches into "an", so the cut falls back to the boundary before it.
        XCTAssertEqual(normalizedName(for: "Godel Escher Bach an Eternal Golden Braid 1979.pdf", rules: rules),
                       "1979-godel-escher-bach.pdf")
        // One word with no boundary inside the budget is cut at the budget, not lost.
        XCTAssertEqual(normalizedName(for: "Supercalifragilisticexpialidocious.pdf", rules: rules),
                       "supercalifragilistic.pdf")
        XCTAssertEqual(normalizedName(for: "short 2020.pdf", rules: rules), "2020-short.pdf")
    }

    func testAsciiOnlyBreaksRatherThanGluing() {
        let rules = NameRules(separator: .dash, asciiOnly: true)
        // Unrepresentable characters become breaks, so words do not run together.
        XCTAssertEqual(normalizedName(for: "日本語 book 2020.pdf", rules: rules), "2020-book.pdf")
        XCTAssertEqual(normalizedName(for: "Señor Muñoz 2020.pdf", rules: rules), "2020-se-or-mu-oz.pdf")
        // Folding accents first keeps the words whole, which is usually what is wanted.
        XCTAssertEqual(
            normalizedName(for: "Señor Muñoz 2020.pdf",
                           rules: NameRules(separator: .dash, stripDiacritics: true, asciiOnly: true)),
            "2020-senor-munoz.pdf")
    }

    func testTheNewRulesAreOffByDefault() {
        XCTAssertEqual(normalizedName(for: "The Señor 2024.pdf", rules: .standard), "2024-the-señor.pdf")
    }
}

extension HammerTests {

    // MARK: - File statistics

    func testItemsCarryTheirSizeAndLength() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try makePDF(at: root.appendingPathComponent("Plain 2024.pdf"), password: nil)
        try makePDF(at: root.appendingPathComponent("Locked 2024.pdf"), password: "shut")

        let results = process(jobs: collectJobs(roots: [root], recursive: true),
                              options: Options(passwords: [], recursive: true, dryRun: true))
        let byName = Dictionary(uniqueKeysWithValues: results.map { ($0.sourceName, $0) })

        let plain = try XCTUnwrap(byName["Plain 2024.pdf"])
        XCTAssertEqual(plain.pageCount, 1)
        XCTAssertGreaterThan(plain.byteCount ?? 0, 0)
        XCTAssertNotNil(plain.modifiedDate)

        // The page tree is not encrypted, so a locked file still reports its length even
        // though no password matched.
        let locked = try XCTUnwrap(byName["Locked 2024.pdf"])
        XCTAssertEqual(locked.status, .locked)
        XCTAssertEqual(locked.pageCount, 1)
        XCTAssertGreaterThan(locked.byteCount ?? 0, 0)
    }
}

extension HammerTests {

    // MARK: - Duplicates by content

    private var chapter: String {
        String(repeating: "The quick brown fox jumps over the lazy dog near the riverbank. ", count: 12)
    }

    func testSameOpeningPagesAreFoundEvenWhenTheBytesDiffer() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // The same text twice: once plain, once encrypted. Different bytes, same book,
        // and names that share nothing, so only content can match them.
        try makeTextPDF(at: root.appendingPathComponent("Dune.pdf"), text: chapter)
        try makeTextPDF(at: root.appendingPathComponent("wholly-different-name.pdf"),
                        text: chapter, password: "shut")
        try makeTextPDF(at: root.appendingPathComponent("Neuromancer.pdf"),
                        text: String(repeating: "A wholly unrelated body of prose here. ", count: 12))

        let items = process(jobs: collectJobs(roots: [root], recursive: true),
                            options: Options(passwords: ["shut"], recursive: true, dryRun: true))
        let groups = duplicateGroups(in: items, passwords: ["shut"])

        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.kind, .sameText)
        XCTAssertEqual(Set(group.items.map(\.sourceName)), ["Dune.pdf", "wholly-different-name.pdf"])
    }

    /// Without a floor on how much text counts, every scan with no text layer would
    /// fingerprint the same and the whole shelf would be one giant group.
    func testTextlessScansAreNotAllDuplicatesOfEachOther() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // Drawn rectangles, no text layer, and names that do not match either.
        try makePDF(at: root.appendingPathComponent("scan-one.pdf"), password: nil)
        try makePDF(at: root.appendingPathComponent("another-thing.pdf"), password: "a")
        try makeTextPDF(at: root.appendingPathComponent("too-short.pdf"), text: "Hello.")

        let items = process(jobs: collectJobs(roots: [root], recursive: true),
                            options: Options(passwords: ["a"], recursive: true, dryRun: true))
        for item in items { XCTAssertNil(contentKey(for: item, passwords: ["a"])) }
        XCTAssertEqual(duplicateGroups(in: items, passwords: ["a"]).count, 0)
    }

    func testIdenticalBytesWinOverContent() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try makeTextPDF(at: root.appendingPathComponent("a.pdf"), text: chapter)
        let bytes = try Data(contentsOf: root.appendingPathComponent("a.pdf"))
        try bytes.write(to: root.appendingPathComponent("b.pdf"))

        let items = process(jobs: collectJobs(roots: [root], recursive: true),
                            options: Options(passwords: [], recursive: true, dryRun: true))
        let groups = duplicateGroups(in: items)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.kind, .identical, "byte equality is the stronger claim")
    }
}

extension HammerTests {

    // MARK: - Sorting

    private func sortable(_ name: String, size: Int, pages: Int, day: Int) -> Item {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        return Item(root: root, source: root.appendingPathComponent(name),
                    destination: root.appendingPathComponent("out-" + name), status: .renamed,
                    modifiedDate: Date(timeIntervalSince1970: Double(day) * 86_400),
                    byteCount: size, pageCount: pages)
    }

    func testSortOrders() {
        let items = [
            sortable("b.pdf", size: 300, pages: 10, day: 3),
            sortable("a.pdf", size: 100, pages: 30, day: 1),
            sortable("c.pdf", size: 200, pages: 20, day: 2),
        ]

        XCTAssertEqual(sorted(items, by: .originalName).map(\.sourceName),
                       ["a.pdf", "b.pdf", "c.pdf"])
        // Size, pages and date read biggest or newest first, which is the question asked.
        XCTAssertEqual(sorted(items, by: .size).map(\.sourceName), ["b.pdf", "c.pdf", "a.pdf"])
        XCTAssertEqual(sorted(items, by: .pages).map(\.sourceName), ["a.pdf", "c.pdf", "b.pdf"])
        XCTAssertEqual(sorted(items, by: .modified).map(\.sourceName), ["b.pdf", "c.pdf", "a.pdf"])
        // And the direction can be turned around: 100, 200, 300.
        XCTAssertEqual(sorted(items, by: .size, descending: false).map(\.sourceName),
                       ["a.pdf", "c.pdf", "b.pdf"])
    }

    /// Numbers inside names sort the way a person reads them, not by character code.
    func testNamesSortNaturally() {
        let items = [sortable("chapter 10.pdf", size: 1, pages: 1, day: 1),
                     sortable("chapter 9.pdf", size: 1, pages: 1, day: 1),
                     sortable("chapter 2.pdf", size: 1, pages: 1, day: 1)]
        XCTAssertEqual(sorted(items, by: .originalName).map(\.sourceName),
                       ["chapter 2.pdf", "chapter 9.pdf", "chapter 10.pdf"])
    }

    func testSortingIsStableForEqualKeys() {
        let items = (1...5).map { sortable("f\($0).pdf", size: 100, pages: 1, day: 1) }
        XCTAssertEqual(sorted(items, by: .size).map(\.sourceName),
                       sorted(items, by: .size).map(\.sourceName))
    }
}

extension HammerTests {

    // MARK: - Locking output back up

    func testOutputCanBeEncryptedWithADifferentPassword() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try makePDF(at: root.appendingPathComponent("Locked 2024-06.pdf"), password: "old-one")
        try makePDF(at: root.appendingPathComponent("Plain 2024-07.pdf"), password: nil)

        let options = Options(passwords: ["old-one"], recursive: true, dryRun: false,
                              encryption: EncryptionSettings(enabled: true, password: "new-one"))
        let results = process(jobs: collectJobs(roots: [root], recursive: true), options: options)
        XCTAssertEqual(Set(results.map(\.status)), [.encrypted])

        // Both come out locked with the new password, whatever they started as.
        for name in ["2024-06-locked.pdf", "2024-07-plain.pdf"] {
            let doc = try XCTUnwrap(loadPDF(root.appendingPathComponent(name)))
            XCTAssertTrue(doc.isLocked, "\(name) should be locked")
            XCTAssertFalse(doc.unlock(withPassword: "old-one"), "the old password must not open it")
            XCTAssertTrue(doc.unlock(withPassword: "new-one"))
            XCTAssertEqual(doc.pageCount, 1)
        }
    }

    func testEncryptionWithoutAPasswordIsIgnored() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try makePDF(at: root.appendingPathComponent("Plain 2024-07.pdf"), password: nil)

        // Enabled but empty is not a request to encrypt with nothing.
        XCTAssertFalse(EncryptionSettings(enabled: true, password: "").isUsable)
        let results = process(jobs: collectJobs(roots: [root], recursive: true),
                              options: Options(passwords: [], recursive: true, dryRun: false,
                                               encryption: EncryptionSettings(enabled: true)))
        XCTAssertEqual(results.first?.status, .renamed)
        let doc = try XCTUnwrap(loadPDF(root.appendingPathComponent("2024-07-plain.pdf")))
        XCTAssertFalse(doc.isLocked)
    }

    func testAFileNoPasswordOpensIsNotReEncrypted() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try makePDF(at: root.appendingPathComponent("Sealed 2024-06.pdf"), password: "unknown")

        let results = process(jobs: collectJobs(roots: [root], recursive: true),
                              options: Options(passwords: ["wrong"], recursive: true, dryRun: false,
                                               encryption: EncryptionSettings(enabled: true,
                                                                              password: "new-one")))
        // Still sealed with its own password: it passes through untouched rather than
        // being re-locked with one that would strand it.
        XCTAssertEqual(results.first?.status, .locked)
        let doc = try XCTUnwrap(loadPDF(root.appendingPathComponent("2024-06-sealed.pdf")))
        XCTAssertTrue(doc.unlock(withPassword: "unknown"))
    }
}

extension HammerTests {

    func testDocumentInfoIsCapturedWhenReadable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("COA 2024.pdf")
        try makeTextPDF(at: url, text: "Coalgebras and their uses.")
        let doc = try XCTUnwrap(loadPDF(url))
        doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] = "Coalgebras"
        doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] = "Cosme"
        XCTAssertTrue(doc.write(to: url))

        let items = process(jobs: collectJobs(roots: [root], recursive: true),
                            options: Options(passwords: [], recursive: true, dryRun: true))
        XCTAssertEqual(items.first?.documentInfo["Title"], "Coalgebras")
        XCTAssertEqual(items.first?.documentInfo["Author"], "Cosme")
    }

    /// A locked file's attributes cannot be read, and empty values are not recorded as
    /// if they were facts.
    func testUnreadableOrBlankInfoIsNotInvented() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pdfnorm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try makePDF(at: root.appendingPathComponent("Sealed 2024.pdf"), password: "shut")

        let items = process(jobs: collectJobs(roots: [root], recursive: true),
                            options: Options(passwords: [], recursive: true, dryRun: true))
        XCTAssertEqual(items.first?.status, .locked)
        XCTAssertNil(items.first?.documentInfo["Title"])
        XCTAssertFalse(items.first?.documentInfo.values.contains("") ?? false)
    }
}
