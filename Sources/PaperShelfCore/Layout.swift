import Foundation

/// The arithmetic behind the results pane's three/four-pane split: the browser, the
/// inspector, and the inspector's own two optional siblings (the notes rail and, nested
/// inside the inspector itself, the contents rail). Kept as pure functions so the exact
/// bug class that has hit this app three times now -- a fixed-width neighbour that the
/// surrounding width math never learned about -- can be pinned down by a real test
/// instead of an ad hoc rendering harness, since none of this needs a view to compute.
public enum SplitLayout {
    /// A pane large enough to be worth looking at. The browser (the catalogue, list,
    /// bibliography or duplicates view) and the PDF preview inside the inspector both
    /// use this as their floor.
    public static let contentFloor: CGFloat = 360

    /// The inspector panel's width, plus the divider drawn ahead of it. It sits beside the
    /// page inside the inspector rather than under it, which is what let the notes stop
    /// being a column of their own.
    public static let panelReserved: CGFloat = 320 + 1

    /// The contents rail's own fixed width, plus the divider `ReviewInspector` draws
    /// ahead of it. Nested inside the inspector rather than a sibling in `split`'s own
    /// HStack, so it eats into the inspector's width instead of the window's.
    public static let contentsReserved: CGFloat = 196 + 1

    /// The most of a pane the inspector may take, however wide it was last dragged.
    ///
    /// The width is one absolute number shared by every display the app is ever opened
    /// on, and it ships at 840. On a 16 inch window's detail column that is a page and a
    /// panel; on a 13 inch laptop's 1176 it left the shelf exactly `contentFloor`, so the
    /// file list a person came here to read was 360 points wide from first launch with
    /// 815 points of inspector beside it. A floor is what a pane may be squeezed to, not
    /// what it should open at.
    ///
    /// A share rather than a second absolute, because the same window gets dragged
    /// between displays and the proportion is the part that should follow it.
    public static let inspectorShareCeiling: CGFloat = 0.55

    /// The divider `split` draws between the browser and the inspector.
    public static let dividerBeforeInspector: CGFloat = 1

    /// How narrow the inspector may ever get. Ordinarily just its own content floor, but
    /// when the contents rail is nested inside it, that rail's width has to come out of
    /// the same budget before the PDF preview sitting next to it gets its own floor --
    /// otherwise the preview is squeezed with nothing stopping it, exactly as the layout
    /// audit flagged for this rail and already fixed once for the notes rail.
    public static func inspectorMinimum(contentsShown: Bool) -> CGFloat {
        contentFloor + (contentsShown ? contentsReserved : 0)
    }

    /// How wide the inspector may be given the room `split` actually has, so the browser
    /// (and, when it is open, the notes rail, a further fixed-width sibling of that same
    /// row) always keep their own floor.
    ///
    /// Reserving only the browser's floor and handing everything else to the inspector let
    /// the rail, and the divider ahead of it, get squeezed past the window edge, taking the
    /// browser down with it: the inspector would happily claim room the notes rail also
    /// needed.
    public static func inspectorMaximum(available: CGFloat, contentsShown: Bool) -> CGFloat {
        let minimum = inspectorMinimum(contentsShown: contentsShown)
        let roomy = min(available - contentFloor - dividerBeforeInspector, share(of: available))
        return max(minimum, roomy)
    }

    /// `inspectorShareCeiling` of a pane this wide, rounded to a whole point.
    public static func share(of available: CGFloat) -> CGFloat {
        (available * inspectorShareCeiling).rounded()
    }

    /// What the window has to be at least this wide for: the browser's floor, the divider
    /// ahead of the inspector, and the inspector's own floor. The window's own
    /// `.frame(minWidth:)` is derived from this so it can no longer drift out of step with
    /// what the panes inside it actually add up to.
    ///
    /// Neither optional rail counts towards it. The contents rail never did, and the
    /// comment explaining why applies word for word to the notes rail, which until now
    /// did: opening it raised the window's minimum by 241 points, so a window that could
    /// grow jumped, and a window that could not -- one tiled, or filling a small display
    /// -- was asked for a width it had no way to give. Both rails now come out of the room
    /// that exists (see `roomForNotes`), which is a rail that folds away rather than a
    /// window that breaks.
    public static func minWidth() -> CGFloat {
        contentFloor + dividerBeforeInspector + contentFloor
    }

