import SwiftUI
import AppKit
import PaperShelfCore

/// Where a highlighter's meaning and palette colour apply. Existing PDF annotations keep the
/// colour stored in the file; new marks and the notes UI use the scoped profile.
enum HighlightMeaningScope: Hashable, Identifiable {
    case library
    case document(id: String, name: String)
    case folder(path: String, name: String)
    case project(id: Int64, name: String)

    var id: String {
        switch self {
        case .library: return "library"
        case .document(let id, _): return "document:" + id
        case .folder(let path, _): return "folder:" + path
        case .project(let id, _): return "project:\(id)"
        }
    }

    var label: String {
        switch self {
        case .library: return "Whole library"
        case .document(_, let name): return name
        case .folder(_, let name): return name
        case .project(_, let name): return name
        }
    }

    var title: String {
        switch self {
        case .library: return "Whole library"
        case .document: return "This paper"
        case .folder(_, let name): return "Folder: \(name)"
        case .project(_, let name): return "Project: \(name)"
        }
    }

    fileprivate var storageKey: String { id }

    static func forDocument(_ url: URL, id: String? = nil) -> Self {
        .document(id: id ?? url.resolvingSymlinksInPath().path,
                  name: url.lastPathComponent)
    }

    static func forFolder(_ url: URL) -> Self {
        let resolved = url.resolvingSymlinksInPath()
        return .folder(path: resolved.path, name: resolved.lastPathComponent)
    }
}

/// One highlighter: a colour and what the reader takes it to mean.
struct HighlightStyle: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var red: Double
    var green: Double
    var blue: Double
    var meaning: String

    init(id: UUID = UUID(), red: Double, green: Double, blue: Double, meaning: String) {
        self.id = id
        self.red = red
        self.green = green
        self.blue = blue
        self.meaning = meaning
    }

    init(id: UUID = UUID(), color: Color, meaning: String) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .yellow
        self.init(id: id, red: Double(resolved.redComponent),
                  green: Double(resolved.greenComponent),
                  blue: Double(resolved.blueComponent), meaning: meaning)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
    }

    var swatch: Color { Color(nsColor: nsColor) }

    /// Squared distance in sRGB. Crude next to a perceptual metric, but it only has to
    /// pick the nearest of a handful of well-separated colours.
    func distance(to other: NSColor) -> Double {
        guard let target = other.usingColorSpace(.sRGB) else { return .greatestFiniteMagnitude }
        return pow(red - Double(target.redComponent), 2)
            + pow(green - Double(target.greenComponent), 2)
            + pow(blue - Double(target.blueComponent), 2)
    }
}

private extension HighlightStyle {
    init?(_ stored: HighlightProfileStyle) {
        guard let id = UUID(uuidString: stored.id) else { return nil }
        self.init(id: id, red: stored.red, green: stored.green, blue: stored.blue,
                  meaning: stored.meaning)
    }
}

/// The reader's highlighters: which colours exist, in what order, meaning what.
///
/// A colour scheme is personal, so this is a list to be edited rather than a fixed set.
/// It is stored as JSON in preferences: an array of records, not something a handful of
/// keys could hold.
@MainActor
@Observable
final class Palette {
    /// One palette, not one per window.
    ///
    /// The settings window and the reader each held their own, so adding a highlighter in
    /// Settings changed the settings window's copy, wrote it to preferences, and left the
    /// reader's copy exactly as it was: the new colour appeared in neither the toolbar's
    /// picker nor the bar over the page until the app was launched again. Both observe
    /// this one now, so a colour added is a colour available.
    static let shared = Palette()

    private(set) var styles: [HighlightStyle] = []

    private let key = "highlightPalette"
    private let scopedMeaningKey = "highlightMeaningOverrides"
    private var scopedOverrides: [String: [String: HighlightProfileOverride]] = [:]

