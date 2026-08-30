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
}