    /// The smallest readable PDF preview beside an inspector. Below this, the inspector
    /// overlays the page rather than turning a document into an unreadable thumbnail.
    public static let previewFloorBesideContents: CGFloat = 300

    /// The narrowest an outline can be and still be one. A list of chapter titles reads at
    /// 130 points; under that every title is an ellipsis, which takes room from the page
    /// and tells nobody where they are in the document.
    public static let contentsRailFloor: CGFloat = 130

    /// The rail's drawn width inside an inspector this wide, and nothing where what is
    /// left over would be too narrow to read.
    ///
    /// The rail gives way before the page does: it narrows to `contentsRailFloor` rather
    /// than let the page be squeezed under its own floor, and under that it is dropped
    /// rather than narrowed further. The reviewer never reached the bottom of this ramp,
    /// because it asks for no rail at all on a pane under 1100 points. The reader has no
    /// such fold and reaches all of it: at 640 points with the notes open it was drawing a
    /// 79 point strip and calling it a table of contents.
    public static func contentsRailWidth(inspectorWidth: CGFloat) -> CGFloat {
        let ideal = contentsReserved - dividerBeforeInspector
        let room = min(ideal, inspectorWidth - previewFloorBesideContents)
        return room < contentsRailFloor ? 0 : room
    }

    /// The width the inspector actually gets: what was asked for, held between its own
    /// floor and whatever leaves the browser its floor, and never more than the room that
    /// exists.
    ///
    /// The last clause is the one that matters. Clamping to `max(minimum, ...)` alone
    /// returns a floor the window may not be able to honour, and SwiftUI then lays the
    /// pane out at that width regardless, pushing whatever sits beyond it off the edge.
    /// When there is not room for both floors the two panes share what there is instead,
    /// which keeps every pane on screen and legible even when it is smaller than anyone
    /// would like.
    public static func inspectorWidth(preferred: CGFloat, available: CGFloat,
                                      contentsShown: Bool) -> CGFloat {
        let room = max(0, available - dividerBeforeInspector)
        let floor = inspectorMinimum(contentsShown: contentsShown)
        guard room >= floor + contentFloor else { return (room / 2).rounded() }
        // The share is a ceiling on what was asked for, not on the floor: a pane still
        // gets what its own controls need on a window too small to give it a share.
        return min(max(min(preferred, share(of: available)), floor), room - contentFloor)
    }
}

// MARK: - Folding

/// Where each pane gives way as the window narrows.
///
/// Nothing is removed at a narrow width; it moves somewhere that costs no horizontal
/// room. The contents rail becomes a popover, the inspector panel overlays the page
/// instead of pushing it, and the sidebar collapses to an overlay the platform already
/// knows how to draw. Pure numbers so a test can hold the window's floor to them: the
/// floor used to be 1011 points wide, and 1252 with the notes open, because every one of
/// these was a fixed neighbour the width arithmetic had to reserve for.
public extension SplitLayout {
    /// Below this the contents rail folds into a popover under its toolbar button.
    static let contentsFoldsBelow: CGFloat = 1100
    /// Below this the inspector panel is drawn over the page rather than beside it.
    static let inspectorOverlaysBelow: CGFloat = panelFloor + previewFloorBesideContents
        + dividerBeforeInspector
    /// Below this the sidebar is an overlay. The platform's split view does this itself;
    /// the number is here so the rest of the app can agree about when it happens.
    static let sidebarOverlaysBelow: CGFloat = 360

    /// What the sidebar asks for when it is drawn beside the shelf rather than over it.
    /// Narrower than this and its own rows start being clipped by the window's edge.
    static let sidebarFloor: CGFloat = 220

    /// Whether a screen this wide has room for a window that carries the sidebar as well
    /// as the shelf and the inspector.
    ///
    /// The window cannot be made narrow: its panes have floors, and they hold it at about
    /// 885 points however small the display is. On a screen not much wider than that the
    /// sidebar is the pane that has to go, or the three of them are drawn over each other
    /// and the sidebar's headings end up clipped against the window's edge. Hidden is not
    /// gone: ⌘B brings it back as an overlay.
    ///
    /// Not the sum of the three floors, which comes to 841 and would call a 1024 point
    /// display roomy. The window's own minimum is already near 885, and a window that
    /// exactly fills the screen is not what having room means. A 13 inch laptop is 1440
    /// points and has room; the small external displays people plug into are 1280 and do
    /// not, once the inspector is open.
    static let sidebarNeedsScreen: CGFloat = 1360