    /// A starting point, not a claim about how anyone reads. Stable ids let the MCP process
    /// address the same highlighter without depending on a process-local UUID.
    static let defaults: [HighlightStyle] = [
        HighlightStyle(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, red: 1.00, green: 0.85, blue: 0.30, meaning: "Worth remembering"),
        HighlightStyle(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, red: 0.55, green: 0.87, blue: 0.55, meaning: "Agree, or confirmed"),
        HighlightStyle(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, red: 0.55, green: 0.78, blue: 1.00, meaning: "Definition or key term"),
        HighlightStyle(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, red: 1.00, green: 0.65, blue: 0.75, meaning: "Disagree, or doubtful"),
        HighlightStyle(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, red: 0.78, green: 0.66, blue: 1.00, meaning: "Follow up"),
    ]

    private init() {
        if !loadSharedProfile() {
            loadLegacyStyles()
            loadLegacyMeanings()
            saveProfile()
        }
    }

    private func loadSharedProfile() -> Bool {
        guard let profile = readHighlightProfile(), !profile.styles.isEmpty else { return false }
        let stored = profile.styles.compactMap(HighlightStyle.init)
        guard !stored.isEmpty else { return false }
        styles = stored
        scopedOverrides = profile.overrides
        return true
    }

    private func loadLegacyStyles() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode([HighlightStyle].self, from: data),
              !stored.isEmpty else {
            styles = Palette.defaults
            return
        }
        styles = stored
    }

    private func loadLegacyMeanings() {
        guard let data = UserDefaults.standard.data(forKey: scopedMeaningKey),
              let stored = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return }
        for (scope, meanings) in stored {
            for (id, meaning) in meanings {
                scopedOverrides[scope, default: [:]][id] = HighlightProfileOverride(meaning: meaning)
            }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(styles) else { return }
        UserDefaults.standard.set(data, forKey: key)
        saveProfile()
    }

    private func saveScopedMeanings() {
        var meanings: [String: [String: String]] = [:]
        for (scope, overrides) in scopedOverrides {
            for (id, override) in overrides {
                if let meaning = override.meaning {
                    meanings[scope, default: [:]][id] = meaning
                }
            }
        }
        guard let data = try? JSONEncoder().encode(meanings) else { return }
        UserDefaults.standard.set(data, forKey: scopedMeaningKey)
        saveProfile()
    }

    private func saveProfile() {
        let stored = styles.map {
            HighlightProfileStyle(id: $0.id.uuidString, red: $0.red, green: $0.green,
                                  blue: $0.blue, meaning: $0.meaning)
        }
        try? writeHighlightProfile(HighlightProfile(styles: stored, overrides: scopedOverrides))
    }

    /// Picks up changes made by the MCP process when a notes or settings view appears.
    func reloadSharedProfile() {
        _ = loadSharedProfile()
    }

    func add() {
        styles.append(HighlightStyle(red: 0.75, green: 0.75, blue: 0.78, meaning: ""))
        save()
    }

    /// The last one cannot be removed: with no colours there is no way to highlight, and
    /// an empty palette is a state nobody chose on purpose.
    func remove(_ style: HighlightStyle) {
        guard styles.count > 1 else { return }
        styles.removeAll { $0.id == style.id }
        save()
    }

    func setColour(_ colour: Color, on style: HighlightStyle) {
        guard let index = styles.firstIndex(where: { $0.id == style.id }) else { return }
        let updated = HighlightStyle(id: style.id, color: colour, meaning: styles[index].meaning)
        styles[index] = updated
        save()
    }

    func setColour(_ colour: Color, on style: HighlightStyle, scope: HighlightMeaningScope) {
        guard scope != .library, styles.contains(where: { $0.id == style.id }) else { return }
        let resolved = NSColor(colour).usingColorSpace(.sRGB) ?? .yellow
        var override = scopedOverrides[scope.storageKey]?[style.id.uuidString] ??
            HighlightProfileOverride()
        override.red = Double(resolved.redComponent)
        override.green = Double(resolved.greenComponent)
        override.blue = Double(resolved.blueComponent)
        update(override, for: style, in: scope)
        saveScopedMeanings()
    }

    func setMeaning(_ meaning: String, on style: HighlightStyle) {
        guard let index = styles.firstIndex(where: { $0.id == style.id }) else { return }
        styles[index].meaning = meaning
        save()
    }

    /// A paper or project can use the same colours with a different vocabulary. Empty means
    /// "inherit the library default", which makes clearing an override one edit.
    func setMeaning(_ meaning: String, on style: HighlightStyle,
                    scope: HighlightMeaningScope) {
        guard scope != .library,
              styles.contains(where: { $0.id == style.id }) else { return }
        let value = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        var override = scopedOverrides[scope.storageKey]?[style.id.uuidString] ??
            HighlightProfileOverride()
        override.meaning = value.isEmpty || value == style.meaning ? nil : value
        update(override, for: style, in: scope)
        saveScopedMeanings()
    }

    func resetMeanings(in scope: HighlightMeaningScope) {
        guard scope != .library else { return }
        scopedOverrides[scope.storageKey] = nil
        saveScopedMeanings()
    }

    /// The raw value shown while editing a scope. Empty means the scope inherits the library
    /// meaning; the effective value belongs in the reader and notes rail instead.
    func meaningOverride(for style: HighlightStyle, scope: HighlightMeaningScope) -> String {
        guard scope != .library else { return style.meaning }
        return scopedOverrides[scope.storageKey]?[style.id.uuidString]?.meaning ?? ""
    }

    func resetToDefaults() {
        styles = Palette.defaults
        save()
    }

    func styles(for scope: HighlightMeaningScope?) -> [HighlightStyle] {
        guard let scope, scope != .library else { return styles }
        return styles(for: [scope])
    }

    func styles(for scopes: [HighlightMeaningScope]) -> [HighlightStyle] {
        var result = styles
        for scope in scopes.reversed() where scope != .library {
            for index in result.indices {
                guard let override = scopedOverrides[scope.storageKey]?[result[index].id.uuidString]
                else { continue }
                result[index].red = override.red ?? result[index].red
                result[index].green = override.green ?? result[index].green
                result[index].blue = override.blue ?? result[index].blue
                result[index].meaning = override.meaning ?? result[index].meaning
            }
        }
        return result
    }

    private func update(_ override: HighlightProfileOverride, for style: HighlightStyle,
                        in scope: HighlightMeaningScope) {
        if override.isEmpty {
            scopedOverrides[scope.storageKey]?[style.id.uuidString] = nil
            if scopedOverrides[scope.storageKey]?.isEmpty == true {
                scopedOverrides[scope.storageKey] = nil
            }
        } else {
            scopedOverrides[scope.storageKey, default: [:]][style.id.uuidString] = override
        }
    }

    /// The palette entry a stored mark was painted with, or nil when it matches nothing
    /// here: files marked in other apps carry colours this palette has never held.
    func nearest(to colour: NSColor?) -> HighlightStyle? {
        guard let colour else { return nil }
        return nearest(to: colour, in: styles)
    }


    func meaning(for colour: NSColor?) -> String {
        meaning(for: colour, scope: nil)
    }

    func meaning(for colour: NSColor?, scope: HighlightMeaningScope?) -> String {
        meaning(for: colour, scopes: scope.map { [$0] } ?? [])
    }

    func meaning(for colour: NSColor?, scopes: [HighlightMeaningScope]) -> String {
        // A mark this app made carries one of these colours exactly. A mark made in
        // Preview or Skim is near one at best, and whether that near miss is worth a name
        // is the preference: turned off, only an exact colour is named.
        let limit = Prefs.shared.labelForeignMarks ? 0.02 : 0.0002
        for scope in scopes where scope != .library {
            let scopedStyles = styles(for: [scope])
            if let match = nearest(to: colour, in: scopedStyles),
               match.distance(to: colour ?? .clear) < limit {
                return match.meaning.isEmpty ? "Highlight" : match.meaning
            }
        }
        let match = nearest(to: colour)
        guard let match, match.distance(to: colour ?? .clear) < limit else { return "Highlight" }
        return meaning(for: match, scopes: scopes)
    }

    func meaning(for style: HighlightStyle, scope: HighlightMeaningScope? = nil) -> String {
        meaning(for: style, scopes: scope.map { [$0] } ?? [])
    }

    func meaning(for style: HighlightStyle, scopes: [HighlightMeaningScope]) -> String {
        for scope in scopes where scope != .library {
            if let override = scopedOverrides[scope.storageKey]?[style.id.uuidString]?.meaning {
                return override
            }
        }
        return style.meaning.isEmpty ? "Highlight" : style.meaning
    }

    private func nearest(to colour: NSColor?, in styles: [HighlightStyle]) -> HighlightStyle? {
        guard let colour else { return nil }
        return styles.min { $0.distance(to: colour) < $1.distance(to: colour) }
    }
}

