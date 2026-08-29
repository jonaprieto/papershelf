import SwiftUI
import AppKit
import PDFHammerCore

/// The app's colours, in one place.
///
/// These exact sRGB pairs were already the app's vocabulary; they were simply written out
/// again at every use, forty-odd times across seven files, which is why a status colour
/// could drift between the list and the reviewer. Naming them costs nothing at runtime —
/// `Color(light:dark:)` builds a dynamic `NSColor` that resolves per appearance — and it
/// means a palette change is one edit rather than a search.
enum Ink {
    /// Done: decrypted, confirmed, applied, a complete BibTeX entry.
    static let green = Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140))
    /// Planned: renamed, encrypted.
    static let blue = Color(light: srgb(29, 78, 216), dark: srgb(133, 174, 255))
    /// Needs a person: locked, missing a field, a warning that can be acted on.
    static let amber = Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60))
    /// Went wrong, or is about to be destroyed: failed, deleted, trashed.
    static let red = Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130))
    /// Deliberately nothing: skipped, unchanged, already correct.
    static let grey = Color(light: srgb(88, 88, 96), dark: srgb(178, 178, 190))
    /// Somewhere else: moved, or the same book twice.
    static let purple = Color(light: srgb(109, 40, 217), dark: srgb(196, 165, 255))
    /// Only the BibTeX highlighter uses this one, for an entry type.
    static let magenta = Color(light: srgb(142, 42, 152), dark: srgb(214, 137, 226))

    /// The tint behind a pill or chip carrying one of the colours above.
    static let fill = 0.16
}

/// Sizes the interface agrees on, so a control is the same height in a toolbar as it is
/// in a panel and a corner radius climbs with the size of the thing it wraps.
enum Metric {
    // Bars
    static let toolbar: CGFloat = 52
    static let filterBar: CGFloat = 38
    static let statusBar: CGFloat = 26

    // Panels
    static let sidebarMin: CGFloat = 220
    static let sidebarIdeal: CGFloat = 264
    static let sidebarMax: CGFloat = 360
    static let inspectorMin: CGFloat = 280
    static let inspectorIdeal: CGFloat = 320
    static let inspectorMax: CGFloat = 480
    static let contentsRail: CGFloat = 200

    // Rows
    static let sidebarRow: CGFloat = 26
    static let planRow: CGFloat = 44

    // Corners, by the size of what they wrap
    static let keyCap: CGFloat = 3
    static let cover: CGFloat = 5
    static let control: CGFloat = 6
    static let group: CGFloat = 7
    static let card: CGFloat = 9
    static let popover: CGFloat = 10

    /// The shelf: a cover keeps a book's proportions rather than being letterboxed into a
    /// fixed band, so the grid asks for a width and derives the height.
    static let coverWidth: CGFloat = 176
    static let coverAspect: CGFloat = 1.32

    /// The grid's 18pt outer padding is part of its width budget. Keeping it here makes
    /// the shelf stop claiming a second card until two ideal cards actually fit.
    static func catalogueColumns(for width: CGFloat) -> Int {
        let usable = max(0, width - 2 * gridSpacing)
        return max(1, Int((usable + gridSpacing) / (coverWidth + gridSpacing)))
    }

    /// How tall a cover is at a given width.
    ///
    /// It used to be 168 points whatever the width, which is why a tall book sat in a
    /// letterbox with grey above and below it and a wide one was cropped: the band was a
    /// constant and a book is not. Anything at or below zero returns zero rather than a
    /// negative frame, since a grid mid-resize will ask.
    static func coverHeight(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return (width * coverAspect).rounded()
    }
    static let gridSpacing: CGFloat = 18

    /// Breakpoints. Below each, something folds away rather than being cut off.
    ///
    /// Read from `SplitLayout` rather than written again here: the arithmetic that acts
    /// on them is pure and tested, and a second copy of a breakpoint is how a pane and
    /// the window's own floor came to disagree in the first place.
    static let contentsFoldsBelow = SplitLayout.contentsFoldsBelow
    static let inspectorOverlaysBelow = SplitLayout.inspectorOverlaysBelow
    static let sidebarOverlaysBelow = SplitLayout.sidebarOverlaysBelow
    static let windowFloorWidth = SplitLayout.windowFloorWidth
    static let windowFloorHeight = SplitLayout.windowFloorHeight
}


/// The type scale.
///
/// One face for the interface and a serif for anything that came out of a document — page
/// text, a quoted highlight, a book's own title on its cover. The sizes are the ones the
/// app already used most; naming them is what stops a caption being 11 points in one view
/// and 12 in the next.
enum Face {
    static let title = Font.system(size: 22, weight: .semibold)
    static let headline = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let control = Font.system(size: 12)
    static let caption = Font.system(size: 11)
    static let section = Font.system(size: 11, weight: .semibold)
    static let micro = Font.system(size: 10)
    /// Filenames, paths and anything else where a character's identity matters more than
    /// how the line looks.
    static let mono = Font.system(size: 11.5, design: .monospaced)
    /// Anything the document itself said.
    static let page = Font.system(size: 13.5, design: .serif)
}

/// Things held for this run of the app and never written down.
///
/// The output password lived as `@State` on the one view that asked for it, which was
/// fine while that view was also the only one that used it. Settings is a separate scene,
/// so it needs somewhere to put the value that is still not a preferences file: a
/// password written into a plist is not a password.
@MainActor
final class SessionSecret: ObservableObject {
    static let shared = SessionSecret()
    @Published var encryptPassword = ""
    private init() {}
}
