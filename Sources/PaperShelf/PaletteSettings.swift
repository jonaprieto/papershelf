import SwiftUI
import AppKit

/// A setting the palette can reach.
///
/// Not a `Command`: a command has a scope, a shortcut and a place in the shelf's dispatch,
/// and a preference has none of those. Fifteen more cases in that enum would each need a
/// row in the shortcut table and a line in a switch, to describe something that is really
/// just a name, a current value and one thing to do about it.
@MainActor
struct PaletteSetting: Identifiable {
    let id: String
    let title: String
    /// What it says now: "On", "Off", "Dark". Read each time, so a row shows the value the
    /// palette was opened on rather than the one it was built with.
    let value: () -> String
    /// Flipped, cycled, or handed over to the Settings window when the value is text.
    let act: () -> Void
    /// Whether acting on it opens the Settings window instead of changing anything here.
    var opensSettings = false
}

@MainActor
enum PaletteSettings {
    /// The Settings window, opened at whatever pane it was last on. The palette hands over
    /// rather than editing free text: an API key typed into a search field is an API key in
    /// a search field's history.
    static func openSettingsWindow() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    static func all() -> [PaletteSetting] {
        let prefs = Prefs.shared
        var settings: [PaletteSetting] = []

        settings.append(PaletteSetting(
            id: "settings", title: "Open Settings", value: { "in Settings" },
            act: openSettingsWindow, opensSettings: true))

        func flag(_ id: String, _ title: String,
                  _ get: @escaping () -> Bool, _ set: @escaping (Bool) -> Void) {
            settings.append(PaletteSetting(id: id, title: title,
                                           value: { get() ? "On" : "Off" },
                                           act: { set(!get()) }))
        }

        // Reading
        settings.append(PaletteSetting(
            id: "pdfAppearance", title: "PDF reading contrast",
            value: { prefs.readingAppearance.label },
            act: {
                let all = PDFReadingAppearance.allCases
                let next = (all.firstIndex(of: prefs.readingAppearance).map { $0 + 1 } ?? 0)
                    % all.count
                prefs.readingAppearance = all[next]
            }))
        flag("selectionPalette", "Show the highlighters beside a selection",
             { prefs.selectionPalette }, { prefs.selectionPalette = $0 })
        flag("labelForeignMarks", "Label marks from other apps with the nearest colour",
             { prefs.labelForeignMarks }, { prefs.labelForeignMarks = $0 })
        flag("offerChatGPT", "Offer “Open in ChatGPT” beside a highlight",
             { prefs.offerChatGPT }, { prefs.offerChatGPT = $0 })

        // The shelf
        flag("watchSources", "Watch the sources for changes",
             { prefs.watchSources }, { prefs.watchSources = $0 })
        flag("autoPreview", "Plan as soon as a source is added",
             { prefs.autoPreview }, { prefs.autoPreview = $0 })
        flag("returnAppliesRename", "Return in the name field renames the file",
             { prefs.returnAppliesRename }, { prefs.returnAppliesRename = $0 })
        flag("onlyUndecided", "Show only what is still undecided",
             { prefs.onlyUndecided }, { prefs.onlyUndecided = $0 })

        // Renaming
        flag("moveOriginals", "Keep the originals",
             { prefs.moveOriginals }, { prefs.moveOriginals = $0 })
        flag("useFolderNames", "Take a date from the folder name",
             { prefs.useFolderNames }, { prefs.useFolderNames = $0 })
        flag("useMetadataDate", "Take a date from the document's metadata",
             { prefs.useMetadataDate }, { prefs.useMetadataDate = $0 })
        flag("useFileDate", "Take a date from the file itself",
             { prefs.useFileDate }, { prefs.useFileDate = $0 })
        flag("ruleStripDiacritics", "Strip diacritics from names",
             { prefs.ruleStripDiacritics }, { prefs.ruleStripDiacritics = $0 })
        flag("ruleDropArticles", "Drop leading articles from names",
             { prefs.ruleDropArticles }, { prefs.ruleDropArticles = $0 })

        // BibTeX
        flag("bibAlign", "Align the equals signs in BibTeX",
             { prefs.bibAlign }, { prefs.bibAlign = $0 })
        flag("bibTrailingComma", "Trailing comma in BibTeX",
             { prefs.bibTrailingComma }, { prefs.bibTrailingComma = $0 })
        flag("bibSortFields", "Sort BibTeX fields alphabetically",
             { prefs.bibSortFields }, { prefs.bibSortFields = $0 })
        flag("bibOmitFile", "Omit the file field in BibTeX",
             { prefs.bibOmitFile }, { prefs.bibOmitFile = $0 })

        // Settings with a handful of values cycle through them, which is the whole editor a
        // choice of three needs.
        settings.append(PaletteSetting(
            id: "appearance", title: "Appearance",
            value: { prefs.appearance.label },
            act: {
                let all = Appearance.allCases
                let next = (all.firstIndex(of: prefs.appearance).map { $0 + 1 } ?? 0) % all.count
                prefs.appearance = all[next]
            }))

        // And the ones whose value is text open the window that can edit it properly.
        for (id, title) in [("aiModel", "AI model"), ("aiBaseURL", "AI endpoint"),
                            ("namePattern", "Naming pattern"), ("passwords", "Passwords"),
                            ("apiKey", "API key")] {
            settings.append(PaletteSetting(id: id, title: title,
                                           value: { "in Settings" },
                                           act: openSettingsWindow,
                                           opensSettings: true))
        }
        return settings
    }
}
