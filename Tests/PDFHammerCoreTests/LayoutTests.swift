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
        XCTAssertEqual(SplitLayout.minWidth(notesShown: false, contentsShown: false), 721)
    }

    func testMinWidthMatchesTheEstablishedConstantsWithNotesRailOpen() {
        XCTAssertEqual(SplitLayout.minWidth(notesShown: true, contentsShown: false), 962)
    }

    /// At the window's own stated minimum, `inspectorMaximum` must never be asked to
    /// satisfy less room than `minWidth` assumed -- otherwise the window's floor and the
    /// split's clamp disagree, and the pane overflows anyway even though the window
    /// "can't" be resized narrower than the layout requires.
    func testMaximumNeverFallsBelowMinimumAtTheWindowsOwnFloor() {
        for notes in [false, true] {
            for contents in [false, true] {
                let available = SplitLayout.minWidth(notesShown: notes, contentsShown: contents)
                let maximum = SplitLayout.inspectorMaximum(
                    available: available, notesShown: notes, contentsShown: contents)
                let minimum = SplitLayout.inspectorMinimum(contentsShown: contents)
                XCTAssertGreaterThanOrEqual(maximum, minimum,
                    "notesShown=\(notes) contentsShown=\(contents)")
            }
        }
    }
}
