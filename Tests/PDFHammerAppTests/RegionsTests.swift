import XCTest
@testable import PDFHammer

/// Moving between the five regions, and the one meaning ⎋ has. Both are pure functions
/// precisely so the promise -- anything you can click you can reach -- can be checked
/// without a window: a cycle key that lands on a pane which is not drawn looks, from the
/// keyboard, exactly like a key that does nothing.
@MainActor
final class RegionsTests: XCTestCase {

    private let all: Set<Region> = Set(Region.allCases)

    func testCyclingVisitsEveryRegionInOrderAndWraps() {
        var seen: [Region] = []
        var current = Region.sidebar
        for _ in Region.allCases {
            seen.append(current)
            current = Regions.next(from: current, by: 1, available: all)
        }
        XCTAssertEqual(seen, Region.allCases)
        XCTAssertEqual(current, .sidebar, "the cycle wraps")
    }

    func testCyclingBackwardsWraps() {
        XCTAssertEqual(Regions.next(from: .sidebar, by: -1, available: all), .status)
        XCTAssertEqual(Regions.next(from: .status, by: -1, available: all), .inspector)
    }

    func testACollapsedRegionIsSkipped() {
        let drawn: Set<Region> = [.sidebar, .document, .status]
        XCTAssertEqual(Regions.next(from: .sidebar, by: 1, available: drawn), .document)
        XCTAssertEqual(Regions.next(from: .document, by: 1, available: drawn), .status)
        XCTAssertEqual(Regions.next(from: .status, by: 1, available: drawn), .sidebar)
    }

    func testTheOnlyDrawnRegionIsWhereYouStay() {
        XCTAssertEqual(Regions.next(from: .document, by: 1, available: [.document]), .document)
        XCTAssertEqual(Regions.next(from: .document, by: -1, available: [.document]), .document)
    }

    func testNothingDrawnLeavesFocusWhereItIs() {
        XCTAssertEqual(Regions.next(from: .inspector, by: 1, available: []), .inspector)
    }

    // MARK: The ladder

    func testEscapeLeavesTheInnermostThingFirst() {
        XCTAssertEqual(Regions.escape(editingField: true, rowFocused: true, filtering: true,
                                      insidePlace: true), .leaveField)
        XCTAssertEqual(Regions.escape(editingField: false, rowFocused: true, filtering: true,
                                      insidePlace: true), .leaveRow)
        XCTAssertEqual(Regions.escape(editingField: false, rowFocused: false, filtering: true,
                                      insidePlace: true), .clearFilters)
        XCTAssertEqual(Regions.escape(editingField: false, rowFocused: false, filtering: false,
                                      insidePlace: true), .leavePlace)
        XCTAssertEqual(Regions.escape(editingField: false, rowFocused: false, filtering: false,
                                      insidePlace: false), .nothing)
    }

    func testEachPressGoesExactlyOneRungDown() {
        // Typing in a field inside a filtered shelf inside the reader: four presses, four
        // different things, in that order and no other.
        var editing = true, row = true, filtering = true, place = true
        var rungs: [EscapeRung] = []
        for _ in 0..<5 {
            let rung = Regions.escape(editingField: editing, rowFocused: row,
                                      filtering: filtering, insidePlace: place)
            rungs.append(rung)
            switch rung {
            case .leaveField: editing = false
            case .leaveRow: row = false
            case .clearFilters: filtering = false
            case .leavePlace: place = false
            case .nothing: break
            }
        }
        XCTAssertEqual(rungs, [.leaveField, .leaveRow, .clearFilters, .leavePlace, .nothing])
    }
}
