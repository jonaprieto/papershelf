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
        return ChatGPTPlugin.Paths(agentsDirectory: root)
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
        try FileManager.default.createDirectory(at: paths.agentsDirectory, withIntermediateDirectories: true)
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
        try FileManager.default.createDirectory(at: paths.agentsDirectory, withIntermediateDirectories: true)
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
        XCTAssertEqual(entry["category"] as? String, "Productivity", "the stale entry must be replaced, not kept")
    }

    func testInstallLeavesUnreadableJSONUntouched() throws {
        let paths = scratchPaths()
        try FileManager.default.createDirectory(at: paths.agentsDirectory, withIntermediateDirectories: true)
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

        let server = try readJSON(paths.destination.appendingPathComponent(".mcp.json"))
        let servers = try XCTUnwrap(server["mcp_servers"] as? [String: Any])
        let pdfHammer = try XCTUnwrap(servers["pdf-hammer"] as? [String: Any])
        XCTAssertEqual(pdfHammer["command"] as? String, fakeServer.path)
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
        try FileManager.default.createDirectory(at: paths.agentsDirectory, withIntermediateDirectories: true)
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
