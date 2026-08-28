import SwiftUI
import AppKit

/// Settings, in a window of their own.
///
/// They were twelve buttons in a rail beside the library, which put "which folder am I
/// looking at" and "what is my API key" at the same level and gave the sidebar two jobs.
/// These are the things you set once and rarely return to; the sidebar is where you are.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, highlighters, keyboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .highlighters: return "Highlighters"
        case .keyboard: return "Keyboard"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .highlighters: return "highlighter"
        case .keyboard: return "keyboard"
        }
    }
}

struct SettingsWindowView: View {
    @AppStorage("settingsPane") private var pane: SettingsPane = .general
    @StateObject private var palette = Palette()

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(
                get: { Optional(pane) },
                set: { if let new = $0 { pane = new } }
            )) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(208)
        } detail: {
            Group {
                switch pane {
                case .general: GeneralSettings()
                case .highlighters: HighlighterSettings(palette: palette)
                case .keyboard: KeyboardSettings()
                }
            }
            .frame(minWidth: 560, minHeight: 420)
            .navigationTitle(pane.title)
        }
        .frame(minWidth: 820, minHeight: 560)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @AppStorage("appearance") private var appearance: Appearance = .system
    @AppStorage("watchSources") private var watchSources = true
    @AppStorage("autoPreview") private var autoPreview = true
    @AppStorage("viewMode") private var mode: ViewMode = .catalogue

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            }

            Section {
                Toggle("Watch the sources for changes", isOn: $watchSources)
                Toggle("Plan as soon as a source is added", isOn: $autoPreview)
                Picker("Open in", selection: $mode) {
                    ForEach(ViewMode.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Running")
            } footer: {
                Text("The watcher checks each new file against what is already known rather "
                     + "than rescanning the shelf, which is what lets it notice a copy of "
                     + "something you already own as it arrives.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Highlighters

struct HighlighterSettings: View {
    @ObservedObject var palette: Palette

    var body: some View {
        Form {
            Section {
                ForEach(Array(palette.styles.enumerated()), id: \.element.id) { index, style in
                    HStack(spacing: 10) {
                        ColorPicker("", selection: Binding(
                            get: { style.swatch },
                            set: { palette.setColour($0, on: style) }
                        ))
                        .labelsHidden()

                        TextField("", text: Binding(
                            get: { style.meaning },
                            set: { palette.setMeaning($0, on: style) }
                        ), prompt: Text("What it means"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)

                        // The number key that paints in this colour, which follows the row
                        // rather than the colour: reorder them and the keys reorder too.
                        if index < 9 {
                            Text("\(index + 1)")
                                .font(.caption2.weight(.bold).monospaced())
                                .frame(width: 16, height: 16)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: Metric.keyCap))
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            palette.remove(style)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .disabled(palette.styles.count < 2)
                        .help(palette.styles.count < 2
                              ? "The last colour stays; without one there is no highlighter"
                              : "Remove this colour")
                    }
                }

                HStack {
                    Button { palette.add() } label: {
                        Label("Add a colour", systemImage: "plus.circle")
                    }
                    .buttonStyle(.link)
                    Spacer()
                    Button("Reset to the five defaults") { palette.resetToDefaults() }
                        .buttonStyle(.link)
                }
            } header: {
                Text("Your highlighters")
            } footer: {
                Text("Shown beside the bar as you highlight and next to every mark, so the "
                     + "convention is legible where it is used rather than remembered. The "
                     + "number keys follow this order.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                ForEach(palette.styles) { style in
                    HStack(spacing: 10) {
                        Text(style.meaning.isEmpty ? "Highlight" : style.meaning)
                            .font(.system(.body, design: .serif))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(style.swatch.opacity(0.38),
                                        in: RoundedRectangle(cornerRadius: 3))
                        Spacer(minLength: 0)
                    }
                }
            } header: {
                Text("In the page")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Keyboard

/// Every command, what it answers to, and where. The list the `?` sheet used to show was
/// typed out by hand beside the monitor that actually implemented it; this one is the
/// monitor's own table, so it cannot drift, and a binding can be changed.
struct KeyboardSettings: View {
    @ObservedObject private var keymap = Keymap.shared
    @State private var filter = ""
    @State private var recording: Command?
    @State private var clash: Clash?
    @State private var monitor: Any?

    /// A key a person asked for that something else already answers to. Held rather than
    /// applied, because taking a key from another command silently is how a shortcut
    /// quietly stops working.
    struct Clash: Equatable {
        let command: Command
        let shortcut: Shortcut
        let taken: Command
    }

    private var groups: [(Command.Group, [Command])] {
        Command.Group.allCases.compactMap { group in
            let matching = Command.allCases.filter { command in
                guard command.group == group else { return false }
                guard !filter.isEmpty else { return true }
                let needle = filter.lowercased()
                return command.title.lowercased().contains(needle)
                    || (keymap.shortcut(for: command)?.display.lowercased().contains(needle) ?? false)
                    || command.scope.label.lowercased().contains(needle)
            }
            return matching.isEmpty ? nil : (group, matching)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Filter commands", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Spacer(minLength: 0)
                Button("Restore all") { keymap.resetAll() }
                    .disabled(!keymap.hasCustomisations)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            List {
                ForEach(groups, id: \.0) { group, commands in
                    Section(group.label) {
                        ForEach(commands) { command in
                            row(for: command)
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            Text("Letters work whenever a text field is not focused; anything with ⌘ works "
                 + "regardless. A command with no shortcut is still reachable — every row "
                 + "here is also a line in the command palette.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .onChange(of: recording) { startOrStopRecording() }
        .onDisappear { stopMonitoring() }
    }

    @ViewBuilder
    private func row(for command: Command) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(command.title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(command.scope.label)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 74, alignment: .leading)

                Button {
                    recording = recording == command ? nil : command
                } label: {
                    if recording == command {
                        Text("Press the keys you want…")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    } else if let shortcut = keymap.shortcut(for: command) {
                        Text(shortcut.display)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                    } else {
                        Text("unbound").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 168, alignment: .trailing)

                Button {
                    keymap.reset(command)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .opacity(keymap.isCustomised(command) ? 1 : 0)
                .help("Back to what it shipped with")
            }

            if let clash, clash.command == command {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("\(clash.shortcut.display) already means “\(clash.taken.title)”. "
                         + "Two commands cannot share a key in the same place.")
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Take it anyway") {
                        keymap.bind(clash.taken, to: nil)
                        keymap.bind(clash.command, to: clash.shortcut)
                        self.clash = nil
                    }
                    Button("Cancel") { self.clash = nil }
                }
                .font(.caption)
                .foregroundStyle(Ink.amber)
                .padding(8)
                .background(Ink.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: Metric.control))
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Recording

    private func startOrStopRecording() {
        stopMonitoring()
        guard let command = recording else { return }
        clash = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape leaves the binding alone, which is the only way out that does not
            // require choosing a key you did not want.
            if event.keyCode == 53 {
                recording = nil
                return nil
            }
            guard let typed = event.charactersIgnoringModifiers, !typed.isEmpty else { return nil }
            let shortcut = Shortcut(typed, Shortcut.Modifiers(
                event.modifierFlags.intersection(.deviceIndependentFlagsMask)))
            if let taken = keymap.conflict(for: shortcut, assigning: command) {
                clash = Clash(command: command, shortcut: shortcut, taken: taken)
            } else {
                keymap.bind(command, to: shortcut)
            }
            recording = nil
            return nil
        }
    }

    private func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
