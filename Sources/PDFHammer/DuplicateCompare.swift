import SwiftUI
import PDFHammerCore

/// Two copies of the same book, side by side, in the pane where you are already looking.
///
/// Choosing between two copies means seeing them beside each other and beside what differs,
/// and until now that meant a whole separate window that only ever opened from a watcher
/// notification — so the duplicates view itself, the screen whose entire job is this
/// decision, offered no way to make it except by name and size in a list.
struct DuplicateCompare: View {
    let group: DuplicateGroup
    let keep: (Item) -> Void
    let trashExtras: () -> Void

    /// The fields worth comparing, and how to read each off an item. Anything the two
    /// copies disagree about is what the decision turns on, so it is marked.
    private var rows: [(label: String, values: [String])] {
        [
            ("Where", group.items.map { $0.root.lastPathComponent }),
            ("Folder", group.items.map { ($0.relativePath as NSString).deletingLastPathComponent }),
            ("Size", group.items.map { byteText($0.byteCount) }),
            ("Pages", group.items.map { $0.pageCount.map(String.init) ?? "—" }),
            ("Security", group.items.map { $0.status == .locked ? "locked" : "opens" }),
            ("Modified", group.items.map { dateText($0.modifiedDate) }),
        ]
    }

    private func byteText(_ bytes: Int?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(group.items.enumerated()), id: \.element.key) { index, item in
                            column(item, isKeeper: index == 0)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows, id: \.label) { row in
                            let differs = Set(row.values).count > 1
                            HStack(alignment: .top, spacing: 12) {
                                Text(row.label)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 68, alignment: .leading)
                                ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                                    Text(value)
                                        .font(.caption)
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .background(differs ? Ink.amber.opacity(0.10) : .clear,
                                        in: RoundedRectangle(cornerRadius: Metric.control))
                        }
                    }
                }
                .padding(14)
            }

            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Text(group.keeper.destinationName)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            claim
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var claim: some View {
        let text: String
        let colour: Color
        switch group.kind {
        case .identical: text = "Identical bytes"; colour = Ink.red
        case .sameText: text = "Same opening pages"; colour = Ink.amber
        case .likely: text = "Similar names"; colour = Ink.grey
        }
        return Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .fittedBackground(colour.opacity(Ink.fill), in: Capsule())
            .foregroundStyle(colour)
    }

    private func column(_ item: Item, isKeeper: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: isKeeper ? "star.fill" : "star")
                    .foregroundStyle(isKeeper ? Ink.green : .tertiary)
                Text(isKeeper ? "Keeping this one" : "Would go to the Trash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isKeeper ? Ink.green : .secondary)
            }
            Text(item.sourceName)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
            if !isKeeper {
                Button("Keep this one instead") { keep(item) }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(isKeeper ? Ink.green.opacity(0.07) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Metric.card))
        .overlay(
            RoundedRectangle(cornerRadius: Metric.card)
                .stroke(isKeeper ? Ink.green.opacity(0.45) : Color.secondary.opacity(0.18),
                        lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(role: .destructive) { trashExtras() } label: {
                Label("Trash the other \(group.extras.count)", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(Ink.red)
            .disabled(group.extras.isEmpty)

            Spacer(minLength: 0)
            Text("To the Trash on apply, never an outright removal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
