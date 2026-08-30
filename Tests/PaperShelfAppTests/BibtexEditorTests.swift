import XCTest
import AppKit
@testable import PaperShelf
@testable import PaperShelfCore

/// The colouring the entry editor does as you type.
///
/// It walks the tokens and paints ranges by their UTF-16 lengths, so it is only correct
/// while the tokens still add up to the text they came from. Core holds that they rebuild
/// their input; this holds the arithmetic the editor does on top of it.
final class BibtexEditorTests: XCTestCase {

    private let entry = """
    @article{2017:verifying,
      title = {Verifying Strong Eventual Consistency in Distributed Systems},
      author = {Gomes, Victor B. F. and Kleppmann, Martin},
      year = {2017},
      doi = {10.1145/3133933}
    }
    """

    func testTokenLengthsCoverTheTextExactly() {
        let total = bibtexTokens(entry).reduce(0) { $0 + ($1.text as NSString).length }
        XCTAssertEqual(total, (entry as NSString).length)
    }

    /// An entry with an accent or an emoji in a title is where a character count and a
    /// UTF-16 length part company, and the ranges are UTF-16.
    func testItHoldsForTextOutsideASCII() {
        let awkward = "@book{k, title = {Über Ästhetik 🙂}, year = {1904} }"
        let total = bibtexTokens(awkward).reduce(0) { $0 + ($1.text as NSString).length }
        XCTAssertEqual(total, (awkward as NSString).length)
    }

    func testEveryKindOfTokenHasAnAnswer() {
        // `.plain` is the one that deliberately has no colour of its own.
        XCTAssertNil(BibtexEditor.colour(for: .plain))
        for kind: BibTokenKind in [.entryType, .key, .field, .value, .punctuation] {
            XCTAssertNotNil(BibtexEditor.colour(for: kind), "\(kind) has no colour")
        }
    }

    /// What the editor paints and what Copy puts on the pasteboard are the same string.
    func testColouringChangesNoCharacter() {
        let rebuilt = bibtexTokens(entry).map(\.text).joined()
        XCTAssertEqual(rebuilt, entry)
    }
}
