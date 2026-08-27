import XCTest
@testable import PDFHammerCore

/// Pins down the split-view arithmetic against the two overflow bugs it exists to
/// prevent: the notes rail squeezing the browser (fixed once already), and the contents
/// rail squeezing the PDF preview inside the inspector (not fixed until this round).
final class LayoutTests: XCTestCase {

    // MARK: inspectorMaximum keeps the browser's floor

    func testBrowserKeepsItsFloorWithNeitherRailOpen() {
        let available: CGFloat = 721
        let maximum = SplitLayout.inspectorMaximum(
            available: available, notesShown: false, contentsShown: false)
        let browserWidth = available - SplitLayout.dividerBeforeInspector - maximum
        XCTAssertGreaterThanOrEqual(browserWidth, SplitLayout.contentFloor)
    }

    func testBrowserKeepsItsFloorWithNotesRailOpen() {
        // The window's own stated minimum with the rail open: exactly the room the
        // layout needs and not a point more, so this is the tightest real case.
        let available: CGFloat = 962
        let maximum = SplitLayout.inspectorMaximum(
            available: available, notesShown: true, contentsShown: false)
        let browserWidth = available - SplitLayout.dividerBeforeInspector - maximum
            - SplitLayout.notesReserved
        XCTAssertGreaterThanOrEqual(browserWidth, SplitLayout.contentFloor)
    }

    /// Reproduces the exact regression this round's task described: at the app's stated
    /// minimum width with the rail open, the pre-fix formula (`max(360, available - 360)`,
    /// ignoring the rail entirely) squeezes the browser under its floor. This fails
    /// against that formula and passes against `SplitLayout`.
    func testUnpatchedFormulaWouldHaveSqueezedTheBrowser() {
        let available: CGFloat = 962
        let buggyMaximum = max(SplitLayout.contentFloor, available - SplitLayout.contentFloor)
        let browserWidthUnderBuggyFormula = available - SplitLayout.dividerBeforeInspector
            - buggyMaximum - SplitLayout.notesReserved
        XCTAssertLessThan(browserWidthUnderBuggyFormula, SplitLayout.contentFloor,
            "this formula is the one being fixed; if it stops squeezing the browser, the reproduction is stale")

        let fixedMaximum = SplitLayout.inspectorMaximum(
            available: available, notesShown: true, contentsShown: false)
        let browserWidthFixed = available - SplitLayout.dividerBeforeInspector
            - fixedMaximum - SplitLayout.notesReserved
        XCTAssertGreaterThanOrEqual(browserWidthFixed, SplitLayout.contentFloor)
    }

    // MARK: inspectorMinimum keeps the PDF preview's floor

    /// The bug the layout audit flagged and this round's fix did not touch: the contents
    /// rail is nested inside the inspector, so unless the inspector's own floor grows to
    /// cover it, the preview next to it is squeezed with nothing stopping it.
    func testPreviewKeepsItsFloorWhenContentsRailIsOpen() {
        let inspectorWidth = SplitLayout.inspectorMinimum(contentsShown: true)
        let previewWidth = inspectorWidth - SplitLayout.contentsReserved
        XCTAssertGreaterThanOrEqual(previewWidth, SplitLayout.contentFloor)
    }

    func testInspectorFloorIsUnchangedWhenContentsRailIsClosed() {
        XCTAssertEqual(SplitLayout.inspectorMinimum(contentsShown: false), SplitLayout.contentFloor)
    }

    // MARK: minWidth matches what the panes actually add up to

    func testMinWidthMatchesTheEstablishedConstantsWithNeitherRailOpen() {
        XCTAssertEqual(SplitLayout.minWidth(notesShown: false), 721)
    }

    func testMinWidthMatchesTheEstablishedConstantsWithNotesRailOpen() {
        XCTAssertEqual(SplitLayout.minWidth(notesShown: true), 962)
    }

    // MARK: The window's floor does not move when the contents rail opens

