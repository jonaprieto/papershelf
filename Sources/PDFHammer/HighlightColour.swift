import SwiftUI
import AppKit

/// The highlighter colours, and what each one is taken to mean.
///
/// A colour scheme only works if it is remembered, so what each colour stands for is set
/// by the reader and shown on the swatch. The defaults are a starting point rather than a
/// claim about how anyone reads.
enum HighlightColour: String, CaseIterable, Identifiable, Sendable {
    case yellow, green, blue, pink, purple

    var id: String { rawValue }

    /// Muted rather than saturated: a highlight sits under text that still has to be read.
    var nsColor: NSColor {
        switch self {
        case .yellow: return NSColor(srgbRed: 1.00, green: 0.85, blue: 0.30, alpha: 1)
        case .green: return NSColor(srgbRed: 0.55, green: 0.87, blue: 0.55, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.55, green: 0.78, blue: 1.00, alpha: 1)
        case .pink: return NSColor(srgbRed: 1.00, green: 0.65, blue: 0.75, alpha: 1)
        case .purple: return NSColor(srgbRed: 0.78, green: 0.66, blue: 1.00, alpha: 1)
        }
    }

    var swatch: Color { Color(nsColor: nsColor) }

    /// The preference key holding this colour's meaning.
    var meaningKey: String { "highlightMeaning-" + rawValue }

    var defaultMeaning: String {
        switch self {
        case .yellow: return "Worth remembering"
        case .green: return "Agree, or confirmed"
        case .blue: return "Definition or key term"
        case .pink: return "Disagree, or doubtful"
        case .purple: return "Follow up"
        }
    }

    var meaning: String {
        let stored = UserDefaults.standard.string(forKey: meaningKey) ?? ""
        return stored.isEmpty ? defaultMeaning : stored
    }

    /// Which of these a stored annotation was painted with.
    ///
    /// Files marked elsewhere carry colours that are none of these, so this picks the
    /// nearest rather than refusing to show them.
    static func matching(_ colour: NSColor?) -> HighlightColour {
        guard let target = colour?.usingColorSpace(.sRGB) else { return .yellow }
        var best = HighlightColour.yellow
        var closest = Double.greatestFiniteMagnitude
        for candidate in allCases {
            guard let mine = candidate.nsColor.usingColorSpace(.sRGB) else { continue }
            let distance = pow(Double(mine.redComponent - target.redComponent), 2)
                + pow(Double(mine.greenComponent - target.greenComponent), 2)
                + pow(Double(mine.blueComponent - target.blueComponent), 2)
            if distance < closest {
                closest = distance
                best = candidate
            }
        }
        return best
    }
}
