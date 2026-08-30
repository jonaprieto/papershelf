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
        return max(minimum, available - contentFloor - dividerBeforeInspector)
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

    /// The rail's drawn width inside an inspector this wide.
    ///
    /// The rail gives way before the page does: a list of chapter titles still reads at
    /// 130 points, whereas a page squeezed to the same is not a page any more.
    public static func contentsRailWidth(inspectorWidth: CGFloat) -> CGFloat {
        let ideal = contentsReserved - dividerBeforeInspector
        return max(0, min(ideal, inspectorWidth - previewFloorBesideContents))
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
        return min(max(preferred, floor), room - contentFloor)
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

    /// Below this the four views of the collection collapse from a row of icons into one
    /// menu. The row is worth its width: it says which views exist and switches in one
    /// click. The menu is what a toolbar already carrying a search field and the actions
    /// for the current mode has room for.
    static let viewIconsBelow: CGFloat = 520

    /// The smallest window the app will open at, and the smallest it can be dragged to.
    static let windowFloorWidth: CGFloat = 640
    static let windowFloorHeight: CGFloat = 480

    static func contentsIsPopover(paneWidth: CGFloat) -> Bool {
        paneWidth < contentsFoldsBelow
    }

    static func inspectorOverlays(paneWidth: CGFloat) -> Bool {
        paneWidth < inspectorOverlaysBelow
    }

    static func showsViewIcons(paneWidth: CGFloat) -> Bool {
        paneWidth >= viewIconsBelow
    }

    /// How wide the search field should be. It was 240 points on every window, which on a
    /// wide screen is a slot for six characters of a query beside half a metre of nothing.
    /// A third of the pane, held between something readable and something that would start
    /// crowding out the actions in the same bar.
    static func searchFieldWidth(paneWidth: CGFloat) -> CGFloat {
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
