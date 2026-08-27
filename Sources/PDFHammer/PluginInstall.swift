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
        /// What a marketplace entry's relative `source.path` is read against. The file sits
        /// at `~/.agents/plugins/marketplace.json`, but its paths resolve from the home
        /// directory, which is why `./plugins/pdf-hammer` means `~/plugins/pdf-hammer` and
        /// not a folder beside the marketplace.
        var home: URL
        var destination: URL
        var marketplace: URL
        /// Where installs before this landed, beside the marketplace, where nothing reading
        /// the entry would look for them. Cleared out on the next install.
        var legacyDestination: URL

        init(home: URL) {
            self.home = home
            self.destination = home.appendingPathComponent("plugins/pdf-hammer", isDirectory: true)
            self.marketplace = home.appendingPathComponent(".agents/plugins/marketplace.json")
            self.legacyDestination = home
                .appendingPathComponent(".agents/plugins/pdf-hammer", isDirectory: true)
        }

        static func standard() -> Paths {
            Paths(home: FileManager.default.homeDirectoryForCurrentUser)
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
        try fm.createDirectory(at: paths.marketplace.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        // An install from before the path was right left a copy beside the marketplace.
        // Leaving it there means two plugin folders and one of them unreachable.
        try? fm.removeItem(at: paths.legacyDestination)
        // A previous install may have left a different set of files behind; starting clean
        // matches what the shell script does with `rm -rf` before its own copy.
        try? fm.removeItem(at: paths.destination)
        let codexPluginDir = paths.destination.appendingPathComponent(".codex-plugin", isDirectory: true)
        try fm.createDirectory(at: codexPluginDir, withIntermediateDirectories: true)
        // The listing shows the icon the manifest points at, and a manifest pointing at a
        // file that is not there is worse than one with no icon: copy first, and only claim
        // the asset if the copy actually landed. A command-line debug build has no bundle to
        // copy it from, which is why this is allowed to come up empty.
        let logo = copyLogo(into: paths.destination)
        try pluginManifestData(hasLogo: logo).write(to: codexPluginDir.appendingPathComponent("plugin.json"))
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
        try? fm.removeItem(at: paths.legacyDestination)
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
        // `./plugins/pdf-hammer`, read from the home directory: the same convention every
        // other entry in a personal marketplace uses. `./pdf-hammer` sent the app looking
        // in `~/pdf-hammer`, which is nowhere, and adding the plugin failed outright.
        ["name": "pdf-hammer",
         "source": ["source": "local", "path": "./plugins/pdf-hammer"],
         "policy": ["installation": "AVAILABLE", "authentication": "ON_INSTALL"],
         "category": "Education & Research"]
    }

    /// Copies the icon out of the app bundle and into the plugin's own `assets/`, since the
    /// listing can only show a file that lives inside the plugin. Returns whether it is
    /// there to be pointed at.
    static func copyLogo(into destination: URL,
                         source: URL? = Bundle.main.url(forResource: "PluginLogo", withExtension: "png")) -> Bool {
        guard let source else { return false }
        let assets = destination.appendingPathComponent("assets", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: assets.appendingPathComponent("logo.png"))
            return true
        } catch {
            return false
        }
    }

    // MARK: - The plugin's own files, matching Plugin/pdf-hammer/

    /// What the marketplace listing is built from. `interface` is the half that shows: a
    /// listing with no `displayName` and no `shortDescription` renders as a bare folder
    /// name with an empty line under it, next to entries that say what they do.
    static func pluginManifestData(hasLogo: Bool, installedAt: Date = Date()) throws -> Data {
        var interface: [String: Any] = [
            "displayName": "PDF Hammer",
            "shortDescription": "Search and cite your own PDFs",
            "longDescription":
                "PDF Hammer keeps a local index of the papers and books on your Mac. This "
                + "plugin lets ChatGPT read it: search by title, author or full text, open a "
                + "document or a single page as Markdown, list what you highlighted and the "
                + "notes you left, pull a BibTeX entry, find duplicate copies of the same "
                + "work, and browse your tags and reading projects. Everything runs against "
                + "the app's own MCP server on your machine, so the files never leave it and "
                + "nothing is uploaded. Requires PDF Hammer to be installed.",
            "developerName": "PDF Hammer",
            "category": "Education & Research",
            "capabilities": ["Read", "Research", "Local processing"],
            "websiteURL": "https://github.com/jonaprieto/pdf-hammer",
            "brandColor": "#586CE8",
            "defaultPrompt": [
                "What did I highlight in the Milner paper?",
                "Find the papers I have on session types",
                "Give me a BibTeX entry for this book",
            ],
        ]
        if hasLogo {
            interface["composerIcon"] = "./assets/logo.png"
            interface["logo"] = "./assets/logo.png"
        }
        return try serialize([
            "name": "pdf-hammer",
            "version": cachebustedVersion(installedAt: installedAt),
            "description": "Ask about the PDFs on your own Mac: search them, read them, cite them.",
            "author": ["name": "PDF Hammer"],
            "homepage": "https://github.com/jonaprieto/pdf-hammer",
            "repository": "https://github.com/jonaprieto/pdf-hammer",
            "keywords": ["pdf", "research", "papers", "books", "bibliography",
                         "highlights", "bibtex", "library"],
            "mcpServers": "./.mcp.json",
            "interface": interface,
        ])
    }

    /// The version, with the moment of the install as semver build metadata.
    ///
    /// A local plugin is read once and cached by version. Reinstalling the same "1.2.0" over
    /// itself leaves the old name, description and icon on screen, which is exactly the loop
    /// this is meant to close: every install is a version the app has not seen before.
    /// Build metadata is ignored when versions are compared, so this is a cache key and not
    /// a version bump.
    static func cachebustedVersion(installedAt: Date, appVersion: String = releaseVersion) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(identifier: "UTC")
        stamp.dateFormat = "yyyyMMddHHmmss"
        return "\(appVersion)+codex.\(stamp.string(from: installedAt))"
    }

    /// The app's own version, so the plugin cannot claim a different one than the build it
    /// points at. A command-line build has no Info.plist to read it from.
    static var releaseVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.0"
    }

    /// `mcpServers`, not `mcp_servers`: the plugin schema names it in camel case, and a
    /// `.mcp.json` carrying the other spelling has no servers in it as far as validation is
    /// concerned.
    static func serverManifestData(command: String) throws -> Data {
        try serialize([
            "mcpServers": [
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
