import XCTest
@testable import PaperShelfCore
@testable import PaperShelf

/// The duplicates view asks for its groups three times in one body pass: the list, the bar
/// above it and the status line. Each call walks every group and every file in it.
@MainActor
final class DuplicatesFilterTests: XCTestCase {

    private func signature(results: Int = 1) -> VisibleFilter.Signature {
        VisibleFilter.Signature(results: results, matching: 0, tags: 0, query: "",
                                scope: nil, undecidedOnly: false, decisions: 0,
                                list: .all, lists: 0)
    }

    func testTheSameQuestionIsAnsweredOnce() {
        let filter = DuplicatesFilter()
        var walks = 0
        for _ in 0..<3 {
            _ = filter.groups(matching: signature(), token: 0) {
                walks += 1
                return []
            }
        }
        XCTAssertEqual(walks, 1, "one body pass walked the groups three times")
    }

    /// The signature says what may be shown; the token says which groups there are. A
    /// check finishing never touches `results`, so keyed on the signature alone this would
    /// go on answering with the groups from before it ran, which the first time is none.
    func testACheckFinishingReachesTheView() {
        let filter = DuplicatesFilter()
        var walks = 0
        let none = filter.groups(matching: signature(), token: 0) {
            walks += 1
            return []
        }
        let found = filter.groups(matching: signature(), token: 1) {
            walks += 1
            return [DuplicateGroup(id: "a", kind: .identical, items: [])]
        }
        XCTAssertEqual(walks, 2, "the duplicate check's own result never reached the view")
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(found.count, 1)
    }

    /// And a search still narrows them.
    func testANewSearchStillReachesIt() {
        let filter = DuplicatesFilter()
        var walks = 0
        for results in [1, 1, 2] {
            _ = filter.groups(matching: signature(results: results), token: 1) {
                walks += 1
                return []
            }
        }
        XCTAssertEqual(walks, 2)
    }
}
