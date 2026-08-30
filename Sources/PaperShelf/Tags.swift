import SwiftUI
import PaperShelfCore

/// Everything a view needs to show and change one file's tags, in one value.
///
/// Tagging is offered in three places now: the right-click menu, the catalogue's cards,
/// and the Details panel beside the page. Passing the same value to all three is what
/// keeps them from drifting into three slightly different ideas of what a tag is: the
/// list, the suggestions and the three actions are defined once, by whoever owns the
/// library connection (`CatalogueTags`), rather than assembled again at each call site.
struct TagActions {
    /// This file's tags, in the order the library returns them.
    var tags: [String] = []
    /// Every tag in use anywhere, so adding one is a pick rather than a retype that can
    /// be misspelled into a second, near-identical tag.
    var available: [String] = []
    /// False only when the library itself could not be opened. A file not indexed yet is
    /// not this case: adding a tag indexes it on the spot.
    var isAvailable = false
    var add: (String) -> Void = { _ in }
    var remove: (String) -> Void = { _ in }
    /// Opens the prompt for a tag that does not exist yet.
    var new: () -> Void = {}

    /// What is worth offering: every tag this file does not already carry. Offering one it
    /// has would either do nothing or, worse, read as a way to remove it.
    var suggestions: [String] { available.filter { !tags.contains($0) } }

    static let none = TagActions()
}

/// One file's tags, as chips that can be removed, with one control that adds.
///
/// The same strip wherever a file is shown large enough to carry it, so tagging is not a
/// thing you have to know to right-click for.
struct TagStrip: View {
    let actions: TagActions
    /// Shown when there are none, so an empty strip still says what the control is for.
    var emptyLabel = "No tags"

    var body: some View {
        if actions.isAvailable {
            HStack(spacing: 6) {
                if actions.tags.isEmpty {
                    Text(emptyLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    // Wraps rather than scrolls: a file with eight tags should show eight,
                    // not hide six of them behind a swipe in a panel this narrow.
                    FlowRow(spacing: 6) {
                        ForEach(actions.tags, id: \.self) { tag in
                            TagChip(name: tag) { actions.remove(tag) }
                        }
                    }
                }
                Spacer(minLength: 0)
                addControl
            }
        }
    }

    private var addControl: some View {
        Menu {
            if actions.suggestions.isEmpty {
                Button("No other tags yet") {}.disabled(true)
            } else {
                ForEach(actions.suggestions, id: \.self) { tag in
                    Button(tag) { actions.add(tag) }
                }
            }
            Divider()
            Button("New Tag…", action: actions.new)
        } label: {
            Image(systemName: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .tip("Add a tag to this file")
    }
}

private struct TagChip: View {
    let name: String
    let remove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "tag").font(.caption2)
            Text(name).font(.caption)
            if hovering {
                Button(action: remove) { Image(systemName: "xmark").font(.caption2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .tip("Remove this tag from the file")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.55), in: Capsule())
        .onHover { hovering = $0 }
    }
}

/// A left-aligned row that wraps onto the next line when it runs out of room.
///
/// `HStack` cannot do this and a `LazyVGrid` needs a column count decided in advance,
/// which is exactly what a row of tags of different lengths does not have.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, max(widest, 0)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    /// The rows the subviews fall into at this width, as index ranges plus their size.
    /// Pure, so the wrapping itself can be checked without rendering anything.
    func arrange(subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: [Int] = []
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.isEmpty ? size.width : lineWidth + spacing + size.width
            if !current.isEmpty && needed > width {
                rows.append((current, lineWidth, lineHeight))
                current = [index]
                lineWidth = size.width
                lineHeight = size.height
            } else {
                current.append(index)
                lineWidth = needed
                lineHeight = max(lineHeight, size.height)
            }
        }
        if !current.isEmpty { rows.append((current, lineWidth, lineHeight)) }
        return rows
    }
}
