import Foundation

/// Installing PaperShelf as a local plugin for the ChatGPT desktop app, in Swift, so
/// Settings can do it without shelling out to `Tools/install-chatgpt-plugin.sh`.
///
/// The app reads plugins from a personal marketplace at `~/.agents/plugins/marketplace.json`.
/// A plugin may declare an MCP server spoken to over stdio, which is exactly what PDF
/// Hammer already ships. Nothing here is published, reviewed, or sent anywhere; it only
/// writes files under the user's home directory that another local app reads.
///
/// The two files written into the plugin folder mirror `Plugin/papershelf/` in the repo
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
        /// directory, which is why `./plugins/papershelf` means `~/plugins/papershelf` and
        /// not a folder beside the marketplace.
        var home: URL
        var destination: URL
        var marketplace: URL
        /// Where installs before this landed: beside the marketplace, where nothing reading
        /// the entry would look for them, and under the name the app used to have. Both are
        /// cleared out on the next install, or two plugin folders are listed and one of
        /// them points at a binary that no longer exists.
        var legacyDestinations: [URL]

        init(home: URL) {
            self.home = home
            self.destination = home.appendingPathComponent("plugins/papershelf", isDirectory: true)
            self.marketplace = home.appendingPathComponent(".agents/plugins/marketplace.json")
            self.legacyDestinations = [
                home.appendingPathComponent(".agents/plugins/papershelf", isDirectory: true),
                home.appendingPathComponent("plugins/pdf-hammer", isDirectory: true),
                home.appendingPathComponent(".agents/plugins/pdf-hammer", isDirectory: true),
            ]
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
                return "No papershelf-mcp was found next to this build, so there is nothing "
                     + "for the plugin to point at. Build and install PaperShelf first."
            }
        }
    }

    // MARK: - The server to point the plugin at

    /// The MCP server sitting next to whichever binary is running right now.
    ///
    /// A release build's bundle has it at `Contents/MacOS/papershelf-mcp`, put there by
    /// `build.sh` under that fixed name so a config can survive every rebuild. That is
    /// deliberately not hardcoded as `/Applications/...`: the app is asked where it is
    /// actually running from, so a copy kept anywhere else still installs a plugin that
    /// finds its own server.
    ///
    /// A debug build launched from the command line has no such bundle -- SwiftPM just
    /// places the two executables side by side, and the server there is still named
    /// `PaperShelfMCP`, its product name, never renamed. That binary talks stdio exactly the
    /// same way, so it is tried too rather than refusing to install anything from a debug
    /// build.
    static func serverExecutableURL(ownExecutable: URL? = Bundle.main.executableURL) -> URL? {
        guard let ownExecutable else { return nil }
        let folder = ownExecutable.deletingLastPathComponent()
        for name in ["papershelf-mcp", "PaperShelfMCP"] {
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
        // An install from before the path was right, or from before the rename, left a
        // copy somewhere nothing reads. Leaving it there means two plugin folders.
        for old in paths.legacyDestinations { try? fm.removeItem(at: old) }
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
            let data = try marketplace(at: paths.marketplace, removing: "papershelf")
            try data.write(to: paths.marketplace, options: .atomic)
        }
        try? fm.removeItem(at: paths.destination)
        for old in paths.legacyDestinations { try? fm.removeItem(at: old) }
    }

    // MARK: - Marketplace merge

    private static func mergedMarketplace(at url: URL, adding entry: [String: Any]) throws -> Data {
        var market = try readMarketplace(at: url) ?? defaultMarketplace()
        var plugins = (market["plugins"] as? [[String: Any]]) ?? []
        // The entry under the old name goes with it: a marketplace listing two plugins
        // for the same app, one of them pointing at a binary that no longer exists, is
        // worse than one that lists neither.
        plugins.removeAll { ["papershelf", "pdf-hammer"].contains($0["name"] as? String ?? "") }
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
        // `./plugins/papershelf`, read from the home directory: the same convention every
        // other entry in a personal marketplace uses. `./papershelf` sent the app looking
        // in `~/papershelf`, which is nowhere, and adding the plugin failed outright.
        ["name": "papershelf",
         "source": ["source": "local", "path": "./plugins/papershelf"],
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

    // MARK: - The plugin's own files, matching Plugin/papershelf/

    /// What the marketplace listing is built from. `interface` is the half that shows: a
    /// listing with no `displayName` and no `shortDescription` renders as a bare folder
    /// name with an empty line under it, next to entries that say what they do.
    ///
    /// `appVersion` defaults to `releaseVersion`, which reads the running app's own
    /// bundle; a test passes an explicit value instead, since a test bundle has a
    /// `CFBundleShortVersionString` of its own that has nothing to do with PaperShelf's.
    static func pluginManifestData(hasLogo: Bool, installedAt: Date = Date(),
                                   appVersion: String = releaseVersion) throws -> Data {
        var interface: [String: Any] = [
            "displayName": "PaperShelf",
            "shortDescription": "Search and cite your own PDFs",
            "longDescription":
                "PaperShelf keeps an index of the papers and books on your Mac. This "
                + "plugin lets ChatGPT read it: search the whole library, or one folder, "
                + "and get back the matching passages with the page each one came from; "
                + "open a document or a single page; list what you highlighted and the "
                + "notes you left from the live PDF; poll a returned revision for new "
                + "highlights and notes; read and update highlight colors and meanings "
                + "for the library, a folder, a project, or one paper; pull a BibTeX "
                + "entry for one paper or a whole reading project; and file what you find "
                + "into projects and tags. It can also "
                + "find duplicate documents by comparing their contents, so an empty "
                + "result means no two are byte-for-byte identical, not that nothing "
                + "looks alike. Renaming files to match PaperShelf's own naming rules is "
                + "a separate capability, off until you turn it on, and it always shows "
                + "the plan before anything changes. Everything runs against the app's "
                + "own server on your machine, so the files never leave it and nothing "
                + "is uploaded. Requires PaperShelf to be installed.",
            "developerName": "PaperShelf",
            "category": "Education & Research",
            "capabilities": ["Read", "Research", "Local processing"],
            "websiteURL": "https://github.com/jonaprieto/papershelf",
            "brandColor": "#586CE8",
            "defaultPrompt": [
                "What do I have on session types? Quote the relevant passages.",
                "What did I highlight in the Milner paper?",
                "Check whether my highlights in the Milner paper changed since the last revision.",
            ],
        ]
        if hasLogo {
            interface["composerIcon"] = "./assets/logo.png"
            interface["logo"] = "./assets/logo.png"
        }
        return try serialize([
            "name": "papershelf",
            "version": cachebustedVersion(installedAt: installedAt, appVersion: appVersion),
            "description": "Ask about the PDFs on your own Mac: search them, read them, cite them.",
            "author": ["name": "PaperShelf"],
            "homepage": "https://github.com/jonaprieto/papershelf",
            "repository": "https://github.com/jonaprieto/papershelf",
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
    /// points at. A command-line build has no Info.plist to read it from, which is when the
    /// fallback below is used; it is kept equal to `paperShelfVersion` by a test, the same
    /// way the checked-in manifest is, so a debug build and a release build never disagree
    /// about what they are.
    static var releaseVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.11.4"
    }

    /// `mcpServers`, not `mcp_servers`: the plugin schema names it in camel case, and a
    /// `.mcp.json` carrying the other spelling has no servers in it as far as validation is
    /// concerned.
    static func serverManifestData(command: String) throws -> Data {
        try serialize([
            "mcpServers": [
                "papershelf": ["command": command, "args": [] as [String]],
            ],
        ])
    }

    private static func serialize(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        data.append(0x0a)
        return data
    }
}
