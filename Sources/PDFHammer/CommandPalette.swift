import SwiftUI
import AppKit
import PDFHammerCore

/// One field that reaches everything: the files in front of you and every command the app
/// has, including the ones with no shortcut.
///
/// The point is not speed for people who already know the keys — they have the keys. It is
/// that a command with no binding stops being unreachable without a mouse, which is what
/// made naming all of them in one table worth doing.
struct CommandPalette: View {
    /// Commands the presenting surface can actually carry out — see
    /// `ResultsPane.performable`. Passed in rather than read from `Command.allCases`, so
    /// the palette never offers a line that would do nothing.
    let commands: [Command]
    let documents: [Item]
    let run: (Command) -> Void
    let open: (Item) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var index = 0
    @FocusState private var fieldFocused: Bool

    enum Entry: Identifiable {
        case command(Command)
        case document(Item)

        var id: String {
            switch self {
            case .command(let c): return "c:" + c.rawValue
            case .document(let item): return "d:" + item.key
            }
        }
    }

    /// `>` narrows to commands, the way a person who has used one of these before will
    /// expect. Everything else searches both.
    private var commandsOnly: Bool { query.hasPrefix(">") }

    private var needle: String {
        (commandsOnly ? String(query.dropFirst()) : query)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    private var matchingCommands: [Command] {
        guard !needle.isEmpty || commandsOnly else { return [] }
        return commands.filter {
            needle.isEmpty || $0.title.lowercased().contains(needle)
        }
        .prefix(8).map { $0 }
    }

    private var matchingDocuments: [Item] {
        guard !commandsOnly, !needle.isEmpty else { return [] }
        return documents.filter {
            $0.destinationName.lowercased().contains(needle)
                || $0.source.lastPathComponent.lowercased().contains(needle)
        }
        .prefix(8).map { $0 }
    }

    private var entries: [Entry] {
        matchingDocuments.map(Entry.document) + matchingCommands.map(Entry.command)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: commandsOnly ? "chevron.right" : "magnifyingglass")
                    .foregroundStyle(commandsOnly ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                TextField("", text: $query, prompt: Text("Search files, or type > for commands"))
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit(runSelected)
                Text("\(documents.count) files · \(commands.count) commands")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()

            if entries.isEmpty {
                Text(needle.isEmpty
                     ? "Type to search. > lists every command, whether or not it has a key."
                     : "Nothing matches “\(needle)”.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { position, entry in
                            row(entry, selected: position == index)
                                .contentShape(Rectangle())
                                .onTapGesture { index = position; runSelected() }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 340)
            }

            Divider()

            HStack(spacing: 12) {
                hint("↩", "run")
                hint("↑↓", "move")
                hint("⎋", "close")
                Spacer()
                Text("Every command is here, with or without a shortcut")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 620)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { index = 0 }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    @ViewBuilder
    private func row(_ entry: Entry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            switch entry {
            case .document(let item):
                Image(systemName: "doc.text")
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                Text(item.destinationName).lineLimit(1)
                Spacer(minLength: 8)
                Text(item.root.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
            case .command(let command):
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                Text(command.title).lineLimit(1)
                Spacer(minLength: 8)
                Text(command.scope.label)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
                if let shortcut = Keymap.shared.shortcut(for: command) {
                    Text(shortcut.display)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? Color.accentColor : .clear,
                    in: RoundedRectangle(cornerRadius: Metric.control))
        .foregroundStyle(selected ? Color.white : Color.primary)
    }

    private func hint(_ key: String, _ meaning: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: Metric.keyCap))
            Text(meaning)
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !entries.isEmpty else { return .ignored }
        index = min(max(index + delta, 0), entries.count - 1)
        return .handled
    }

    private func runSelected() {
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        // Dismiss first: a command that opens a sheet of its own cannot do it from
        // underneath this one.
        dismiss()
        switch entry {
        case .command(let command): run(command)
        case .document(let item): open(item)
        }
    }
}
