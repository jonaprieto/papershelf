import XCTest
@testable import PaperShelf

/// What gets handed to ChatGPT, and how it is encoded.
///
/// The encoding is the part worth testing: a passage is arbitrary text, and an ampersand
/// or a plus sign in a quotation would otherwise be read as query syntax by whatever
/// parses the URL, silently truncating what the person meant to ask about.
final class ChatGPTHandoffTests: XCTestCase {

    func testThePromptNamesTheDocumentAndQuotesThePassage() {
        let prompt = ChatGPTHandoff.prompt(
            quoted: "eventual consistency guarantees convergence",
            note: "compare with SEC", page: 3, title: "Verifying Strong Eventual Consistency")
        XCTAssertTrue(prompt.contains("Verifying Strong Eventual Consistency"))
        XCTAssertTrue(prompt.contains("page 3"))
        XCTAssertTrue(prompt.contains("> eventual consistency guarantees convergence"))
        XCTAssertTrue(prompt.contains("My note: compare with SEC"))
    }

    func testAPassageWithNoNoteDoesNotClaimOne() {
        let prompt = ChatGPTHandoff.prompt(quoted: "a passage", note: "", page: 1, title: "A Book")
        XCTAssertFalse(prompt.contains("My note"))
    }

    func testEveryLineOfAMultiLinePassageIsQuoted() {
        let prompt = ChatGPTHandoff.prompt(quoted: "first line\nsecond line", note: "",
                                           page: nil, title: "A Book")
        XCTAssertTrue(prompt.contains("> first line"))
        XCTAssertTrue(prompt.contains("> second line"))
        XCTAssertFalse(prompt.contains("page"), "no page number, so none is invented")
    }

    /// The characters that would otherwise end the prompt early.
    func testQuerySyntaxInAPassageSurvivesEncoding() throws {
        let awkward = "Kingsbury & Terry: a+b = c? #1 100% sure"
        let prompt = ChatGPTHandoff.prompt(quoted: awkward, note: "", page: nil, title: "T")

        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#")
        let encoded = try XCTUnwrap(prompt.addingPercentEncoding(withAllowedCharacters: allowed))
        let url = try XCTUnwrap(URL(string: "codex://threads/new?prompt=\(encoded)"))

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let value = try XCTUnwrap(components.queryItems?.first { $0.name == "prompt" }?.value)
        XCTAssertTrue(value.contains(awkward),
                      "the passage must come back out of the URL exactly as it went in")
    }
}
