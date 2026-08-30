import XCTest
@testable import PaperShelf
@testable import PaperShelfCore

/// Picking more than one file. The rules are the ones every file window has: a plain
/// click means one, command-click adds or removes, shift-click takes a run.
final class SelectionTests: XCTestCase {
    private let order = ["a", "b", "c", "d", "e"]

    func testShiftTakesTheRunBetweenTheAnchorAndTheClick() {
        XCTAssertEqual(selectionRange(from: "b", to: "d", in: order), ["b", "c", "d"])
        XCTAssertEqual(selectionRange(from: "d", to: "b", in: order), ["b", "c", "d"],
                       "upwards is the same run")
        XCTAssertEqual(selectionRange(from: "c", to: "c", in: order), ["c"])
    }

    /// A file that is not on screen any more cannot anchor a run. Falling back to the one
    /// clicked is what a person expects; selecting everything is not.
    func testAMissingAnchorSelectsOnlyWhatWasClicked() {
        XCTAssertEqual(selectionRange(from: "gone", to: "d", in: order), ["d"])
        XCTAssertEqual(selectionRange(from: "b", to: "gone", in: order), ["gone"])
    }

    /// Where a decision leaves you: the next file still waiting *below* the one decided,
    /// in the order on screen. Walking the results instead is how confirming one file
    /// landed on another from a different folder entirely.
    func testADecisionMovesToTheNextWaitingFileBelowIt() {
        let waiting: Set<String> = ["a", "d", "e"]
        XCTAssertEqual(nextWaiting(after: "b", in: order, waiting: { waiting.contains($0) }), "d")
        XCTAssertEqual(nextWaiting(after: "d", in: order, waiting: { waiting.contains($0) }), "e")
    }

    /// Past the last one it wraps, so the files above the anchor are not stranded.
    func testItWrapsOnceAndStopsWhenNothingIsWaiting() {
        XCTAssertEqual(nextWaiting(after: "e", in: order, waiting: { $0 == "a" }), "a")
        XCTAssertNil(nextWaiting(after: "b", in: order, waiting: { _ in false }))
        XCTAssertNil(nextWaiting(after: "b", in: [], waiting: { _ in true }))
    }

    /// An anchor no longer on screen starts at the top rather than jumping somewhere
    /// arbitrary.
    func testAMissingAnchorStartsAtTheTop() {
        XCTAssertEqual(nextWaiting(after: "gone", in: order, waiting: { $0 != "a" }), "b")
        XCTAssertEqual(nextWaiting(after: nil, in: order, waiting: { _ in true }), "a")
    }
}
