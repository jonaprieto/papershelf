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

    /// The notes rail's own fixed width, plus the divider `split` draws ahead of it.
    public static let notesReserved: CGFloat = 240 + 1

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
    public static func inspectorMaximum(
        available: CGFloat, notesShown: Bool, contentsShown: Bool
    ) -> CGFloat {
        let minimum = inspectorMinimum(contentsShown: contentsShown)
        let reserved = contentFloor + dividerBeforeInspector + (notesShown ? notesReserved : 0)
        return max(minimum, available - reserved)
    }

    /// What the window has to be at least this wide for: the browser's floor, the divider
    /// ahead of the inspector, the inspector's own floor (which grows when the contents
    /// rail is open), and the notes rail when it is open. The window's own `.frame(minWidth:)`
    /// is derived from this so it can no longer drift out of step with what the panes
    /// inside it actually add up to.
    public static func minWidth(notesShown: Bool, contentsShown: Bool) -> CGFloat {
        contentFloor + dividerBeforeInspector
            + inspectorMinimum(contentsShown: contentsShown)
            + (notesShown ? notesReserved : 0)
    }
}