/// Edits the library role list or the overrides for one paper, folder, or project.
struct HighlightMeaningEditor: View {
    let palette: Palette
    let scope: HighlightMeaningScope
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                ForEach(Array(palette.styles.enumerated()), id: \.element.id) { index, style in
                    HStack(spacing: Space.step) {
                        ColorPicker("", selection: Binding(
                            get: { effectiveStyle(for: style).swatch },
                            set: { setColour($0, for: style) }
                        ))
                        .labelsHidden()
                        .accessibilityLabel(scope == .library
                                            ? "Library colour"
                                            : "Colour override for \(scope.title)")

                        TextField(
                            "",
                            text: Binding(
                                get: { palette.meaningOverride(for: style, scope: scope) },
                                set: { setMeaning($0, for: style) }
                            ),
                            prompt: Text(scope == .library
                                         ? "What it means"
                                         : (style.meaning.isEmpty
                                            ? "Library default"
                                            : "Library: \(style.meaning)"))
                        )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)

                        if scope == .library && index < 9 {
                            Text("\(index + 1)")
                                .font(Face.mono.weight(.bold))
                                .frame(width: 16, height: 16)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: Metric.keyCap))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: Space.tight) {
                    Text(scope == .library ? "Library roles" : "\(scope.title) overrides")
                    Text(scope == .library
                         ? "Define the roles and colours available across your library."
                         : "Use the same role controls as Settings, limited to this scope.")
                        .font(Face.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Text(scope == .library
                     ? "These roles and colours are the defaults used by every paper without an override."
                     : "Blank fields inherit the library meaning. Colour wells start from the library colour and can be changed here.")
                    .font(Face.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if scope != .library {
                Section {
                    Button {
                        openLibraryRoles()
                    } label: {
                        Label("Add or remove roles in Settings", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.link)

                    Button("Reset all overrides") { palette.resetMeanings(in: scope) }
                        .buttonStyle(.link)
                } footer: {
                    Text("The library owns the role list. Add a role there, then return here to give it this scope's meaning and colour.")
                        .font(Face.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 620, minHeight: 320)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func effectiveStyle(for style: HighlightStyle) -> HighlightStyle {
        palette.styles(for: scope).first { $0.id == style.id } ?? style
    }

    private func setColour(_ colour: Color, for style: HighlightStyle) {
        if scope == .library {
            palette.setColour(colour, on: style)
        } else {
            palette.setColour(colour, on: style, scope: scope)
        }
    }

    private func setMeaning(_ meaning: String, for style: HighlightStyle) {
        if scope == .library {
            palette.setMeaning(meaning, on: style)
        } else {
            palette.setMeaning(meaning, on: style, scope: scope)
        }
    }

    private func openLibraryRoles() {
        Prefs.shared.settingsPane = .highlighters
        dismiss()
        DispatchQueue.main.async { PaletteSettings.openSettingsWindow() }
    }
}
