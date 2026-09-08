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
    /// Whether what the deck is showing is showing because the reviewer's selection is on
    /// it.
    ///
    /// A preview tab says as much by being one, and that is what stops a walk down a
    /// folder from rewriting which paper the next launch opens. A paper somebody kept open
    /// says nothing of the kind, and the selection landing on one is still browsing rather
    /// than reading, so the deck has to say it here: three papers restored with the shelf
    /// standing on the first of them used to change the remembered paper before anybody
    /// had read a word.
    var showingSelection = false

    struct Pane: Identifiable, Equatable {
        let id: UUID
        var tabs: [Tab] = []
        /// Nil only while the pane holds nothing.
        var active: Tab.ID?
    }

    /// One open document. It carries an `Annotator` that nothing reads yet. The window
    /// holds one of its own, and `PDFPreview` attaches that to whichever document is on
    /// screen; attaching drops the marks, the outline and the bookmarks and closes the find
    /// session, so switching away and back loses the search you were in the middle of and
    /// re-reads everything else. The day the window reads the tab's own annotator instead,
    /// coming back to a paper costs the page and nothing more: no second walk over a long
    /// book's notes, and the find still open where you left it.
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
        deck.showingSelection = !kept

        // The selection moving replaces the deck's preview wherever it sits, not only one
        // the active pane happens to hold. Looking in a single pane would let a second
        // preview stand beside the first the day a window has two.
        let preview = kept ? nil : previewPosition
        // Which means the tab does not always land in the pane the eye is on, so whether it
        // is already open has to be asked of the pane it lands in. Asked of the active pane
        // alone, a document already kept in the pane that holds the preview gets opened a
        // second time beside itself: the same paper twice on one bar, and a stored deck the
        // next launch resolves by key and cannot tell the two apart. The same paper in two
        // different panes stays allowed; that one is deliberate.
        let target = preview?.pane ?? index

        if let existing = deck.panes[target].tabs.firstIndex(where: { $0.key == key }) {
            if kept { deck.panes[target].tabs[existing].isPreview = false }
            let showing = deck.panes[target].tabs[existing].id
            // The preview tab is where the selection is, and the selection is here now, on
            // a paper somebody had already asked to keep. Left where it was, it sits on the
            // bar in italics naming a paper nobody is looking at. Taken by id rather than
            // by index, because removing the one ahead of it moves the other along.
            if let preview, preview.tab != existing {
                deck.panes[preview.pane].tabs.remove(at: preview.tab)
            }
            deck.panes[target].active = showing
            // Showing it also means being in the pane that shows it.
            deck.activePane = deck.panes[target].id
            return deck
        }

        let tab = Tab(id: UUID(), key: key, isPreview: !kept, annotator: makeAnnotator())
        if let preview {
            deck.panes[preview.pane].tabs[preview.tab] = tab
            deck.panes[preview.pane].active = tab.id
            // And the focus follows it there, so an open shows what it opened. Left behind,
            // the deck would show whatever the pane that was active held, or nothing.
            deck.activePane = deck.panes[preview.pane].id
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
        // Somebody picked this one, so what is showing is no longer where the selection
        // happens to have got to, and it is worth writing down again.
        deck.showingSelection = false
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
        // A close is worth writing down, whatever the selection was doing when it came.
        deck.showingSelection = false
        guard wasActive else { return deck }
        let next = min(at, deck.panes[index].tabs.count - 1)
        deck.panes[index].active = next >= 0 ? deck.panes[index].tabs[next].id : nil
        return deck
    }

    /// Turn the preview tab into one that stays.
    func promotingPreview() -> Deck {
        var deck = self
        // Asked for, so no longer the selection passing through.
        deck.showingSelection = false
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

/// What is written down between launches: the order, and which one was showing.
///
/// Keys rather than tabs. An `Annotator` is built fresh on the way back in, and the page you
/// were on comes from `ReadingPositions` as it always has.
struct StoredDeck: Codable, Equatable {
    var panes: [[String]]
    /// The index of the active tab in each pane, or -1 where the pane holds nothing. It
    /// counts the tabs that were stored, so a preview tab standing ahead of them does not
    /// shift it onto the wrong paper.
    ///
    /// It has no way to point at the preview tab itself, and falls back to the first tab
    /// when the preview was the one showing. That fallback names a paper nobody was
    /// reading, which is why `ResultsPane.tabsToStore` writes nothing at all in that state
    /// rather than writing this.
    var active: [Int]
    var activePane: Int

    init(_ deck: Deck) {
        // The preview tab is the reviewer's selection rather than something anybody opened,
        // so it is not carried across a launch.
        let kept = deck.panes.map { $0.tabs.filter { !$0.isPreview } }
        panes = kept.map { $0.map(\.key) }
        active = zip(deck.panes, kept).map { pane, tabs in
            tabs.firstIndex { $0.id == pane.active } ?? (tabs.isEmpty ? -1 : 0)
        }
        activePane = deck.panes.firstIndex { $0.id == deck.activePane } ?? 0
    }
}

extension Deck {
    /// Rebuild what was open, dropping whatever is no longer there.
    ///
    /// A file renamed, moved or trashed since the last launch goes without comment, the same
    /// bargain an unreachable source already makes. If the one that was showing is the one
    /// that went, the pane shows something else rather than opening onto nothing.
    static func restoring(_ stored: StoredDeck, reachable: (String) -> Bool,
                          makeAnnotator: (String) -> Annotator) -> Deck {
        var panes: [Pane] = []
        for (index, keys) in stored.panes.enumerated() {
            let wanted = stored.active.indices.contains(index) ? stored.active[index] : -1
            let wantedKey = keys.indices.contains(wanted) ? keys[wanted] : nil
            let tabs = keys.filter(reachable).map {
                Tab(id: UUID(), key: $0, isPreview: false, annotator: makeAnnotator($0))
            }
            let active = tabs.first { $0.key == wantedKey }?.id ?? tabs.first?.id
            panes.append(Pane(id: UUID(), tabs: tabs, active: active))
        }
        // A window always has somewhere to put a document, even when nothing came back.
        if panes.isEmpty { panes = [Pane(id: UUID())] }
        let at = panes.indices.contains(stored.activePane) ? stored.activePane : 0
        return Deck(panes: panes, activePane: panes[at].id)
    }
}

/// The deck a window holds, so SwiftUI can watch it.
///
/// A box around the value rather than a model with methods: every rule lives on `Deck`,
/// where a test can reach it, and this exists only to be observed.
@MainActor
@Observable
final class ReadingDeck {
    var deck: Deck
    init(deck: Deck) { self.deck = deck }
}
