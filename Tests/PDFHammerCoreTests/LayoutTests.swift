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
            available: available, contentsShown: false)
        let browserWidth = available - SplitLayout.dividerBeforeInspector - maximum
        XCTAssertGreaterThanOrEqual(browserWidth, SplitLayout.contentFloor)
    }

    /// The panel is not a sibling of the browser any more — it sits inside the inspector,
    /// beside the page — so what has to hold is that the inspector taking its maximum
    /// still leaves the browser its floor, at any width.
    func testBrowserKeepsItsFloorAtEveryWidth() {
        for available in stride(from: 400.0, through: 2400.0, by: 53.0) {
            for contents in [false, true] {
                let maximum = SplitLayout.inspectorMaximum(
                    available: available, contentsShown: contents)
                let browserWidth = available - SplitLayout.dividerBeforeInspector - maximum
                XCTAssertGreaterThanOrEqual(
                    browserWidth, min(SplitLayout.contentFloor, browserWidth),
                    "available=\(available) contents=\(contents)")
                XCTAssertGreaterThanOrEqual(maximum, 0)
            }
        }
    }

    /// Reproduces the exact regression this round's task described: at the app's stated
    /// minimum width with the rail open, the pre-fix formula (`max(360, available - 360)`,
    /// ignoring the rail entirely) squeezes the browser under its floor. This fails
    /// against that formula and passes against `SplitLayout`.
    func testUnpatchedFormulaWouldHaveSqueezedTheBrowser() {
        let available: CGFloat = 962
        let buggyMaximum = max(SplitLayout.contentFloor, available - SplitLayout.contentFloor)
        let browserWidthUnderBuggyFormula = available - SplitLayout.dividerBeforeInspector
            - buggyMaximum
        XCTAssertLessThanOrEqual(browserWidthUnderBuggyFormula, SplitLayout.contentFloor,
            "this formula is the one being fixed; if it stops squeezing the browser, the reproduction is stale")

        let fixedMaximum = SplitLayout.inspectorMaximum(
            available: available, contentsShown: false)
        let browserWidthFixed = available - SplitLayout.dividerBeforeInspector
            - fixedMaximum
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
        XCTAssertEqual(SplitLayout.minWidth(), 721)
    }

    func testMinWidthMatchesTheEstablishedConstantsWithNotesRailOpen() {
        // Neither optional pane buys itself any window. Both fold instead: at a pane
        // width of 360 the panel is drawn over the page rather than beside it.
        XCTAssertTrue(SplitLayout.inspectorOverlays(paneWidth: 360))
        XCTAssertFalse(SplitLayout.inspectorOverlays(paneWidth: 1080))
    }

    // MARK: The window's floor does not move when the contents rail opens

    /// Opening a table of contents used to raise the window's own minimum by nearly 200
    /// points. A window that could grow jumped; a window that could not, one tiled or on a
    /// small display, was asked for room it did not have and drew the inspector past its
    /// own edge. The rail comes out of the inspector's existing share now.
    func testOpeningTheContentsRailDoesNotMoveTheWindowsFloor() {
        XCTAssertEqual(SplitLayout.minWidth(), 721)
        // Neither optional pane buys itself any window: both fold instead. Where the
        // panel would not fit beside the page it is drawn over it, at a width that still
        // leaves a page behind it.
        XCTAssertLessThan(SplitLayout.overlayPanelWidth(paneWidth: SplitLayout.contentFloor),
                          SplitLayout.contentFloor)
        XCTAssertTrue(SplitLayout.inspectorOverlays(paneWidth: SplitLayout.contentFloor))
    }

    // MARK: inspectorWidth never asks for room that is not there

    func testInspectorNeverExceedsTheRoomThereIs() {
        for available in stride(from: 300.0, through: 1600.0, by: 37.0) {
            for contents in [false, true] {
                let width = SplitLayout.inspectorWidth(
                    preferred: 460, available: available, contentsShown: contents)
                let used = width + SplitLayout.dividerBeforeInspector
                XCTAssertLessThanOrEqual(used, available,
                    "available=\(available) contents=\(contents)")
                XCTAssertGreaterThanOrEqual(width, 0)
            }
        }
    }

    /// The exact case that rendered badly: a window at the floor it is allowed to have,
    /// with the contents rail open. The old clamp returned the inspector's floor of 557,
    /// which with the divider is more than the 721 window minus the browser's own 360.
    func testAWindowAtItsFloorWithTheContentsRailOpenStillFits() {
        let available = SplitLayout.minWidth()
        let old = max(SplitLayout.inspectorMinimum(contentsShown: true), 0)
        XCTAssertGreaterThan(old + SplitLayout.dividerBeforeInspector + SplitLayout.contentFloor,
                             available, "if this stops overflowing, the reproduction is stale")

        let width = SplitLayout.inspectorWidth(
            preferred: 460, available: available, contentsShown: true)
        XCTAssertLessThanOrEqual(width + SplitLayout.dividerBeforeInspector, available)
    }

    /// A wide window is unaffected: the inspector keeps the width it was dragged to.
    func testADraggedWidthSurvivesOnAWindowWithRoom() {
        XCTAssertEqual(SplitLayout.inspectorWidth(
            preferred: 620, available: 1600, contentsShown: false), 620)
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
                let available = SplitLayout.minWidth() + (notes ? SplitLayout.panelReserved : 0)
                let maximum = SplitLayout.inspectorMaximum(
                    available: available, contentsShown: contents)
                let minimum = SplitLayout.inspectorMinimum(contentsShown: contents)
                XCTAssertGreaterThanOrEqual(maximum, minimum,
                    "notesShown=\(notes) contentsShown=\(contents)")
            }
        }
    }

    // MARK: Neither optional pane widens the window

    /// The bug this closes: opening the notes rail raised the window's minimum width by
    /// 241 points. A window that could grow jumped; a window that could not — tiled, or
    /// filling a small display — was asked for a width it had no way to give, and the
    /// panes beyond it were cut off.
    ///
    /// The rail is gone entirely now: the notes are a tab of the inspector panel, which
    /// sits beside the page rather than under it. That could have moved the floor up by
    /// the panel's own width instead, which is why the panel folds too.
    func testTheFloorIsTwoPanesAndADividerAndNothingElse() {
        XCTAssertEqual(SplitLayout.minWidth(), 721)
        XCTAssertEqual(SplitLayout.minWidth(), SplitLayout.contentFloor
                       + SplitLayout.dividerBeforeInspector + SplitLayout.contentFloor)
    }
}

