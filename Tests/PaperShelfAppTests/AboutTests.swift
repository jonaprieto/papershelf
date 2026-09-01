import XCTest
@testable import PaperShelf
@testable import PaperShelfCore

/// The licence the app shows and the licence shipped beside the source have to be the
/// same words. A LICENSE file nobody reads and an about window that has drifted from it
/// is a licence nobody can rely on, and the drift is silent.
final class AboutTests: XCTestCase {

    /// The repository root, found from this file rather than from the working directory,
    /// which is wherever the test runner happens to have started.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)          // .../Tests/PaperShelfAppTests/AboutTests.swift
            .deletingLastPathComponent()          // .../Tests/PaperShelfAppTests
            .deletingLastPathComponent()          // .../Tests
            .deletingLastPathComponent()          // repository root
    }

    func testTheShownLicenceIsTheShippedOne() throws {
        let file = repositoryRoot.appendingPathComponent("LICENSE")
        let shipped = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(AboutWindow.licence.trimmingCharacters(in: .whitespacesAndNewlines),
                       shipped.trimmingCharacters(in: .whitespacesAndNewlines),
                       "the about window and the LICENSE file have drifted apart")
    }

    /// Whoever holds the copyright has to be named in the licence itself, not only in the
    /// bundle: a copyright line in an Info.plist is not a grant of anything.
    func testTheLicenceNamesItsHolder() {
        XCTAssertTrue(AboutWindow.licence.contains("MIT License"))
        XCTAssertTrue(AboutWindow.licence.contains("Jonathan Prieto-Cubides"))
    }

    /// The acknowledgements name every converter the app can actually call. A tool added
    /// to `markdownConverters` and left out of the notice is an unacknowledged dependency.
    func testEveryConverterTheAppCanCallIsOneItNames() {
        XCTAssertEqual(markdownConverters.map(\MarkdownConverter.name).sorted(),
                       ["Docling", "Marker", "MarkItDown", "pdftotext"].sorted(),
                       "a converter was added or removed; the About window lists them "
                       + "from this same array, so only this expectation needs updating")
    }

    // MARK: - Changelog

    /// The test bundle is never a `.app` build.sh has copied `CHANGELOG.md` into, so this
    /// exercises the same path a `swift run` build or a pre-1.7.0 `.app` takes: a plain
    /// message rather than an empty page.
    func testTheChangelogFallsBackGracefullyWhenNotBundled() {
        XCTAssertEqual(AboutWindow.changelog, "The changelog is not available in this build.")
    }

    /// The changelog file itself has to keep naming the version it is shipped inside, or
    /// a bump to `paperShelfVersion` silently leaves the About window's fourth page
    /// describing an older release than the one someone is actually running.
    func testTheChangelogFileNamesTheCurrentVersion() throws {
        let file = repositoryRoot.appendingPathComponent("CHANGELOG.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains(paperShelfVersion),
                       "CHANGELOG.md has no entry for \(paperShelfVersion)")
    }
}
