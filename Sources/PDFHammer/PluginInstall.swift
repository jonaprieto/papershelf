import Foundation

/// Installing PDF Hammer as a local plugin for the ChatGPT desktop app, in Swift, so
/// Settings can do it without shelling out to `Tools/install-chatgpt-plugin.sh`.
///
/// The app reads plugins from a personal marketplace at `~/.agents/plugins/marketplace.json`.
/// A plugin may declare an MCP server spoken to over stdio, which is exactly what PDF
/// Hammer already ships. Nothing here is published, reviewed, or sent anywhere; it only
/// writes files under the user's home directory that another local app reads.
///
/// The two files written into the plugin folder mirror `Plugin/pdf-hammer/` in the repo
/// exactly (that folder is only reachable from a source checkout, not from inside a built
/// `.app`, so it cannot be copied at runtime the way the shell script copies it -- the
/// content is reproduced here instead).
enum ChatGPTPlugin {

    /// Where everything lives. A parameter everywhere rather than a global default so
    /// tests can point the whole thing at a scratch directory and never touch a real
    /// `~/.agents`.
    struct Paths {
        var agentsDirectory: URL
        var destination: URL
        var marketplace: URL

        init(agentsDirectory: URL) {
            self.agentsDirectory = agentsDirectory
            self.destination = agentsDirectory.appendingPathComponent("pdf-hammer", isDirectory: true)
            self.marketplace = agentsDirectory.appendingPathComponent("marketplace.json")
        }

        static func standard() -> Paths {
            Paths(agentsDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".agents/plugins", isDirectory: true))
        }
    }

    struct Status {
        var installed: Bool
        var destination: URL
    }

    enum InstallError: LocalizedError {
        case corruptMarketplace(URL)
        case serverNotFound

        var errorDescription: String? {
            switch self {
            case .corruptMarketplace(let url):
                return "\(url.path) is not valid JSON, so it was left alone. "
                     + "Fix or remove that file, then try again."
            case .serverNotFound:
                return "No pdf-hammer-mcp was found next to this build, so there is nothing "
                     + "for the plugin to point at. Build and install PDF Hammer.app first."
            }
        }
    }

    // MARK: - The server to point the plugin at

    /// The MCP server sitting next to whichever binary is running right now.
    ///
    /// A release build's bundle has it at `Contents/MacOS/pdf-hammer-mcp`, put there by
    /// `build.sh` under that fixed name so a config can survive every rebuild. That is
    /// deliberately not hardcoded as `/Applications/...`: the app is asked where it is
    /// actually running from, so a copy kept anywhere else still installs a plugin that
    /// finds its own server.
    ///
    /// A debug build launched from the command line has no such bundle -- SwiftPM just
    /// places the two executables side by side, and the server there is still named
    /// `PDFHammerMCP`, its product name, never renamed. That binary talks stdio exactly the
    /// same way, so it is tried too rather than refusing to install anything from a debug
    /// build.
    static func serverExecutableURL(ownExecutable: URL? = Bundle.main.executableURL) -> URL? {
        guard let ownExecutable else { return nil }
        let folder = ownExecutable.deletingLastPathComponent()
        for name in ["pdf-hammer-mcp", "PDFHammerMCP"] {
            let candidate = folder.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Status

    static func status(paths: Paths = .standard()) -> Status {
        Status(installed: FileManager.default.fileExists(atPath: paths.destination.path),
               destination: paths.destination)
    }

    // MARK: - Install

    /// Writes the plugin into place and lists it in the marketplace.
    ///
    /// The marketplace is read and validated before anything is written to disk: if it
    /// exists but is not JSON this reads as an object, the whole call throws and nothing
    /// changes, rather than risking a plugin folder that got copied in with no matching
    /// listing, or a marketplace that lost whatever else it had in it.
    @discardableResult
    static func install(paths: Paths = .standard(), serverURL: URL? = serverExecutableURL()) throws -> URL {
        guard let serverURL else { throw InstallError.serverNotFound }
        let marketplaceData = try mergedMarketplace(at: paths.marketplace, adding: pluginEntry())

        let fm = FileManager.default
        try fm.createDirectory(at: paths.agentsDirectory, withIntermediateDirectories: true)
        // A previous install may have left a different set of files behind; starting clean
        // matches what the shell script does with `rm -rf` before its own copy.
        try? fm.removeItem(at: paths.destination)
        let codexPluginDir = paths.destination.appendingPathComponent(".codex-plugin", isDirectory: true)
        try fm.createDirectory(at: codexPluginDir, withIntermediateDirectories: true)
        try pluginManifestData().write(to: codexPluginDir.appendingPathComponent("plugin.json"))
        try serverManifestData(command: serverURL.path).write(to: paths.destination.appendingPathComponent(".mcp.json"))
        try marketplaceData.write(to: paths.marketplace, options: .atomic)

        return paths.destination
    }

    /// Removes the plugin folder and its marketplace listing, leaving any other plugins
    /// listed there untouched. Same rule as install: an unreadable marketplace stops the
    /// whole thing before anything is removed.
    static func uninstall(paths: Paths = .standard()) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.marketplace.path) {
            let data = try marketplace(at: paths.marketplace, removing: "pdf-hammer")
            try data.write(to: paths.marketplace, options: .atomic)
        }
        try? fm.removeItem(at: paths.destination)
    }

    // MARK: - Marketplace merge

    private static func mergedMarketplace(at url: URL, adding entry: [String: Any]) throws -> Data {
        var market = try readMarketplace(at: url) ?? defaultMarketplace()
        var plugins = (market["plugins"] as? [[String: Any]]) ?? []
        plugins.removeAll { ($0["name"] as? String) == "pdf-hammer" }
        plugins.append(entry)
        market["plugins"] = plugins
        return try serialize(market)
    }

    private static func marketplace(at url: URL, removing name: String) throws -> Data {
        var market = try readMarketplace(at: url) ?? defaultMarketplace()
        var plugins = (market["plugins"] as? [[String: Any]]) ?? []
        plugins.removeAll { ($0["name"] as? String) == name }
        market["plugins"] = plugins
        return try serialize(market)
    }

    /// `nil` means the file does not exist yet, which is fine -- a fresh marketplace is
    /// created. Anything that exists but does not parse as a JSON object throws instead of
    /// being silently treated as empty, which would erase whatever plugins it already listed.
    private static func readMarketplace(at url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.corruptMarketplace(url)
        }
        return object
    }

    private static func defaultMarketplace() -> [String: Any] {
        ["name": "local", "interface": ["displayName": "Local plugins"], "plugins": [] as [[String: Any]]]
    }

    private static func pluginEntry() -> [String: Any] {
        ["name": "pdf-hammer",
         "source": ["source": "local", "path": "./pdf-hammer"],
         "policy": ["installation": "AVAILABLE"],
         "category": "Productivity"]
    }

    // MARK: - The plugin's own files, matching Plugin/pdf-hammer/

    private static func pluginManifestData() throws -> Data {
        try serialize([
            "name": "pdf-hammer",
            "version": "1.1.0",
            "description": "Read your PDF library: search it, read a document as Markdown, "
                          + "and see what you highlighted.",
            "author": ["name": "PDF Hammer"],
            "keywords": ["pdf", "research", "bibliography", "highlights"],
            "mcpServers": "./.mcp.json",
        ])
    }

    private static func serverManifestData(command: String) throws -> Data {
        try serialize([
            "mcp_servers": [
                "pdf-hammer": ["command": command, "args": [] as [String]],
            ],
        ])
    }

    private static func serialize(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        data.append(0x0a)
        return data
    }
}
