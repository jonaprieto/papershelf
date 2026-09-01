import Foundation
import PaperShelfCore

/// What the app has been told, read from the app's own preferences.
///
/// The suite name is spelled out rather than left to `UserDefaults.standard`. The app is a
/// bundle, so its `standard` resolves to `com.jonaprieto.pdfhammer`; this server is a bare
/// executable at `Contents/MacOS/papershelf-mcp` with no Info.plist of its own, so its
/// `standard` is a different domain and would silently read nothing at all. Reading works
/// across processes because the app is unsandboxed: this is a plain CFPreferences plist,
/// not an App-Group container.
enum Prefs {
    private static let defaults = UserDefaults(suiteName: "com.jonaprieto.pdfhammer")

    /// The passwords the reader has already given the app, so a document it can open is a
    /// document this server can open. Never placed in a tool result, an error message, or
    /// a line written to stderr.
    static var passwords: [String] {
        PasswordList.active(defaults?.string(forKey: "passwords") ?? "")
    }

    /// Off until the user turns it on. Nothing in this server moves a file until it is.
    /// Read here, used in Task 11 and Task 12.
    static var fileOperationsEnabled: Bool {
        defaults?.bool(forKey: "mcpFileOperations") ?? false
    }

    /// The same backup arrangement the app itself would use, so a rename done from here
    /// leaves originals exactly where a rename done there would.
    static var backup: BackupSettings {
        let custom = defaults?.string(forKey: "backupCustomPath") ?? ""
        return BackupSettings(
            enabled: defaults?.object(forKey: "moveOriginals") as? Bool ?? true,
            folderName: defaults?.string(forKey: "backupFolderName") ?? defaultBackupFolderName,
            customLocation: custom.isEmpty ? nil : URL(fileURLWithPath: custom))
    }
}
