import SwiftUI

/// The five places focus can be, and the rule that makes moving between them predictable:
/// one key cycles, five jump, and ⎋ always means "out of this, into what contains it".
///
/// Anything you can click you can reach, and anything you can reach you can edit in place.
/// That promise is only keepable if there is one list of places to be — before this, focus
/// was whatever AppKit happened to have given the last thing clicked.
enum Region: Int, CaseIterable, Identifiable, Codable {
    case sidebar = 1, contents, document, inspector, status
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .sidebar: return "Sidebar"
        case .contents: return "Contents"
        case .document: return "Document"
        case .inspector: return "Inspector"
        case .status: return "Status bar"
        }
    }
}

/// Which rung of the ladder ⎋ is on. One key, always meaning the same thing, so escape is
/// never a guess.
enum EscapeRung: Equatable {
    /// Leaves the field for the row it belongs to, keeping what was typed.
    case leaveField
    /// Leaves the row for its region: the ring moves to the whole pane.
    case leaveRow
    /// Clears the search and any filter chips, so the next press has something left to do.
    case clearFilters
    /// Leaves the place: the reader, the project, the palette, the popover.
    case leavePlace
    /// Nothing left to leave.
    case nothing
}

@MainActor
@Observable
final class Regions {
    static let shared = Regions()

    var focused: Region = .document
    /// Which regions are drawn right now. A collapsed sidebar and an absent table of
    /// contents are not places to be, so cycling skips them and jumping to one opens it.
    var available: Set<Region> = [.sidebar, .document, .inspector, .status]
    /// True while a row inside the focused region is the thing selected, rather than the
    /// region as a whole. The ⎋ ladder reads it.
    var rowFocused = false

    private init() {}

    func focus(_ region: Region) {
        focused = region
        rowFocused = false
    }

    func step(_ delta: Int) {
        focused = Regions.next(from: focused, by: delta, available: available)
        rowFocused = false
    }

    /// The next available region in cycle order, wrapping, skipping anything not drawn.
    ///
    /// Pure so the cycle can be tested without a window: the bug this prevents is a key
    /// that appears to do nothing because it moved focus to a pane that is not on screen.
    static func next(from current: Region, by delta: Int, available: Set<Region>) -> Region {
        let order = Region.allCases
        guard !available.isEmpty else { return current }
        let start = order.firstIndex(of: current) ?? 0
        for step in 1...order.count {
            let index = (start + delta * step % order.count + order.count * order.count) % order.count
            let candidate = order[index]
            if available.contains(candidate) { return candidate }
        }
        return current
    }

    /// What ⎋ means right now.
    ///
    /// Read top to bottom: the innermost thing you are inside is the thing you leave, so
    /// one press never skips a level and never does two things at once.
    static func escape(editingField: Bool, rowFocused: Bool, filtering: Bool,
                       insidePlace: Bool) -> EscapeRung {
        if editingField { return .leaveField }
        if rowFocused { return .leaveRow }
        if filtering { return .clearFilters }
        if insidePlace { return .leavePlace }
        return .nothing
    }
}


/// The 2pt ring that says which region has the keys.
///
/// Focus is never invisible: without this, the difference between "the sidebar has the
/// arrow keys" and "the shelf has them" was whatever the last click happened to leave
/// behind, and the only way to find out was to press a key and see what moved.
struct RegionRing: ViewModifier {
    let region: Region
    private let regions = Regions.shared

    init(_ region: Region) { self.region = region }

    func body(content: Content) -> some View {
        content
            // A bar down the leading edge rather than a box around everything. The box
            // said the right thing and said it far too loudly: two accent-coloured
            // rectangles nested inside each other, drawn over content, on every screen.
            // The edge marks the same region and stays out of the way of what is in it.
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .opacity(regions.focused == region ? 0.85 : 0)
                    .allowsHitTesting(false)
            }
            // Simultaneous, not a gesture of its own: clicking inside a region should
            // focus it and still do whatever the click was for.
            .simultaneousGesture(TapGesture().onEnded { regions.focus(region) })
    }
}

extension View {
    func region(_ region: Region) -> some View { modifier(RegionRing(region)) }
}
