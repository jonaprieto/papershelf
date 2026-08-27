import SwiftUI
import AppKit

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
final class Palette: ObservableObject {
    @Published private(set) var styles: [HighlightStyle] = []

    private let key = "highlightPalette"

    /// A starting point, not a claim about how anyone reads.
    static let defaults: [HighlightStyle] = [
        HighlightStyle(red: 1.00, green: 0.85, blue: 0.30, meaning: "Worth remembering"),
        HighlightStyle(red: 0.55, green: 0.87, blue: 0.55, meaning: "Agree, or confirmed"),
        HighlightStyle(red: 0.55, green: 0.78, blue: 1.00, meaning: "Definition or key term"),
        HighlightStyle(red: 1.00, green: 0.65, blue: 0.75, meaning: "Disagree, or doubtful"),
        HighlightStyle(red: 0.78, green: 0.66, blue: 1.00, meaning: "Follow up"),
    ]

    init() { load() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode([HighlightStyle].self, from: data),
              !stored.isEmpty else {
            styles = Palette.defaults
            return
        }
        styles = stored
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(styles) else { return }
        UserDefaults.standard.set(data, forKey: key)
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
        let match = nearest(to: colour)
        guard let match, match.distance(to: colour ?? .clear) < 0.02 else { return "Highlight" }
        return match.meaning.isEmpty ? "Highlight" : match.meaning
    }
}
