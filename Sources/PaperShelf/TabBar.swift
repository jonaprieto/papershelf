import SwiftUI

/// One pane's open documents.
///
/// A scroll view rather than a row that grows: a pane can be 328 points wide and a person can
/// have a dozen papers open, and an HStack asked for less room than its children need does not
/// clip, it draws them over whatever is beside it. That is not a hypothetical here; the filter
/// bar in this same window did exactly that.
struct TabBar: View {
    let tabs: [Deck.Tab]
    let active: Deck.Tab.ID?
    /// What to call a tab. The deck holds keys, which are paths; the name a person reads is
    /// the library's business, not this view's.
    let title: (Deck.Tab) -> String
    let activate: (Deck.Tab.ID) -> Void
    let close: (Deck.Tab.ID) -> Void
    /// What the + asks for. A tab here is a document, so there is no blank one to open and
    /// nothing to show until a paper is chosen; this hands the pointer the list ⌘K already
    /// gives rather than standing up a second document picker beside it.
    let open: () -> Void

    static let height: CGFloat = 28
    /// Wide enough for a recognisable stem, narrow enough that four tabs fit a narrow pane.
    private static let maximumTabWidth: CGFloat = 180

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        tabView(tab)
                        Divider().frame(height: TabBar.height - Space.step)
                    }
                }
            }
            .scrollIndicators(.hidden)
            openButton
        }
        .frame(height: TabBar.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .clipped()
    }

    /// Beside the scroll view, not in it, and pinned to the trailing edge.
    ///
    /// A dozen papers open is the case this has to survive, and it is also the case where
    /// somebody most wants another one. Inside the scroll view the + scrolls away with the
    /// tabs; after the tabs in a plain row their own width pushes it past the pane's edge,
    /// where the bar's clip erases it. Pinned here it is in the same place at every tab
    /// count, and the tabs scroll under it.
    private var openButton: some View {
        Button(action: open) {
            Image(systemName: "plus")
                .font(Face.control)
                .frame(width: TabBar.height, height: TabBar.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open a paper")
        .accessibilityIdentifier("tabBar.open")
        .tip("Open a paper", key: "⌘K")
    }

    private func tabView(_ tab: Deck.Tab) -> some View {
        let isActive = tab.id == active
        return HStack(spacing: Space.tight) {
            Text(title(tab))
                .font(Face.caption)
                .italic(tab.isPreview)
                .lineLimit(1)
                .truncationMode(.middle)
            Button { close(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(title(tab))")
        }
        .padding(.horizontal, Space.snug)
        .frame(maxWidth: TabBar.maximumTabWidth)
        .frame(height: TabBar.height)
        .background(isActive ? Color.primary.opacity(0.10) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { activate(tab.id) }
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
