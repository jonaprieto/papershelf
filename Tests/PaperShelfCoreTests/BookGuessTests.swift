import XCTest
@testable import PaperShelfCore

final class BookGuessTests: XCTestCase {

    func testParsesAPlainObject() {
        let guess = parseBookGuess(#"{"title": "Gödel, Escher, Bach", "author": "Hofstadter", "year": "1979"}"#)
        XCTAssertEqual(guess, BookGuess(title: "Gödel, Escher, Bach", author: "Hofstadter", year: "1979"))
    }

    func testToleratesFencesAndSurroundingProse() {
        let reply = """
        Sure, here is the result:
        ```json
        {"title": "Dune", "author": "Herbert", "year": 1965}
        ```
        Let me know if you need anything else.
        """
        XCTAssertEqual(parseBookGuess(reply), BookGuess(title: "Dune", author: "Herbert", year: "1965"))
    }

    func testMissingFieldsStayMissing() {
        // Both real nulls and the string "null", which models emit often enough to matter.
        XCTAssertEqual(parseBookGuess(#"{"title": "Untitled", "author": null, "year": "null"}"#),
                       BookGuess(title: "Untitled", author: nil, year: nil))
        XCTAssertEqual(parseBookGuess(#"{"title": "Solo", "author": "  "}"#),
                       BookGuess(title: "Solo", author: nil, year: nil))
    }

    func testUnusableRepliesAreRejected() {
        XCTAssertNil(parseBookGuess("I could not identify this document."))
        XCTAssertNil(parseBookGuess("{}"))
        XCTAssertNil(parseBookGuess(#"{"author": "Herbert"}"#), "a guess without a title is useless")
        XCTAssertNil(parseBookGuess("{not json at all}"))
    }

    func testFilenameLeadsWithTheYear() {
        let guess = BookGuess(title: "Gödel, Escher, Bach", author: "Hofstadter", year: "1979")
        XCTAssertEqual(
            filename(for: guess, rules: NameRules(separator: .dash, stripSymbols: true)),
            "1979-gödel-escher-bach-hofstadter.pdf")
        XCTAssertEqual(
            filename(for: guess, rules: NameRules(separator: .dash, stripSymbols: true, stripDiacritics: true)),
            "1979-godel-escher-bach-hofstadter.pdf")
    }

    /// The year of publication must win over a number that happens to be the title.
    func testATitleThatIsANumberDoesNotBecomeTheDate() {
        let rules = NameRules(separator: .dash, stripSymbols: true)
        XCTAssertEqual(filename(for: BookGuess(title: "1984", author: "Orwell", year: "1949"), rules: rules),
                       "1949-1984-orwell.pdf")
    }

    func testPartialGuessesStillProduceAName() {
        let rules = NameRules(separator: .dash, stripSymbols: true)
        XCTAssertEqual(filename(for: BookGuess(title: "Refactoring"), rules: rules), "refactoring.pdf")
        XCTAssertEqual(filename(for: BookGuess(title: "Dune", year: "1965"), rules: rules), "1965-dune.pdf")
        XCTAssertEqual(filename(for: BookGuess(title: "  "), rules: rules), "")
    }

    func testPromptCarriesTheFilenameAndIsClipped() {
        let prompt = bookGuessPrompt(filename: "scan001.pdf", excerpt: String(repeating: "a", count: 5000), limit: 100)
        XCTAssertTrue(prompt.contains("scan001.pdf"))
        XCTAssertLessThan(prompt.count, 300)
    }

    func testPromptSaysSoWhenThereIsNoTextLayer() {
        let prompt = bookGuessPrompt(filename: "scan.pdf", excerpt: "   \n \n ")
        XCTAssertTrue(prompt.contains("no text layer"))
    }

    /// The rules are not advisory. A name that came from the model goes through them
    /// exactly like one read off the filesystem, and follows them when they change.
    func testAGuessedNameObeysTheRules() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(scratchName("guess"))
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("scan001.pdf")
        fm.createFile(atPath: file.path, contents: Data())

        let item = Item(root: root, source: file, destination: file, status: .renamed)
        let guess = BookGuess(title: "Gödel, Escher, Bach", author: "Hofstadter", year: "1979")

        // Folder borrowing off, so this measures the rules and nothing else: scan001 is
        // a generic stem and would otherwise pick up the temp folder's name.
        var options = Options(passwords: [], recursive: true, dryRun: true, useFolderNames: false)
        options.rules = NameRules(separator: .dash, stripSymbols: true)
        XCTAssertEqual(restyled(item, options: options, guess: guess).destinationName,
                       "1979-gödel-escher-bach-hofstadter.pdf")

        options.rules = NameRules(casing: .uppercase, separator: .underscore,
                                  stripSymbols: true, stripDiacritics: true)
        XCTAssertEqual(restyled(item, options: options, guess: guess).destinationName,
                       "1979_GODEL_ESCHER_BACH_HOFSTADTER.pdf")

        // With no guess it falls back to the filename, as before.
        XCTAssertEqual(restyled(item, options: options, guess: nil).destinationName,
                       "SCAN001.pdf")
    }
}


final class ModelFilterTests: XCTestCase {

    /// The filter drops what plainly cannot answer a chat request and keeps the rest,
    /// including names from endpoints that are not OpenAI's.
    func testChatModelsSurviveAndOthersDoNot() {
        let kept = ["gpt-4o-mini", "gpt-4.1", "o3-mini", "claude-3-5-sonnet",
                    "llama-3.3-70b", "mistral-large", "deepseek-chat", "qwen2.5-72b"]
        let dropped = ["text-embedding-3-small", "whisper-1", "tts-1-hd", "dall-e-3",
                       "omni-moderation-latest", "gpt-4o-realtime-preview",
                       "gpt-4o-audio-preview", "gpt-4o-transcribe", "davinci-002"]

        for id in kept { XCTAssertTrue(looksLikeChatModel(id), "\(id) should be offered") }
        for id in dropped { XCTAssertFalse(looksLikeChatModel(id), "\(id) should be hidden") }
    }
}
