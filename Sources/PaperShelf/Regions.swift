import SwiftUI
import PDFKit

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

    /// Whether this region has the arrow keys.
    ///
    /// Every pane that draws its own selection asks, and draws it in the accent colour
    /// when the answer is yes and in grey when it is no. That is what a macOS list does
    /// for free when it is the first responder, and what this app has to do by hand
    /// because it decides for itself where focus is.
    func hasKeys(_ region: Region) -> Bool { focused == region }

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


/// Clicking inside a region gives it the keys.
///
/// It used to draw the answer as well: first a box around the whole pane, then, when that
/// proved far too loud, a 2pt accent bar down its leading edge. Both were chrome the
/// platform does not have, permanently on screen, saying something every macOS list
/// already says by drawing its own selection in the accent colour while it has the keys
/// and in grey while it does not. `Regions.hasKeys(_:)` is how the panes say it now.
struct RegionFocus: ViewModifier {
    let region: Region
    private let regions = Regions.shared

    init(_ region: Region) { self.region = region }

    func body(content: Content) -> some View {
        content
            // Simultaneous, not a gesture of its own: clicking inside a region should
            // focus it and still do whatever the click was for.
            .simultaneousGesture(TapGesture().onEnded { regions.focus(region) })
    }
}

extension View {
    func region(_ region: Region) -> some View { modifier(RegionFocus(region)) }
}

/// ⇧H and ⇧L move the keys to the pane on the left or the right, the way H and L move the
/// page: in the reader that is the outline, the page and the notes; in the library, the
/// sidebar, the files and the inspector.
///
/// Found by where the panes are drawn rather than by naming them, so it reaches whatever
/// is on screen in whichever window has the keys, and skips what is folded away. A pane
/// here is a list or a page, the two things in this app that take keys of their own.
@MainActor
enum PaneHop {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    private static func handle(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == .shift,
              let key = event.charactersIgnoringModifiers?.lowercased(), key == "h" || key == "l",
              let window = event.window else { return false }
        // A capital letter typed into a note or a name is a capital letter.
        if let text = window.firstResponder as? NSTextView, text.isEditable { return false }
        let panes = candidates(in: window)
        let responder = window.firstResponder as? NSView
        let current = panes.first { pane in responder.map { $0 === pane || $0.isDescendant(of: pane) } ?? false }
        guard let index = next(from: current.map(leftEdge), among: panes.map(leftEdge),
                               step: key == "l" ? 1 : -1) else { return true }
        window.makeFirstResponder(panes[index])
        return true
    }

    private static func leftEdge(_ view: NSView) -> CGFloat {
        view.convert(view.visibleRect, to: nil).minX
    }

    private static func candidates(in window: NSWindow) -> [NSView] {
        var found: [NSView] = []
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            if view is NSTableView || view is PDFView {
                if !view.visibleRect.isEmpty, view.acceptsFirstResponder { found.append(view) }
                return
            }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        return found
    }

    /// The nearest pane whose left edge is past the current one's, in the direction of the
    /// step; nil at the edge, which does not wrap. Two lists stacked in one column share an
    /// edge, so a few points either way count as the same column. With nothing focused,
    /// ⇧L lands on the leftmost pane and ⇧H on the rightmost.
    static func next(from current: CGFloat?, among edges: [CGFloat], step: Int) -> Int? {
        let slack: CGFloat = 8
        let ahead = edges.indices.filter { index in
            guard let current else { return true }
            return step > 0 ? edges[index] > current + slack : edges[index] < current - slack
        }
        return step > 0 ? ahead.min { edges[$0] < edges[$1] } : ahead.max { edges[$0] < edges[$1] }
    }
}