    /// Opening a table of contents used to raise the window's own minimum by nearly 200
    /// points. A window that could grow jumped; a window that could not, one tiled or on a
    /// small display, was asked for room it did not have and drew the inspector past its
    /// own edge. The rail comes out of the inspector's existing share now.
    func testOpeningTheContentsRailDoesNotMoveTheWindowsFloor() {
        XCTAssertEqual(SplitLayout.minWidth(notesShown: false), 721)
        XCTAssertEqual(SplitLayout.minWidth(notesShown: true), 962)
    }

    // MARK: inspectorWidth never asks for room that is not there

    func testInspectorNeverExceedsTheRoomThereIs() {
        for available in stride(from: 300.0, through: 1600.0, by: 37.0) {
            for notes in [false, true] {
                for contents in [false, true] {
                    let width = SplitLayout.inspectorWidth(
                        preferred: 460, available: available,
                        notesShown: notes, contentsShown: contents)
                    let used = width + SplitLayout.dividerBeforeInspector
                        + (notes ? SplitLayout.notesReserved : 0)
                    XCTAssertLessThanOrEqual(used, available,
                        "available=\(available) notes=\(notes) contents=\(contents)")
                    XCTAssertGreaterThanOrEqual(width, 0)
                }
            }
        }
    }

    /// The exact case that rendered badly: a window at the floor it is allowed to have,
    /// with the contents rail open. The old clamp returned the inspector's floor of 557,
    /// which with the divider is more than the 721 window minus the browser's own 360.
    func testAWindowAtItsFloorWithTheContentsRailOpenStillFits() {
        let available = SplitLayout.minWidth(notesShown: false)
        let old = max(SplitLayout.inspectorMinimum(contentsShown: true), 0)
        XCTAssertGreaterThan(old + SplitLayout.dividerBeforeInspector + SplitLayout.contentFloor,
                             available, "if this stops overflowing, the reproduction is stale")

        let width = SplitLayout.inspectorWidth(
            preferred: 460, available: available, notesShown: false, contentsShown: true)
        XCTAssertLessThanOrEqual(width + SplitLayout.dividerBeforeInspector, available)
    }

    /// A wide window is unaffected: the inspector keeps the width it was dragged to.
    func testADraggedWidthSurvivesOnAWindowWithRoom() {
        XCTAssertEqual(SplitLayout.inspectorWidth(
            preferred: 620, available: 1600, notesShown: false, contentsShown: false), 620)
    }

    // MARK: The rail narrows before the page does

    func testTheContentsRailKeepsItsIdealWidthWhenThereIsRoom() {
        XCTAssertEqual(SplitLayout.contentsRailWidth(inspectorWidth: 600),
                       SplitLayout.contentsReserved - SplitLayout.dividerBeforeInspector)
    }

    func testTheContentsRailNarrowsRatherThanSqueezingThePageAway() {
        let width = SplitLayout.contentsRailWidth(inspectorWidth: 300)
        XCTAssertEqual(width, 300 - SplitLayout.previewFloorBesideContents)
        XCTAssertGreaterThan(width, 0, "a rail with no width is not a table of contents")
    }

    func testTheContentsRailDisappearsRatherThanGoingNegative() {
        XCTAssertEqual(SplitLayout.contentsRailWidth(inspectorWidth: 80), 0)
    }

    /// At the window's own stated minimum, `inspectorMaximum` must never be asked to
    /// satisfy less room than `minWidth` assumed -- otherwise the window's floor and the
    /// split's clamp disagree, and the pane overflows anyway even though the window
    /// "can't" be resized narrower than the layout requires.
    func testMaximumNeverFallsBelowMinimumAtTheWindowsOwnFloor() {
        for notes in [false, true] {
            for contents in [false, true] {
                let available = SplitLayout.minWidth(notesShown: notes)
                let maximum = SplitLayout.inspectorMaximum(
                    available: available, notesShown: notes, contentsShown: contents)
                let minimum = SplitLayout.inspectorMinimum(contentsShown: contents)
                XCTAssertGreaterThanOrEqual(maximum, minimum,
                    "notesShown=\(notes) contentsShown=\(contents)")
            }
        }
    }
}
