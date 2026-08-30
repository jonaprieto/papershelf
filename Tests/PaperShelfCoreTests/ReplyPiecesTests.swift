import XCTest
@testable import PaperShelfCore

/// Turning "(Title, p. 17)" written into the prose into a numbered mark that points at a
/// list underneath. Nothing an answer said may be dropped on the way to the screen.
final class ReplyPiecesTests: XCTestCase {

    private func citation(_ title: String, _ page: Int, in reply: String,
                          _ written: String) -> Citation {
        let range = reply.range(of: written)!
        return Citation(documentTitle: title, page: page, contentHash: "h", range: range)
    }

    private func rendered(_ pieces: [ReplyPiece]) -> String {
        pieces.map {
            switch $0 {
            case .text(let text): return text
            case .mark(let number): return "[\(number)]"
            }
        }.joined()
    }

    func testACitationBecomesANumberedMark() {
        let reply = "Pearl treats it as harmful (Causality, p. 17) and Morgan does not."
        let pieces = replyPieces(reply, citations: [
            citation("Causality", 17, in: reply, "(Causality, p. 17)")
        ])
        XCTAssertEqual(rendered(pieces),
                       "Pearl treats it as harmful [1] and Morgan does not.")
    }

    /// Numbered in the order they are first read, not in the order the model listed them.
    func testNumbersFollowTheOrderInTheText() {
        let reply = "First (B, p. 2) then (A, p. 1) then (B, p. 2) again."
        let citations = [
            citation("A", 1, in: reply, "(A, p. 1)"),
            citation("B", 2, in: reply, "(B, p. 2)"),
        ]
        XCTAssertEqual(numberedCitations(citations).map(\.number), [1, 2])
        XCTAssertEqual(numberedCitations(citations).map(\.citation.documentTitle), ["B", "A"])
    }

    /// One page cited twice is one source with one number, not two entries saying the
    /// same thing.
    func testTheSamePageIsOneSource() {
        let reply = "Here (A, p. 1) and again (A, p. 1)."
        let first = citation("A", 1, in: reply, "(A, p. 1)")
        let second = Citation(documentTitle: "A", page: 1, contentHash: "h",
                              range: reply.range(of: "(A, p. 1).")!.lowerBound
                                     ..< reply.range(of: "(A, p. 1).")!.upperBound)
        XCTAssertEqual(numberedCitations([first, second]).count, 1)
    }

    func testAnAnswerWithNoCitationsIsOnePieceOfText() {
        XCTAssertEqual(replyPieces("Nothing to cite.", citations: []),
                       [.text("Nothing to cite.")])
        XCTAssertEqual(replyPieces("", citations: []), [])
    }

    /// The text either side of every mark is kept exactly, so an answer cannot lose a
    /// sentence to its own citations.
    func testEveryCharacterOutsideACitationSurvives() {
        let reply = "Opening (A, p. 1) middle (B, p. 9) closing."
        let pieces = replyPieces(reply, citations: [
            citation("A", 1, in: reply, "(A, p. 1)"),
            citation("B", 9, in: reply, "(B, p. 9)"),
        ])
        XCTAssertEqual(rendered(pieces), "Opening [1] middle [2] closing.")
        let kept = pieces.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
        XCTAssertEqual(kept.joined(), "Opening  middle  closing.")
    }

    /// A citation whose span the reply does not actually contain is left alone rather
    /// than used to slice the text at an index from some other string.
    func testASpanFromAnotherStringIsIgnored() {
        let other = "a different reply entirely, longer than the one shown"
        let stray = Citation(documentTitle: "A", page: 1, contentHash: "h",
                             range: other.range(of: "longer")!)
        XCTAssertEqual(replyPieces("short", citations: [stray]), [.text("short")])
    }
}
