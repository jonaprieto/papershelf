import SwiftUI
import AppKit

/// Where a highlighter's meaning applies. The PDF keeps its colour; this only changes the
/// label shown beside it and in exported notes.
enum HighlightMeaningScope: Hashable, Identifiable {
    case library
    case document(String)
    case project(id: Int64, name: String)

    var id: String {
        switch self {
        case .library: return "library"
        case .document(let path): return "document:" + path
        case .project(let id, _): return "project:\(id)"
        }
    }

    var label: String {
        switch self {
        case .library: return "Whole library"
        case .document(let path): return URL(fileURLWithPath: path).lastPathComponent
        case .project(_, let name): return name
        }
    }

    var title: String {
        switch self {
        case .library: return "Whole library"
        case .document: return "This paper"
        case .project(_, let name): return "Project: \(name)"
        }
    }

    fileprivate var storageKey: String { id }

    static func forDocument(_ url: URL) -> Self {
        .document(url.resolvingSymlinksInPath().path)
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
    private var scopedMeanings: [String: [String: String]] = [:]

    /// A starting point, not a claim about how anyone reads.
    static let defaults: [HighlightStyle] = [
        HighlightStyle(red: 1.00, green: 0.85, blue: 0.30, meaning: "Worth remembering"),
        HighlightStyle(red: 0.55, green: 0.87, blue: 0.55, meaning: "Agree, or confirmed"),
        HighlightStyle(red: 0.55, green: 0.78, blue: 1.00, meaning: "Definition or key term"),
        HighlightStyle(red: 1.00, green: 0.65, blue: 0.75, meaning: "Disagree, or doubtful"),
        HighlightStyle(red: 0.78, green: 0.66, blue: 1.00, meaning: "Follow up"),
    ]

    private init() {
        load()
        loadScopedMeanings()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode([HighlightStyle].self, from: data),
              !stored.isEmpty else {
            styles = Palette.defaults
            return
        }
        styles = stored
    }

    private func loadScopedMeanings() {
        guard let data = UserDefaults.standard.data(forKey: scopedMeaningKey),
              let stored = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return }
        scopedMeanings = stored
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(styles) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func saveScopedMeanings() {
        guard let data = try? JSONEncoder().encode(scopedMeanings) else { return }
        UserDefaults.standard.set(data, forKey: scopedMeaningKey)
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
        if value.isEmpty || value == style.meaning {
            scopedMeanings[scope.storageKey]?[style.id.uuidString] = nil
            if scopedMeanings[scope.storageKey]?.isEmpty == true {
                scopedMeanings[scope.storageKey] = nil
            }
        } else {
            scopedMeanings[scope.storageKey, default: [:]][style.id.uuidString] = value
        }
        saveScopedMeanings()
    }

    func resetMeanings(in scope: HighlightMeaningScope) {
        guard scope != .library else { return }
        scopedMeanings[scope.storageKey] = nil
        saveScopedMeanings()
    }

    func resetToDefaults() {
        styles = Palette.defaults
        save()
    }

    /// The palette entry a stored mark was painted with, or nil when it matches nothing
    /// here: files marked in other apps carry colours this palette has never held.
    func nearest(to colour: NSColor?) -> HighlightStyle? {
        guard let colour else { return nil }
        return styles.min { $0.distance(to: colour) < $1.distance(to: colour) }
    }


    func meaning(for colour: NSColor?) -> String {
        meaning(for: colour, scope: nil)
    }

    func meaning(for colour: NSColor?, scope: HighlightMeaningScope?) -> String {
        let match = nearest(to: colour)
        // A mark this app made carries one of these colours exactly. A mark made in
        // Preview or Skim is near one at best, and whether that near miss is worth a name
        // is the preference: turned off, only an exact colour is named.
        let limit = Prefs.shared.labelForeignMarks ? 0.02 : 0.0002
        guard let match, match.distance(to: colour ?? .clear) < limit else { return "Highlight" }
        return meaning(for: match, scope: scope)
    }

    func meaning(for style: HighlightStyle, scope: HighlightMeaningScope? = nil) -> String {
        if let scope, scope != .library,
           let override = scopedMeanings[scope.storageKey]?[style.id.uuidString] {
            return override
        }
        return style.meaning.isEmpty ? "Highlight" : style.meaning
    }
}

/// Edits the same meanings as Settings, but against one paper or project when requested.
struct HighlightMeaningEditor: View {
    let palette: Palette
    let scope: HighlightMeaningScope
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                ForEach(palette.styles) { style in
                    TextField(
                        style.meaning.isEmpty ? "Highlight" : style.meaning,
                        text: Binding(
                            get: { palette.meaning(for: style, scope: scope) },
                            set: { value in
                                if scope == .library { palette.setMeaning(value, on: style) }
                                else { palette.setMeaning(value, on: style, scope: scope) }
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }
            } header: {
                Text(scope.title)
            } footer: {
                Text(scope == .library
                     ? "These are the defaults used by every paper without its own meaning."
                     : "Blank fields inherit the whole-library meaning.")
                    .font(Face.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if scope != .library {
                Button("Reset this scope") { palette.resetMeanings(in: scope) }
                    .buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 360, minHeight: 240)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
