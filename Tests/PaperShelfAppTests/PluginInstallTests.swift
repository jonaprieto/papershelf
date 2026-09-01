import XCTest
@testable import PaperShelf
import PaperShelfCore

/// The merge into `marketplace.json` is the part worth hammering on: it must fold a new
/// entry into whatever is already there, update rather than duplicate a listing that
/// exists, and refuse to touch a file it cannot parse. Everything here runs against a
/// scratch directory, never the real `~/.agents`.
final class PluginInstallTests: XCTestCase {

    /// The repository root, found from this file rather than from the working directory,
    /// which is wherever the test runner happens to have started.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)          // .../Tests/PaperShelfAppTests/PluginInstallTests.swift
            .deletingLastPathComponent()          // .../Tests/PaperShelfAppTests
            .deletingLastPathComponent()          // .../Tests
            .deletingLastPathComponent()          // repository root
    }

    private func scratchPaths() -> ChatGPTPlugin.Paths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("papershelf-plugin-tests-\(UUID().uuidString)", isDirectory: true)
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
        let own = dir.appendingPathComponent("PaperShelf")
        let server = dir.appendingPathComponent("papershelf-mcp")
        FileManager.default.createFile(atPath: server.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)

        XCTAssertEqual(ChatGPTPlugin.serverExecutableURL(ownExecutable: own)?.path, server.path)
    }

    func testServerURLFallsBackToTheDebugProductName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let own = dir.appendingPathComponent("PaperShelf")
        let server = dir.appendingPathComponent("PaperShelfMCP")
        FileManager.default.createFile(atPath: server.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)

        XCTAssertEqual(ChatGPTPlugin.serverExecutableURL(ownExecutable: own)?.path, server.path)
    }

    func testServerURLIsNilWithNeitherNameNextToIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let own = dir.appendingPathComponent("PaperShelf")

        XCTAssertNil(ChatGPTPlugin.serverExecutableURL(ownExecutable: own))
    }

    // MARK: - Install: marketplace states

    func testInstallCreatesAMarketplaceThatDoesNotExistYet() throws {
        let paths = scratchPaths()
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.marketplace.path))

        let destination = try ChatGPTPlugin.install(paths: paths, serverURL: fakeServer)

        XCTAssertEqual(destination.path, paths.destination.path)
        let market = try readJSON(paths.marketplace)
        XCTAssertEqual(names(market), ["papershelf"])
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
        XCTAssertEqual(Set(names(market)), ["some-other-plugin", "papershelf"])
    }

    func testInstallUpdatesAnExistingListingInsteadOfDuplicatingIt() throws {
        let paths = scratchPaths()
        try FileManager.default.createDirectory(at: paths.marketplace.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [String: Any] = [
            "name": "local",
            "plugins": [
                ["name": "papershelf", "source": ["source": "local", "path": "./stale-path"], "category": "Stale"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: paths.marketplace)

        try ChatGPTPlugin.install(paths: paths, serverURL: fakeServer)

        let market = try readJSON(paths.marketplace)
        XCTAssertEqual(names(market), ["papershelf"], "must update in place, not add a second entry")
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
        XCTAssertEqual(manifest["name"] as? String, "papershelf")
        XCTAssertEqual(manifest["mcpServers"] as? String, "./.mcp.json")

        // camelCase, the spelling the plugin schema accepts. Under `mcp_servers` the file
        // parses but declares no servers at all, and the plugin installs with nothing behind
        // it.
        let server = try readJSON(paths.destination.appendingPathComponent(".mcp.json"))
        let servers = try XCTUnwrap(server["mcpServers"] as? [String: Any])
        let pdfHammer = try XCTUnwrap(servers["papershelf"] as? [String: Any])
        XCTAssertEqual(pdfHammer["command"] as? String, fakeServer.path)
    }

    /// The entry's `source.path` is read from the home directory, not from beside the
    /// marketplace file. Pointing it at `./papershelf` sent the app to `~/papershelf` and
    /// `codex plugin add` failed with "plugin source path is not a directory".
    func testTheListedPathIsWhereThePluginActuallyLands() throws {
        let paths = scratchPaths()
        try ChatGPTPlugin.install(paths: paths, serverURL: fakeServer)

        let market = try readJSON(paths.marketplace)
        let entry = try XCTUnwrap((market["plugins"] as? [[String: Any]])?.first)
        let source = try XCTUnwrap(entry["source"] as? [String: Any])
        let listed = try XCTUnwrap(source["path"] as? String)
        XCTAssertEqual(listed, "./plugins/papershelf")

        let resolved = paths.home.appendingPathComponent(String(listed.dropFirst(2)), isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: resolved.appendingPathComponent(".codex-plugin/plugin.json").path),
            "the path in the listing has to lead to the manifest that was written")
    }

    /// An install from before the path was right left a folder beside the marketplace that
    /// nothing reading the entry would look for, and an install from before the rename left
    /// one under the old name. Both are cleared, or the listing shows two plugins for one
    /// app and one of them points at a binary that is gone.
    func testInstallClearsOutPluginsLeftAtOldPathsAndOldNames() throws {
        let paths = scratchPaths()
        for old in paths.legacyDestinations {
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: old.appendingPathComponent("plugin.json"))
        }

        try ChatGPTPlugin.install(paths: paths, serverURL: fakeServer)

        for old in paths.legacyDestinations {
            XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), old.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.destination.path))
    }

    /// The same for the listing itself: the entry the old name wrote has to go, not be
    /// left beside the new one.
    func testInstallReplacesAListingWrittenUnderTheOldName() throws {
        let paths = scratchPaths()
        let stale: [String: Any] = [
            "plugins": [["name": "pdf-hammer", "source": ["path": "./plugins/pdf-hammer"]]],
        ]
        try FileManager.default.createDirectory(
            at: paths.marketplace.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: stale).write(to: paths.marketplace)

        try ChatGPTPlugin.install(paths: paths, serverURL: fakeServer)

        let listed = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.marketplace))
        let plugins = ((listed as? [String: Any])?["plugins"] as? [[String: Any]]) ?? []
        XCTAssertEqual(plugins.compactMap { $0["name"] as? String }, ["papershelf"])
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
        XCTAssertEqual(interface["displayName"] as? String, "PaperShelf",
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

    // MARK: - Fidelity to Plugin/papershelf/

    /// `pluginManifestData` reproduces `Plugin/papershelf/.codex-plugin/plugin.json` in
    /// Swift, because a built `.app` has no source checkout to copy the real file from at
    /// install time. The two drifted apart once already -- 1.1.0 in one, 1.2.3 in the
    /// other -- with nothing to catch it. This reads the checked-in file and holds the
    /// Swift copy to it, field for field.
    func testTheSwiftManifestMatchesTheCheckedInOne() throws {
        let repoManifest = try readJSON(repositoryRoot
            .appendingPathComponent("Plugin/papershelf/.codex-plugin/plugin.json"))

        // `appVersion` is given explicitly as `paperShelfVersion` rather than left at its
        // default: the default reads the running app's own bundle, and in a test bundle
        // that reports the test runner's own version, not PaperShelf's. `paperShelfVersion`
        // is the constant a separate test holds Resources/Info.plist to, so passing it here
        // is what actually chains this manifest's version to the one place it is written.
        var swiftManifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: ChatGPTPlugin.pluginManifestData(hasLogo: true,
                                                    installedAt: Date(timeIntervalSince1970: 0),
                                                    appVersion: paperShelfVersion))
            as? [String: Any])

        // The Swift copy stamps every install with the moment it happened, as semver build
        // metadata, so a local plugin is never read by ChatGPT as a version it has already
        // cached. The checked-in file names no such moment; only the released version ahead
        // of the "+" has to agree with it.
        let stamped = try XCTUnwrap(swiftManifest["version"] as? String)
        let released = String(stamped.split(separator: "+", maxSplits: 1)[0])
        XCTAssertEqual(released, paperShelfVersion,
                       "the plugin must claim the version this build actually is")
        XCTAssertEqual(released, repoManifest["version"] as? String,
                       "Plugin/papershelf/.codex-plugin/plugin.json has drifted from "
                       + "paperShelfVersion")
        swiftManifest["version"] = repoManifest["version"]

        let canonical = { (object: [String: Any]) in
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        XCTAssertEqual(try canonical(swiftManifest), try canonical(repoManifest),
                       "PluginInstall.swift has drifted from "
                       + "Plugin/papershelf/.codex-plugin/plugin.json")
    }

    func testUninstallWithNoMarketplaceStillRemovesTheFolder() throws {
        let paths = scratchPaths()
        try FileManager.default.createDirectory(at: paths.destination, withIntermediateDirectories: true)

        try ChatGPTPlugin.uninstall(paths: paths)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.destination.path))
    }
}
