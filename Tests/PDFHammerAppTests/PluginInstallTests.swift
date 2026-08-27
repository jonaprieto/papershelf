import XCTest
@testable import PDFHammer

/// The merge into `marketplace.json` is the part worth hammering on: it must fold a new
/// entry into whatever is already there, update rather than duplicate a listing that
/// exists, and refuse to touch a file it cannot parse. Everything here runs against a
/// scratch directory, never the real `~/.agents`.
final class PluginInstallTests: XCTestCase {

    private func scratchPaths() -> ChatGPTPlugin.Paths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfhammer-plugin-tests-\(UUID().uuidString)", isDirectory: true)
        return ChatGPTPlugin.Paths(home: root)
    }

    /// A real, always-executable file to stand in for the server: `install` only needs a
    /// path to write into `.mcp.json`, it does not itself re-validate that the path works.
    private let fakeServer = URL(fileURLWithPath: "/usr/bin/true")

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func names(_ market: [String: Any]) -> [String] {
        (market["plugins"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
    }

    // MARK: - serverExecutableURL

    func testServerURLFindsTheBundledName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let own = dir.appendingPathComponent("PDFHammer")
        let server = dir.appendingPathComponent("pdf-hammer-mcp")
        FileManager.default.createFile(atPath: server.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)

        XCTAssertEqual(ChatGPTPlugin.serverExecutableURL(ownExecutable: own)?.path, server.path)
    }

    func testServerURLFallsBackToTheDebugProductName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let own = dir.appendingPathComponent("PDFHammer")
        let server = dir.appendingPathComponent("PDFHammerMCP")
        FileManager.default.createFile(atPath: server.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)

        XCTAssertEqual(ChatGPTPlugin.serverExecutableURL(ownExecutable: own)?.path, server.path)
    }

    func testServerURLIsNilWithNeitherNameNextToIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let own = dir.appendingPathComponent("PDFHammer")

        XCTAssertNil(ChatGPTPlugin.serverExecutableURL(ownExecutable: own))
    }

    // MARK: - Install: marketplace states

    func testInstallCreatesAMarketplaceThatDoesNotExistYet() throws {
        let paths = scratchPaths()
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.marketplace.path))

        let destination = try ChatGPTPlugin.install(paths: paths, serverURL: fakeServer)

        XCTAssertEqual(destination.path, paths.destination.path)
        let market = try readJSON(paths.marketplace)
        XCTAssertEqual(names(market), ["pdf-hammer"])
        XCTAssertEqual(market["name"] as? String, "local")
    }

    func testInstallPreservesOtherPluginsAlreadyListed() throws {
        let paths = scratchPaths()
        try FileManager.default.createDirectory(at: paths.marketplace.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [String: Any] = [
            "name": "local",
            "interface": ["displayName": "Local plugins"],
            "plugins": [
                ["name": "some-other-plugin", "source": ["source": "local", "path": "./some-other-plugin"]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: existing)
        try data.write(to: paths.marketplace)

        try ChatGPTPlugin.install(paths: paths, serverURL: fakeServer)

        let market = try readJSON(paths.marketplace)
        XCTAssertEqual(Set(names(market)), ["some-other-plugin", "pdf-hammer"])
    }

    func testInstallUpdatesAnExistingListingInsteadOfDuplicatingIt() throws {
        let paths = scratchPaths()
        try FileManager.default.createDirectory(at: paths.marketplace.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [String: Any] = [
            "name": "local",
            "plugins": [
                ["name": "pdf-hammer", "source": ["source": "local", "path": "./stale-path"], "category": "Stale"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: paths.marketplace)

        try ChatGPTPlugin.install(paths: paths, serverURL: fakeServer)

        let market = try readJSON(paths.marketplace)
        XCTAssertEqual(names(market), ["pdf-hammer"], "must update in place, not add a second entry")
        let plugins = try XCTUnwrap(market["plugins"] as? [[String: Any]])
        let entry = try XCTUnwrap(plugins.first)
        XCTAssertEqual(entry["category"] as? String, "Education & Research",
                       "the stale entry must be replaced, not kept")
    }

    func testInstallLeavesUnreadableJSONUntouched() throws {
        let paths = scratchPaths()
        try FileManager.default.createDirectory(at: paths.marketplace.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("{ not json at all".utf8)
        try garbage.write(to: paths.marketplace)

        XCTAssertThrowsError(try ChatGPTPlugin.install(paths: paths, serverURL: fakeServer)) { error in
            guard case ChatGPTPlugin.InstallError.corruptMarketplace = error else {
                return XCTFail("expected corruptMarketplace, got \(error)")
            }
        }

        let unchanged = try Data(contentsOf: paths.marketplace)
        XCTAssertEqual(unchanged, garbage, "a file that could not be parsed must not be rewritten")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.destination.path),
                       "nothing should be written at all when the marketplace could not be read")
    }

    func testInstallFailsWithoutAServer() throws {
        let paths = scratchPaths()
        XCTAssertThrowsError(try ChatGPTPlugin.install(paths: paths, serverURL: nil)) { error in
            guard case ChatGPTPlugin.InstallError.serverNotFound = error else {
                return XCTFail("expected serverNotFound, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.marketplace.path))
    }

    // MARK: - The files an install actually writes

    func testInstallWritesAPluginPointingAtTheGivenServer() throws {
        let paths = scratchPaths()
        try ChatGPTPlugin.install(paths: paths, serverURL: fakeServer)

        let manifest = try readJSON(paths.destination.appendingPathComponent(".codex-plugin/plugin.json"))
        XCTAssertEqual(manifest["name"] as? String, "pdf-hammer")
        XCTAssertEqual(manifest["mcpServers"] as? String, "./.mcp.json")

        // camelCase, the spelling the plugin schema accepts. Under `mcp_servers` the file
        // parses but declares no servers at all, and the plugin installs with nothing behind
        // it.
        let server = try readJSON(paths.destination.appendingPathComponent(".mcp.json"))
        let servers = try XCTUnwrap(server["mcpServers"] as? [String: Any])
        let pdfHammer = try XCTUnwrap(servers["pdf-hammer"] as? [String: Any])
        XCTAssertEqual(pdfHammer["command"] as? String, fakeServer.path)
    }

    /// The entry's `source.path` is read from the home directory, not from beside the
    /// marketplace file. Pointing it at `./pdf-hammer` sent the app to `~/pdf-hammer` and
    /// `codex plugin add` failed with "plugin source path is not a directory".
    func testTheListedPathIsWhereThePluginActuallyLands() throws {
        let paths = scratchPaths()
        try ChatGPTPlugin.install(paths: paths, serverURL: fakeServer)

        let market = try readJSON(paths.marketplace)
        let entry = try XCTUnwrap((market["plugins"] as? [[String: Any]])?.first)
        let source = try XCTUnwrap(entry["source"] as? [String: Any])
        let listed = try XCTUnwrap(source["path"] as? String)
        XCTAssertEqual(listed, "./plugins/pdf-hammer")

        let resolved = paths.home.appendingPathComponent(String(listed.dropFirst(2)), isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: resolved.appendingPathComponent(".codex-plugin/plugin.json").path),
            "the path in the listing has to lead to the manifest that was written")
    }

    /// An install from before the path was right left a folder beside the marketplace that
    /// nothing reading the entry would look for.
    func testInstallClearsOutAPluginLeftAtTheOldPath() throws {
        let paths = scratchPaths()
        try FileManager.default.createDirectory(at: paths.legacyDestination,
                                                withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: paths.legacyDestination.appendingPathComponent("plugin.json"))

        try ChatGPTPlugin.install(paths: paths, serverURL: fakeServer)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.legacyDestination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.destination.path))
    }

    // MARK: - What the listing shows

    /// The row in the marketplace is drawn from `interface`. Without these it renders as a
    /// bare folder name with an empty line under it.
    func testTheManifestCarriesEverythingTheListingNeeds() throws {
        let paths = scratchPaths()
        try ChatGPTPlugin.install(paths: paths, serverURL: fakeServer)

        let manifest = try readJSON(paths.destination.appendingPathComponent(".codex-plugin/plugin.json"))
        let interface = try XCTUnwrap(manifest["interface"] as? [String: Any])
        for field in ["displayName", "shortDescription", "longDescription",
                      "developerName", "category"] {
            let value = interface[field] as? String
            XCTAssertFalse(value?.isEmpty ?? true, "interface.\(field) is what the listing reads")
        }
        XCTAssertEqual(interface["displayName"] as? String, "PDF Hammer",
                       "the row should say the app's name, not the folder's")
        XCTAssertFalse((interface["capabilities"] as? [String] ?? []).isEmpty)
        let prompts = try XCTUnwrap(interface["defaultPrompt"] as? [String])
        XCTAssertLessThanOrEqual(prompts.count, 3, "anything past the third is dropped")
        XCTAssertTrue(prompts.allSatisfy { $0.count <= 128 }, "a longer prompt is truncated")
    }

    /// A local plugin is cached by version, so reinstalling the same "1.2.0" over itself
    /// would leave the old name and description on screen. The install time rides along as
    /// build metadata, which semver ignores when comparing but the cache does not.
    func testEachInstallIsAVersionTheAppHasNotSeen() throws {
        let first = ChatGPTPlugin.cachebustedVersion(
            installedAt: Date(timeIntervalSince1970: 1_700_000_000), appVersion: "1.2.0")
        let second = ChatGPTPlugin.cachebustedVersion(
            installedAt: Date(timeIntervalSince1970: 1_700_000_060), appVersion: "1.2.0")

        XCTAssertEqual(first, "1.2.0+codex.20231114221320")
        XCTAssertNotEqual(first, second)
        // The plugin claims the version of the build it points at, rather than one written
        // down twice and left to drift.
        XCTAssertEqual(ChatGPTPlugin.cachebustedVersion(
            installedAt: Date(timeIntervalSince1970: 1_700_000_000), appVersion: "9.9.9"),
            "9.9.9+codex.20231114221320")
    }

    /// An icon is claimed only when one was actually copied in. A manifest pointing at a
    /// missing file fails validation outright, which is worse than having no icon.
    func testNoLogoIsClaimedWhenThereIsNoneToCopy() throws {
        let manifest = try JSONSerialization.jsonObject(
            with: ChatGPTPlugin.pluginManifestData(hasLogo: false)) as? [String: Any]
        let interface = try XCTUnwrap(manifest?["interface"] as? [String: Any])
        XCTAssertNil(interface["logo"])
        XCTAssertNil(interface["composerIcon"])

        let withLogo = try JSONSerialization.jsonObject(
            with: ChatGPTPlugin.pluginManifestData(hasLogo: true)) as? [String: Any]
        let claimed = try XCTUnwrap(withLogo?["interface"] as? [String: Any])
        XCTAssertEqual(claimed["logo"] as? String, "./assets/logo.png")
    }

    /// The copy lands where the manifest says it does, since the two are written apart.
    func testTheLogoLandsWhereTheManifestPointsAtIt() throws {
        let paths = scratchPaths()
        let source = paths.marketplace.deletingLastPathComponent().appendingPathComponent("source-logo.png")
        try FileManager.default.createDirectory(at: paths.marketplace.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not really a png".utf8).write(to: source)

        XCTAssertTrue(ChatGPTPlugin.copyLogo(into: paths.destination, source: source))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: paths.destination.appendingPathComponent("assets/logo.png").path))

        XCTAssertFalse(ChatGPTPlugin.copyLogo(into: paths.destination, source: nil),
                       "a build with no bundled icon installs without one")
    }

    func testReinstallReplacesRatherThanAccumulatesFiles() throws {
        let paths = scratchPaths()
        try ChatGPTPlugin.install(paths: paths, serverURL: fakeServer)
        // A stray leftover from some earlier, different version of the plugin.
        let stray = paths.destination.appendingPathComponent("stale-leftover.json")
        try Data().write(to: stray)

        try ChatGPTPlugin.install(paths: paths, serverURL: fakeServer)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
    }

    // MARK: - Status

    func testStatusReflectsInstallAndRemoval() throws {
        let paths = scratchPaths()
        XCTAssertFalse(ChatGPTPlugin.status(paths: paths).installed)

        try ChatGPTPlugin.install(paths: paths, serverURL: fakeServer)
        XCTAssertTrue(ChatGPTPlugin.status(paths: paths).installed)

        try ChatGPTPlugin.uninstall(paths: paths)
        XCTAssertFalse(ChatGPTPlugin.status(paths: paths).installed)
    }

    // MARK: - Uninstall

    func testUninstallRemovesTheFolderAndTheListingButNotOtherPlugins() throws {
        let paths = scratchPaths()
        try FileManager.default.createDirectory(at: paths.marketplace.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [String: Any] = [
            "name": "local",
            "plugins": [["name": "some-other-plugin", "source": ["source": "local", "path": "./x"]]],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: paths.marketplace)
        try ChatGPTPlugin.install(paths: paths, serverURL: fakeServer)

        try ChatGPTPlugin.uninstall(paths: paths)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.destination.path))
        let market = try readJSON(paths.marketplace)
        XCTAssertEqual(names(market), ["some-other-plugin"])
    }

    func testUninstallLeavesUnreadableJSONUntouched() throws {
        let paths = scratchPaths()
        try ChatGPTPlugin.install(paths: paths, serverURL: fakeServer)
        let garbage = Data("not json".utf8)
        try garbage.write(to: paths.marketplace)

        XCTAssertThrowsError(try ChatGPTPlugin.uninstall(paths: paths)) { error in
            guard case ChatGPTPlugin.InstallError.corruptMarketplace = error else {
                return XCTFail("expected corruptMarketplace, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: paths.marketplace), garbage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.destination.path),
                     "the plugin folder must be left in place when its listing could not be removed")
    }

    func testUninstallWithNoMarketplaceStillRemovesTheFolder() throws {
        let paths = scratchPaths()
        try FileManager.default.createDirectory(at: paths.destination, withIntermediateDirectories: true)

        try ChatGPTPlugin.uninstall(paths: paths)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.destination.path))
    }
}
