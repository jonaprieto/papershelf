import AppKit
import Foundation
import PaperShelfCore

/// The small, semantic AppleScript surface. UI scripting remains the right tool for
/// clicking a particular control; these commands are the stable app-level operations that
/// scripts, Shortcuts, and test harnesses should not have to find by coordinates.
@objc(PaperShelfScriptCommand)
final class PaperShelfScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let name = commandDescription.commandName
        let argument = directParameter as? String
        return onMain { [self] in
            switch name {
            case "choose theme": return chooseTheme(argument)
            case "choose PDF contrast": return chooseContrast(argument)
            case "current theme": return Prefs.shared.appearance.label
            case "current PDF contrast": return Prefs.shared.readingAppearance.label
            case "show catalogue": return showCatalogue()
            case "show settings":
                PaletteSettings.openSettingsWindow()
                return true
            case "show notes":
                post(.scriptShowNotes)
                return true
            case "toggle sidebar":
                post(.scriptToggleSidebar)
                return true
            case "toggle inspector":
                Prefs.shared.inspectorCollapsed.toggle()
                return true
            case "toggle reading mode":
                post(.scriptToggleReading)
                return true
            case "toggle zen mode":
                post(.scriptToggleZen)
                return true
            case "open command palette":
                post(.scriptOpenCommandPalette)
                return true
            case "copy current citation":
                post(.scriptCopyCitation)
                return true
            case "bookmark current page":
                post(.scriptAddBookmark)
                return true
            case "remove current bookmark":
                post(.scriptRemoveBookmark)
                return true
            case "show bookmarks":
                post(.scriptShowBookmarks)
                return true
            case "show diagnostics log":
                return AppDiagnostics.shared.url.path
            case "version":
                return paperShelfVersion
            default:
                return fail("PaperShelf does not implement the command \(name).")
            }
        }
    }

    @MainActor
    private func chooseTheme(_ argument: String?) -> Any? {
        switch argument?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "system": Prefs.shared.appearance = .system
        case "light": Prefs.shared.appearance = .light
        case "dark": Prefs.shared.appearance = .dark
        default: return fail("Theme must be system, light, or dark.")
        }
        return Prefs.shared.appearance.label
    }

    @MainActor
    private func chooseContrast(_ argument: String?) -> Any? {
        let value = argument?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        // Read off the labels the menu shows rather than a list kept beside them: a
        // contrast that can be chosen in the app can always be named here. The two hyphen
        // and short spellings stay because scripts already use them.
        let named = PDFReadingAppearance.allCases.first { $0.label.lowercased() == value }
        let older: [String: PDFReadingAppearance] = [
            "tint": .tint, "white-on-black": .whiteOnBlack,
        ]
        guard let mode = named ?? older[value] else {
            let names = PDFReadingAppearance.allCases.map { $0.label.lowercased() }
            return fail("PDF contrast must be one of: \(names.joined(separator: ", ")).")
        }
        Prefs.shared.readingAppearance = mode
        return Prefs.shared.readingAppearance.label
    }

    @MainActor
    private func showCatalogue() -> Any? {
        AppDelegate.current?.wantsLibrary = true
        post(.showShelfInCatalogue, userInfo: ["shelf": SmartList.all.rawValue])
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.title == "PaperShelf"
            || window.title.hasPrefix("All Documents") {
            window.makeKeyAndOrderFront(nil)
            break
        }
        return true
    }

    @MainActor
    private func post(_ name: Notification.Name, userInfo: [AnyHashable: Any]? = nil) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
    }

    @MainActor
    private func fail(_ message: String) -> Any? {
        scriptErrorNumber = NSArgumentsWrongScriptError
        scriptErrorString = message
        return nil
    }

    private func onMain(_ action: @escaping @MainActor () -> Any?) -> Any? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(action)
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated(action)
        }
    }
}
