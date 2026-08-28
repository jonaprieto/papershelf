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

    /// Whether the inspector panel fits beside the page in an inspector this wide.
    ///
    /// A preference, not a reservation. Asked for where there is no room it simply is not
    /// drawn, and it comes back the moment there is — the bargain both rails already make.
    /// Without it, moving the panel beside the page would have pushed the window's floor
    /// up by its full width, which is the fault this whole exercise removed.
    public static func roomForPanel(inspectorWidth: CGFloat, contentsShown: Bool) -> Bool {
        inspectorWidth - panelReserved >= inspectorMinimum(contentsShown: contentsShown)
    }

    /// A page still worth looking at beside an open contents rail. Less than the browser's
    /// floor on purpose: this is the case where the window is already short of room, and a
    /// page squeezed to this is better than a pane hanging off the edge of the window.
    public static let previewFloorBesideContents: CGFloat = 140

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
