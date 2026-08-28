import SwiftUI
import AppKit

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
    static let gridSpacing: CGFloat = 18

    /// Breakpoints. Below each, something folds away rather than being cut off.
    static let contentsFoldsBelow: CGFloat = 1100
    static let inspectorOverlaysBelow: CGFloat = 1000
    static let sidebarOverlaysBelow: CGFloat = 900
    static let windowFloorWidth: CGFloat = 640
    static let windowFloorHeight: CGFloat = 480
}
