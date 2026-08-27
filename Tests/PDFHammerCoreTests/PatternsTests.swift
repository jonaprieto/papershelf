import XCTest
import PDFKit
@testable import PDFHammerCore

final class PatternsTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/tmp/pick")

    private func item(
        _ name: String,
        metadataDate: Date? = nil,
        modifiedDate: Date? = nil,
        documentInfo: [String: String] = [:]
    ) -> Item {
        let source = root.appendingPathComponent(name)
        return Item(root: root, source: source, destination: source, status: .renamed,
                    metadataDate: metadataDate, modifiedDate: modifiedDate, documentInfo: documentInfo)
    }

    private func date(_ year: Int, _ month: Int) -> Date {
        DateComponents(calendar: .current, year: year, month: month, day: 15).date!
    }

    // MARK: - Token resolution: date/year

    func testDateTokenFromFilename() {
        let pattern = NamePattern(elements: [.token(NameToken(.date))])
        XCTAssertEqual(render(pattern, for: item("Extracto_2024-06.pdf")), "2024-06.pdf")
    }

    func testDateTokenPrefersGuessYearOverStemDate() {
        let pattern = NamePattern(elements: [.token(NameToken(.date))])
        let guess = BookGuess(title: "Old Scan", author: nil, year: "1776")
        XCTAssertEqual(render(pattern, for: item("1949-old-scan.pdf"), guess: guess), "1776.pdf")
    }

    func testDateTokenFallsBackToFolder() {
        let pattern = NamePattern(elements: [.token(NameToken(.date))])
        let folder = FolderContext(prefix: "2021-03", slug: "bank")
        XCTAssertEqual(render(pattern, for: item("Statement.pdf"), folder: folder), "2021-03.pdf")
    }

    func testDateTokenFallsBackToMetadataThenFileDate() {
        let pattern = NamePattern(elements: [.token(NameToken(.date))])
        XCTAssertEqual(render(pattern, for: item("Statement.pdf", metadataDate: date(2020, 5))), "2020-05.pdf")
        XCTAssertEqual(render(pattern, for: item("Statement.pdf", modifiedDate: date(2021, 1))), "2021-01.pdf")
    }

    func testYearTokenIsFirstFourDigitsOfDate() {
        let pattern = NamePattern(elements: [.token(NameToken(.year))])
        XCTAssertEqual(render(pattern, for: item("Report_2024-06.pdf")), "2024.pdf")
    }

    // MARK: - Token resolution: title

    func testTitleTokenPrefersGuess() {
        let pattern = NamePattern(elements: [.token(NameToken(.title))])
        let guess = BookGuess(title: "Frankenstein", author: nil, year: nil)
        XCTAssertEqual(render(pattern, for: item("whatever.pdf"), guess: guess), "Frankenstein.pdf")
    }

    func testTitleTokenReadsStemWithItsOwnDateLiftedOut() {
        let pattern = NamePattern(elements: [.token(NameToken(.title))])
        XCTAssertEqual(render(pattern, for: item("Report_2024-06.pdf")), "Report.pdf")
    }

    func testTitleTokenBorrowsFolderWhenStemHasNoLetters() {
        let pattern = NamePattern(elements: [.token(NameToken(.title))])
        let folder = FolderContext(prefix: nil, slug: "acme66")
        XCTAssertEqual(render(pattern, for: item("20240612.pdf"), folder: folder), "acme66.pdf")
    }

    func testTitleTokenKeepsUninformativeStemWhenNoFolderIsKnown() {
        let pattern = NamePattern(elements: [.token(NameToken(.title))])
        XCTAssertEqual(render(pattern, for: item("20240612.pdf")), "20240612.pdf")
    }

    // MARK: - Token resolution: author, publisher, journal, folder, stem, counter

    func testAuthorTokenPrefersGuessOverDocumentInfo() {
        let pattern = NamePattern(elements: [.token(NameToken(.author))])
        let info = [PDFDocumentAttribute.authorAttribute.rawValue: "Ada Lovelace"]
        XCTAssertEqual(render(pattern, for: item("x.pdf", documentInfo: info)), "Ada Lovelace.pdf")

        let guess = BookGuess(title: "x", author: "Mary Shelley", year: nil)
        XCTAssertEqual(render(pattern, for: item("x.pdf", documentInfo: info), guess: guess), "Mary Shelley.pdf")
    }

    func testPublisherAndJournalReadDocumentInfoWhenPresent() {
        let pattern = NamePattern(elements: [.token(NameToken(.publisher)), .literal("-"), .token(NameToken(.journal))])
        let info = ["Publisher": "O'Reilly", "Journal": "CACM"]
        XCTAssertEqual(render(pattern, for: item("x.pdf", documentInfo: info)), "O'Reilly-CACM.pdf")
    }

    func testPublisherAndJournalAreMissingByDefault() {
        // Nothing in this codebase populates these keys today (see NameToken.Kind's own
        // doc comment); this is the realistic case, not a contrived one.
        let pattern = NamePattern(elements: [
            .token(NameToken(.publisher)), .literal("-"),
            .token(NameToken(.journal)), .literal("-"),
            .token(NameToken(.title)),
        ])
        let guess = BookGuess(title: "Frankenstein", author: nil, year: nil)
        XCTAssertEqual(render(pattern, for: item("x.pdf"), guess: guess), "Frankenstein.pdf")
    }

    func testFolderToken() {
        let pattern = NamePattern(elements: [.token(NameToken(.folder))])
        let folder = FolderContext(prefix: "2024", slug: "bank")
        XCTAssertEqual(render(pattern, for: item("x.pdf"), folder: folder), "bank.pdf")
    }

    func testOriginalStemIsUntouchedUnlikeTitle() {
        let pattern = NamePattern(elements: [.token(NameToken(.originalStem))])
        XCTAssertEqual(render(pattern, for: item("Some Weird_Name 2024.pdf")), "Some Weird_Name 2024.pdf")
    }

    func testCounterTokenIsEmptyForTheFirstFileAndFilledOnCollision() {
        let pattern = NamePattern(elements: [.token(NameToken(.counter))])
        XCTAssertEqual(render(pattern, for: item("first-time.pdf"), collisionIndex: 1), "first-time.pdf",
                       "no counter token content, so the whole name falls back to the original")
        XCTAssertEqual(render(pattern, for: item("x.pdf"), collisionIndex: 3), "3.pdf")
    }

    // MARK: - Token options: casing

    func testCasingOptions() {
        let guess = BookGuess(title: "the great gatsby", author: nil, year: nil)
        func rendered(_ casing: NameToken.Casing) -> String {
            render(NamePattern(elements: [.token(NameToken(.title, casing: casing))]),
                   for: item("x.pdf"), guess: guess)
        }
        XCTAssertEqual(rendered(.upper), "THE GREAT GATSBY.pdf")
        XCTAssertEqual(rendered(.lower), "the great gatsby.pdf")
        XCTAssertEqual(rendered(.titleCase), "The Great Gatsby.pdf")
        XCTAssertEqual(rendered(.unchanged), "the great gatsby.pdf")
    }

    // MARK: - Token options: abbreviation

    func testCompactAbbreviationStripsDashFromDate() {
        let pattern = NamePattern(elements: [.token(NameToken(.date, abbreviation: .compact))])
        XCTAssertEqual(render(pattern, for: item("Extracto_2024-06.pdf")), "202406.pdf")
    }

    func testCompactAbbreviationIsANoOpWithNoDashToStrip() {
        let pattern = NamePattern(elements: [.token(NameToken(.date, abbreviation: .compact))])
        XCTAssertEqual(render(pattern, for: item("Report_2024.pdf")), "2024.pdf")
    }

    func testSurnameAbbreviationKeepsTextAfterLastSpace() {
        let pattern = NamePattern(elements: [.token(NameToken(.author, abbreviation: .surname))])
        let guess = BookGuess(title: "x", author: "Ada Lovelace", year: nil)
        XCTAssertEqual(render(pattern, for: item("x.pdf"), guess: guess), "Lovelace.pdf")
    }

    func testSurnameAbbreviationIsANoOpOnASingleWord() {
        let pattern = NamePattern(elements: [.token(NameToken(.author, abbreviation: .surname))])
        let guess = BookGuess(title: "x", author: "Cosme", year: nil)
        XCTAssertEqual(render(pattern, for: item("x.pdf"), guess: guess), "Cosme.pdf")
    }

    func testInitialsAbbreviationOnAMultiWordValue() {
        let pattern = NamePattern(elements: [.token(NameToken(.journal, abbreviation: .initials))])
        let info = ["Journal": "Journal of Machine Learning Research"]
        XCTAssertEqual(render(pattern, for: item("x.pdf", documentInfo: info)), "JOMLR.pdf")
    }

    func testInitialsAbbreviationOnASingleWord() {
        let pattern = NamePattern(elements: [.token(NameToken(.title, abbreviation: .initials))])
        let guess = BookGuess(title: "Frankenstein", author: nil, year: nil)
        XCTAssertEqual(render(pattern, for: item("x.pdf"), guess: guess), "F.pdf")
    }

    // MARK: - Token options: maxLength (own dedicated test: a length limit has to cut sensibly)

    func testTokenMaxLengthClipsOnAWordBoundary() {
        let pattern = NamePattern(elements: [.token(NameToken(.title, maxLength: 10))])
        let guess = BookGuess(title: "The Great Gatsby", author: nil, year: nil)
        XCTAssertEqual(render(pattern, for: item("x.pdf"), guess: guess), "The Great.pdf",
                       "cuts back to the last whole word inside the budget, not mid-word")
    }

    func testTokenMaxLengthCutsMidWordOnlyWhenNoBoundaryExistsInBudget() {
        let pattern = NamePattern(elements: [.token(NameToken(.title, maxLength: 4))])
        let guess = BookGuess(title: "Frankenstein", author: nil, year: nil)
        XCTAssertEqual(render(pattern, for: item("x.pdf"), guess: guess), "Fran.pdf")
    }

    func testPatternMaxTotalLengthClipsTheJoinedNameOnAWordBoundary() {
        let pattern = NamePattern(
            elements: [.token(NameToken(.author)), .literal(" - "), .token(NameToken(.title))],
            maxTotalLength: 15
        )
        let guess = BookGuess(title: "A Study In Scarlet", author: "Doyle", year: nil)
        let name = render(pattern, for: item("x.pdf"), guess: guess)
        XCTAssertEqual(name, "Doyle - A.pdf")
        XCTAssertLessThanOrEqual((name as NSString).deletingPathExtension.count, 15)
    }

    // MARK: - Failure mode: a missing token must not leave a stray separator or empty bracket

    func testMissingTokenAtStartDropsItsSeparator() {
        let pattern = NamePattern(elements: [.token(NameToken(.author)), .literal("-"), .token(NameToken(.title))])
        let guess = BookGuess(title: "Frankenstein", author: nil, year: nil)
        XCTAssertEqual(render(pattern, for: item("x.pdf"), guess: guess), "Frankenstein.pdf")
    }

    func testMissingTokenAtEndDropsItsSeparator() {
        // "2024.pdf": the whole stem is the date, so title resolves to nothing once its
        // own date is lifted out and there is no folder to borrow from.
        let pattern = NamePattern(elements: [.token(NameToken(.date)), .literal("-"), .token(NameToken(.title))])
        XCTAssertEqual(render(pattern, for: item("2024.pdf")), "2024.pdf")
    }

    func testMissingMiddleTokenLeavesExactlyOneSeparatorBehind() {
        let pattern = NamePattern(elements: [
            .token(NameToken(.author)), .literal("-"),
            .token(NameToken(.title)), .literal("-"),
            .token(NameToken(.year)),
        ])
        let guess = BookGuess(title: "", author: "Lovelace", year: nil)
        // "2024.pdf" makes .title resolve to nothing (see above) while .year still reads
        // the same stem's own date, so this exercises a real missing-middle-token case
        // rather than a token that was simply never asked to resolve.
        XCTAssertEqual(render(pattern, for: item("2024.pdf"), guess: guess), "Lovelace-2024.pdf",
                       "neither gluing the survivors together nor leaving both dashes behind")
    }

    func testAllTokensEmptyFallsBackToTheOriginalName() {
        let pattern = NamePattern(elements: [.token(NameToken(.author)), .literal("-"), .token(NameToken(.title))])
        XCTAssertEqual(render(pattern, for: item("2024.pdf")), "2024.pdf")
    }

    // MARK: - Failure mode: illegal filename characters

    func testIllegalFilenameCharactersAreSanitized() {
        let pattern = NamePattern(elements: [.token(NameToken(.author))])
        let guess = BookGuess(title: "x", author: "Doe/Roe: A Study", year: nil)
        let name = render(pattern, for: item("x.pdf"), guess: guess)
        XCTAssertEqual(name, "Doe-Roe- A Study.pdf")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
    }

    // MARK: - Failure mode: reserved names

    func testReservedDeviceNameIsRenamedRatherThanUsedVerbatim() {
        let pattern = NamePattern(elements: [.token(NameToken(.originalStem, casing: .lower))])
        XCTAssertEqual(render(pattern, for: item("CON.pdf")), "con-file.pdf")
    }

    func testANameThatOnlyContainsAReservedWordIsUnaffected() {
        let pattern = NamePattern(elements: [.token(NameToken(.originalStem, casing: .lower))])
        XCTAssertEqual(render(pattern, for: item("console.pdf")), "console.pdf")
    }

    func testReservedDeviceNameCheckIsCaseInsensitiveOnItsOwn() {
        // No `.lower` casing here: the previous test above only ever fed the reserved
        // check an already-lowercased value, so it could not tell a case-sensitive
        // comparison apart from the real, case-insensitive one. This uses the stem
        // verbatim so the check itself, not the token's own casing option, is on trial.
        let pattern = NamePattern(elements: [.token(NameToken(.originalStem))])
        XCTAssertEqual(render(pattern, for: item("CON.pdf")), "CON-file.pdf")
    }

    // MARK: - Failure mode: collision with an existing file

    func testAvailableNameIncrementsAnExplicitCounterToken() {
        let pattern = NamePattern(elements: [.token(NameToken(.title)), .literal("-"), .token(NameToken(.counter))])
        let guess = BookGuess(title: "Frankenstein", author: nil, year: nil)
        let taken: Set<String> = ["Frankenstein.pdf", "Frankenstein-2.pdf"]
        XCTAssertEqual(availableName(for: pattern, item: item("x.pdf"), guess: guess, existingNames: taken),
                       "Frankenstein-3.pdf")
    }

    func testAvailableNameRendersTheCounterTokenInPlaceRatherThanAppendingASuffix() {
        // The test above places `[counter]` right where a Hammer-style `-2`/`-3` suffix
        // would also land, so it cannot tell "the counter token was rendered" apart from
        // "the counter token was ignored and a generic suffix was appended instead": both
        // produce the byte-identical "Frankenstein-3.pdf". This pattern puts the counter
        // token somewhere a bolted-on suffix never would, so the two code paths diverge.
        let pattern = NamePattern(elements: [
            .literal("v"), .token(NameToken(.counter)), .literal("-"), .token(NameToken(.title)),
        ])
        let guess = BookGuess(title: "Frankenstein", author: nil, year: nil)
        let taken: Set<String> = ["vFrankenstein.pdf"]
        XCTAssertEqual(availableName(for: pattern, item: item("x.pdf"), guess: guess, existingNames: taken),
                       "v2-Frankenstein.pdf",
                       "the counter token itself resolves to 2, not a '-2' suffix bolted onto the base name")
    }

    func testAvailableNameAppendsASuffixWhenThereIsNoCounterToken() {
        let pattern = NamePattern(elements: [.token(NameToken(.title))])
        let guess = BookGuess(title: "Frankenstein", author: nil, year: nil)
        let taken: Set<String> = ["Frankenstein.pdf", "Frankenstein-2.pdf"]
        XCTAssertEqual(availableName(for: pattern, item: item("x.pdf"), guess: guess, existingNames: taken),
                       "Frankenstein-3.pdf")
    }

    func testAvailableNameReturnsTheBaseNameWhenNothingCollides() {
        let pattern = NamePattern(elements: [.token(NameToken(.title))])
        let guess = BookGuess(title: "Frankenstein", author: nil, year: nil)
        XCTAssertEqual(availableName(for: pattern, item: item("x.pdf"), guess: guess, existingNames: []),
                       "Frankenstein.pdf")
    }

    // MARK: - Compact string round trip

    func testRoundTripsThroughTextOverAGeneratedSetOfPatterns() {
        var patterns: [NamePattern] = []
        for kind in NameToken.Kind.allCases {
            for casing in NameToken.Casing.allCases {
                for abbreviation in NameToken.Abbreviation.allCases {
                    for maxLength in [0, 5, 40] {
                        let token = NameToken(kind, casing: casing, maxLength: maxLength, abbreviation: abbreviation)
                        patterns.append(NamePattern(elements: [
                            .literal("prefix-"),
                            .token(token),
                            .literal("-mid-"),
                            .token(NameToken(.year)),
                            .literal(" [odd] chars \\ end"),
                        ], maxTotalLength: maxLength))
                    }
                }
            }
        }
        XCTAssertGreaterThan(patterns.count, 100, "this needs to be a real generated set, not one example")

        for pattern in patterns {
            let roundTripped = NamePattern(parsing: pattern.text, maxTotalLength: pattern.maxTotalLength)
            XCTAssertEqual(roundTripped, pattern, "did not round-trip: \(pattern.text)")
        }
    }

    func testPresetsRoundTrip() {
        for preset in NamePattern.presets {
            XCTAssertEqual(NamePattern(parsing: preset.pattern.text), preset.pattern)
        }
    }

    // MARK: - Parsing safety: never silently lose a piece of an unparseable pattern

    func testUnknownTokenKindIsKeptAsLiteralText() {
        let pattern = NamePattern(parsing: "[bogus]-[title]")
        XCTAssertEqual(pattern.elements, [.literal("[bogus]-"), .token(NameToken(.title))])
        // Stable once normalised: re-parsing its own `.text` must not drift any further.
        XCTAssertEqual(NamePattern(parsing: pattern.text), pattern)
    }

    func testUnknownModifierKeepsTheWholeBracketAsLiteralText() {
        let pattern = NamePattern(parsing: "[title:bogus]")
        XCTAssertEqual(pattern.elements, [.literal("[title:bogus]")])
        XCTAssertEqual(NamePattern(parsing: pattern.text), pattern)
    }

    func testUnterminatedBracketIsKeptAsLiteralText() {
        let pattern = NamePattern(parsing: "[title")
        XCTAssertEqual(pattern.elements, [.literal("[title")])
    }

    // MARK: - Presets

    func testPresetsAreDistinctAndDescribed() {
        XCTAssertEqual(NamePattern.presets.count, 4)
        XCTAssertEqual(Set(NamePattern.presets.map(\.name)).count, 4, "no two presets share a name")
        for preset in NamePattern.presets {
            XCTAssertFalse(preset.summary.isEmpty, "\(preset.name) needs a one-line description")
        }
    }

    func testStatementPresetMatchesTodaysDefaultShape() {
        XCTAssertEqual(render(.statement, for: item("Extracto_2024-06.pdf")), "2024-06-Extracto.pdf")
    }

    func testBookPresetUsesSurnameYearTitle() {
        let guess = BookGuess(title: "Frankenstein", author: "Mary Shelley", year: "1818")
        XCTAssertEqual(render(.book, for: item("x.pdf"), guess: guess), "Shelley-1818-Frankenstein.pdf")
    }

    // MARK: - Preview

    func testPreviewMarksWhichTokensCameOutEmpty() {
        let pattern = NamePattern(elements: [.token(NameToken(.date)), .literal("-"), .token(NameToken(.title))])
        let result = preview(pattern, for: item("2024.pdf"))
        XCTAssertEqual(result.originalName, "2024.pdf")
        XCTAssertEqual(result.renderedName, "2024.pdf")
        XCTAssertEqual(result.tokens.count, 2)
        XCTAssertEqual(result.tokens[0].kind, .date)
        XCTAssertEqual(result.tokens[0].value, "2024")
        XCTAssertFalse(result.tokens[0].isEmpty)
        XCTAssertEqual(result.tokens[1].kind, .title)
        XCTAssertEqual(result.tokens[1].value, "")
        XCTAssertTrue(result.tokens[1].isEmpty)
    }

    func testPreviewWalksTheFolderWhenARootIsGiven() {
        let pattern = NamePattern(elements: [.token(NameToken(.folder))])
        let result = preview(pattern, for: item("bank/2024/doc.pdf"), under: root)
        XCTAssertEqual(result.renderedName, "bank.pdf")
    }

    func testPreviewsCoversASampleOfDocuments() {
        let pattern = NamePattern(elements: [.token(NameToken(.title))])
        let items = [item("a.pdf"), item("b.pdf")]
        let guesses = [items[0].key: BookGuess(title: "Alpha", author: nil, year: nil),
                       items[1].key: BookGuess(title: "Beta", author: nil, year: nil)]
        let results = previews(pattern, for: items, guesses: guesses)
        XCTAssertEqual(results.map(\.renderedName), ["Alpha.pdf", "Beta.pdf"])
    }
}