    static func startsWithSidebar(screenWidth: CGFloat) -> Bool {
        screenWidth >= sidebarNeedsScreen
    }

    /// Whether a window this wide can show the sidebar without taking the shelf apart.
    ///
    /// The platform collapses the sidebar column eventually, but it holds on well past the
    /// point where the two panes are worth having: at 560 points the sidebar is at its
    /// floor, the shelf is at its floor, and the section headings are clipped against the
    /// window edge. Below this the sidebar starts hidden and ⌘B brings it back as the
    /// overlay the platform draws.
    static func showsSidebar(windowWidth: CGFloat) -> Bool {
        windowWidth >= sidebarFloor + contentFloor
    }

    /// The smallest window the app will open at, and the smallest it can be dragged to.
    static let windowFloorWidth: CGFloat = 640
    static let windowFloorHeight: CGFloat = 480

    /// A reader is a page and the bar under it, so it is taller than the library window
    /// and narrower. What it opens at where the display can show it.
    static let readerIdealWidth: CGFloat = 900
    static let readerIdealHeight: CGFloat = 1000
    /// And the smallest it is worth drawing: below this the page bar's own controls start
    /// running into each other.
    static let readerFloorWidth: CGFloat = 520
    static let readerFloorHeight: CGFloat = 400

    /// What a reader opens at on a display that leaves this much room.
    ///
    /// It used to open at a flat 900 by 1000 wherever it was opened. A 13 inch laptop has
    /// 875 points of height once the menu bar has taken its own, so AppKit trimmed the
    /// window on its way to the screen and every reader there opened at full screen
    /// height, which is not a size anybody chose. The margin is so the window reads as a
    /// window rather than as the desktop.
    ///
    /// The floor wins over the fit: a display too small for both is a window that hangs
    /// off the edge, which the person can move, rather than a page too small to read.
    static func readerWindowSize(visible: CGSize) -> CGSize {
        let margin: CGFloat = 48
        return CGSize(
            width: max(readerFloorWidth, min(readerIdealWidth, visible.width - margin)),
            height: max(readerFloorHeight, min(readerIdealHeight, visible.height - margin)))
    }

    static func contentsIsPopover(paneWidth: CGFloat) -> Bool {
        paneWidth < contentsFoldsBelow
    }

    static func inspectorOverlays(paneWidth: CGFloat) -> Bool {
        paneWidth < inspectorOverlaysBelow
    }

    /// The command palette launcher is wide enough to name itself, without taking over
    /// the actions beside it on a large window.
    static func commandPaletteWidth(paneWidth: CGFloat) -> CGFloat {
        min(max(paneWidth / 3, 240), 560)
    }

    /// The narrowest the inspector panel is still worth drawing: a name field, a row of
    /// keyed buttons and a tab bar. Squeezed below this it does not shrink -- its contents
    /// overflow the frame they were given and paint over whatever is beside them, which is
    /// how a panel laid out at 151 points came to draw 280 points wide across the page.
    static let panelFloor: CGFloat = 260

    /// Whether a pane this wide can hold the page and the panel at once.
    static func showsPageBesidePanel(paneWidth: CGFloat) -> Bool {
        paneWidth >= panelFloor + previewFloorBesideContents + dividerBeforeInspector
    }

    /// How wide the inspector panel is drawn in a pane of this width.
    ///
    /// Its ideal where there is room, never less than its floor, and the whole pane when
    /// there is not room for both -- at which point the page is the thing that folds. It
    /// costs no horizontal room to fold: the reader opens it across the whole region.
    static func panelWidth(paneWidth: CGFloat) -> CGFloat {
        let ideal = panelReserved - dividerBeforeInspector
        guard showsPageBesidePanel(paneWidth: paneWidth) else { return max(0, paneWidth) }
        return max(panelFloor, min(ideal, paneWidth - previewFloorBesideContents))
    }

    /// What the detail side of the window has to be at least. Two panes and a divider
    /// while both are drawn side by side; one pane's floor once the panel overlays it,
    /// which is the whole reason the window can now reach 640.
    static func detailMinWidth() -> CGFloat { contentFloor }
}