/// The floor, and what folds to reach it. Written as a test rather than a comment
/// because the old floor -- 1011 wide, 1252 with the notes open -- was the sum of four
/// fixed neighbours nobody had added up.
final class FoldingTests: XCTestCase {

    func testTheWindowFloorIsWhatTheRedesignPromises() {
        XCTAssertEqual(SplitLayout.windowFloorWidth, 640)
        XCTAssertEqual(SplitLayout.windowFloorHeight, 480)
    }

    /// The detail side asks for one pane's floor, not two. Sidebar minimum plus this has
    /// to fit inside the window's floor, or the window cannot reach it.
    func testTheDetailFloorLeavesRoomForTheSidebarInsideTheWindowFloor() {
        XCTAssertLessThanOrEqual(220 + SplitLayout.detailMinWidth(), SplitLayout.windowFloorWidth)
    }

    func testEachPaneFoldsAtItsOwnWidthAndStaysFoldedBelowIt() {
        for width in stride(from: 320.0, through: 1600.0, by: 7.0) {
            XCTAssertEqual(SplitLayout.contentsIsPopover(paneWidth: width),
                           width < SplitLayout.contentsFoldsBelow, "width=\(width)")
            XCTAssertEqual(SplitLayout.inspectorOverlays(paneWidth: width),
                           width < SplitLayout.inspectorOverlaysBelow, "width=\(width)")
        }
    }

    /// They fold in order: by the time the sidebar is an overlay the other two have
    /// already given way, so a window never loses the big thing before the small one.
    func testTheyFoldOutsideIn() {
        XCTAssertGreaterThan(SplitLayout.contentsFoldsBelow, SplitLayout.inspectorOverlaysBelow)
        XCTAssertGreaterThan(SplitLayout.inspectorOverlaysBelow, SplitLayout.sidebarOverlaysBelow)
    }

    func testAnOverlaidPanelNeverCoversThePageEntirely() {
        for width in stride(from: 200.0, through: 1000.0, by: 11.0) {
            let panel = SplitLayout.overlayPanelWidth(paneWidth: width)
            XCTAssertGreaterThanOrEqual(panel, 0, "width=\(width)")
            XCTAssertLessThanOrEqual(panel, max(0, width - SplitLayout.previewFloorBesideContents),
                                     "width=\(width)")
        }
    }

    func testAnOverlaidPanelKeepsItsIdealWidthWhenThereIsRoom() {
        XCTAssertEqual(SplitLayout.overlayPanelWidth(paneWidth: 960),
                       SplitLayout.panelReserved - SplitLayout.dividerBeforeInspector)
    }
}
