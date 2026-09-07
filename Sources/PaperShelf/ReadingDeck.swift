import Foundation

/// What a window has open, and which of it is on screen.
///
/// A value type with pure functions rather than a class with methods, for the reason
/// `Regions.next` and every function in `SplitLayout` are written that way: these rules are
/// fiddly, they are the kind that go wrong quietly, and a value in, value out shape is one a
/// test can pin without a window. Nothing draws a deck yet.
struct Deck: Equatable {
    var panes: [Pane]
    /// Which pane the rails, the notes and the highlighter keys describe. One pane today;
    /// the split adds the second.
    var activePane: Pane.ID

    struct Pane: Identifiable, Equatable {
        let id: UUID
        var tabs: [Tab] = []
        /// Nil only while the pane holds nothing.
        var active: Tab.ID?
    }

    /// One open document. It owns its `Annotator`, so switching away and back keeps the
    /// marks, the outline, the bookmarks and the find session that were already there.
    ///
    /// It holds no `PDFDocument`. `PDFPreview` owns that through its `NSView`, which goes
    /// away with the tab's pane when the tab is not on screen, so a tab in the background
    /// costs what is listed here and nothing more.
    struct Tab: Identifiable {
        let id: UUID
        let key: String
        /// The reviewer's selection, drawn in italics and replaced as the selection moves.
        /// A kept tab is one somebody asked for.
        var isPreview: Bool
        let annotator: Annotator
    }

    static func one(pane: UUID) -> Deck {
        Deck(panes: [Pane(id: pane)], activePane: pane)
    }

    var active: Pane? { panes.first { $0.id == activePane } }

    var activeTab: Tab? {
        guard let pane = active, let id = pane.active else { return nil }
        return pane.tabs.first { $0.id == id }
    }

    /// Where the one preview tab is. There is at most one in the whole deck, which is why
    /// this looks past the active pane: `promotingPreview` already clears them everywhere,
    /// and a lookup that stopped at one pane would let a second preview stand beside it.
    private var previewPosition: (pane: Int, tab: Int)? {
        for pane in panes.indices {
            if let tab = panes[pane].tabs.firstIndex(where: \.isPreview) { return (pane, tab) }
        }
        return nil
    }

    /// Open a document, or look at the one already open for it.
    ///
    /// `kept: false` is the reviewer's selection moving. It replaces the preview tab rather
    /// than adding one, which is what keeps a walk through two hundred files from opening
    /// two hundred tabs.
    func opening(_ key: String, kept: Bool, makeAnnotator: () -> Annotator) -> Deck {
        var deck = self
        guard let index = deck.panes.firstIndex(where: { $0.id == activePane }) else { return deck }

        if let existing = deck.panes[index].tabs.firstIndex(where: { $0.key == key }) {
            if kept { deck.panes[index].tabs[existing].isPreview = false }
            deck.panes[index].active = deck.panes[index].tabs[existing].id
            return deck
        }

        let tab = Tab(id: UUID(), key: key, isPreview: !kept, annotator: makeAnnotator())
        if !kept, let preview = previewPosition {
            // The selection moving replaces the deck's preview wherever it sits, not only
            // one the active pane happens to hold. Looking in a single pane would let a
            // second preview stand beside the first the day a window has two.
            deck.panes[preview.pane].tabs[preview.tab] = tab
            deck.panes[preview.pane].active = tab.id
            return deck
        }
        if kept {
            deck.panes[index].tabs.append(tab)
        } else {
            // Ahead of the kept tabs: it is the one that moves, so it stays where the eye
            // already is rather than walking along the bar as the selection changes.
            deck.panes[index].tabs.insert(tab, at: 0)
        }
        deck.panes[index].active = tab.id
        return deck
    }

    func activating(_ tab: Tab.ID) -> Deck {
        var deck = self
        guard let index = deck.panes.firstIndex(where: { $0.id == activePane }),
              deck.panes[index].tabs.contains(where: { $0.id == tab }) else { return deck }
        deck.panes[index].active = tab
        return deck
    }

    /// Close a tab, and say what is showing afterwards: the one to its right, or the one to
    /// its left when it was last. A pane that runs out of tabs stays, empty.
    func closing(_ tab: Tab.ID) -> Deck {
        var deck = self
        guard let index = deck.panes.firstIndex(where: { $0.id == activePane }),
              let at = deck.panes[index].tabs.firstIndex(where: { $0.id == tab })
        else { return deck }

        let wasActive = deck.panes[index].active == tab
        deck.panes[index].tabs.remove(at: at)
        guard wasActive else { return deck }
        let next = min(at, deck.panes[index].tabs.count - 1)
        deck.panes[index].active = next >= 0 ? deck.panes[index].tabs[next].id : nil
        return deck
    }

    /// Turn the preview tab into one that stays.
    func promotingPreview() -> Deck {
        var deck = self
        for pane in deck.panes.indices {
            for tab in deck.panes[pane].tabs.indices where deck.panes[pane].tabs[tab].isPreview {
                deck.panes[pane].tabs[tab].isPreview = false
            }
        }
        return deck
    }

    func stepping(by delta: Int) -> Deck {
        guard let pane = active, !pane.tabs.isEmpty,
              let at = pane.tabs.firstIndex(where: { $0.id == pane.active })
        else { return self }
        let count = pane.tabs.count
        let next = ((at + delta) % count + count) % count
        return activating(pane.tabs[next].id)
    }
}

extension Deck.Tab: Equatable {
    /// By what it is, not by the annotator it carries: `Annotator` is a reference and a
    /// class with no `Equatable` of its own, and two tabs are the same tab when they have
    /// the same identity, key and standing.
    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.key == b.key && a.isPreview == b.isPreview
    }
}
