import XCTest
@testable import PaperShelf

@MainActor
final class LocalBuildUpdatesTests: XCTestCase {
    func testCompletedBundlesAndRecordsPreserveTheRunningIdentity() async throws {
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent("LocalBuildTests-\(UUID())")
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }
        let installed = scratch.appendingPathComponent("Installed.app")
        let dist = scratch.appendingPathComponent("dist/PaperShelf.app")
        let record = scratch.appendingPathComponent("development-build.json")
        var info: [String: Any] = [
            "CFBundleIdentifier": "com.jonaprieto.pdfhammer", "CFBundleShortVersionString": "1.14.1",
            "CFBundleVersion": "23", "PaperShelfGitCommit": "abc123+dirty",
            "PaperShelfBuildChannel": "development", "PaperShelfBuildID": UUID().uuidString,
            "PaperShelfBuiltAt": "2026-09-08T12:00:00Z",
        ]
        func bundle(_ url: URL) throws {
            let contents = url.appendingPathComponent("Contents")
            try files.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try files.createDirectory(at: contents.appendingPathComponent("_CodeSignature"), withIntermediateDirectories: true)
            for name in ["PaperShelf", "papershelf-mcp"] {
                let executable = contents.appendingPathComponent("MacOS/\(name)")
                try Data().write(to: executable)
                try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            }
            try Data().write(to: contents.appendingPathComponent("_CodeSignature/CodeResources"))
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        }
        func writeRecord() throws {
            try JSONSerialization.data(withJSONObject: ["bundlePath": dist.path,
                "buildID": info["PaperShelfBuildID"]!, "version": info["CFBundleShortVersionString"]!,
                "builtAt": info["PaperShelfBuiltAt"]!]).write(to: record, options: .atomic)
        }
        try bundle(installed)
        let running = try XCTUnwrap(AppBuild.completed(at: installed))
        XCTAssertNil(LocalBuildUpdates.find(running: running, recordURL: record))
        try bundle(dist)
        try writeRecord()
        XCTAssertNil(LocalBuildUpdates.find(running: running, recordURL: record), "Installing the same ID is not a new build")
        info["PaperShelfBuildID"] = UUID().uuidString
        try bundle(dist)
        XCTAssertNil(LocalBuildUpdates.find(running: running, recordURL: record), "A stale record does not advertise another bundle")
        try writeRecord()
        let separate = try XCTUnwrap(LocalBuildUpdates.find(running: running, recordURL: record))
        XCTAssertEqual(separate.bundleURL.path, dist.path)
        XCTAssertEqual(separate.revision, running.revision)
        XCTAssertNotEqual(separate.id, running.id)

        info["PaperShelfBuiltAt"] = "2026-09-07T12:00:00Z"
        try bundle(dist)
        try writeRecord()
        XCTAssertNil(LocalBuildUpdates.find(running: running, recordURL: record), "An older checkout is not a new local build")
        info["PaperShelfBuiltAt"] = "2026-09-08T12:00:00Z"
        try bundle(dist)
        try writeRecord()
        var releaseInfo = info
        releaseInfo["PaperShelfBuildChannel"] = "release"
        releaseInfo["PaperShelfBuildID"] = running.id?.uuidString
        let released = AppBuild(info: releaseInfo, at: installed)
        XCTAssertNil(LocalBuildUpdates.find(running: released, recordURL: record), "Release builds ignore checkout records")

        let suite = "LocalBuildTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = LocalBuildUpdates(running: running, defaults: defaults, recordURL: record)
        await checker.check()
        XCTAssertTrue(checker.showsBadge)
        checker.dismissBuild()
        await checker.check()
        XCTAssertFalse(checker.showsBadge)
        XCTAssertNotNil(checker.available)
        info["PaperShelfBuildID"] = UUID().uuidString
        try bundle(dist)
        try writeRecord()
        await checker.check()
        XCTAssertTrue(checker.showsBadge, "Another dirty build has its own notice")
        try files.removeItem(at: dist.appendingPathComponent("Contents/_CodeSignature/CodeResources"))
        XCTAssertNil(LocalBuildUpdates.find(running: running, recordURL: record), "Interrupted signing is not a completed build")
        try files.removeItem(at: dist)
        XCTAssertNil(LocalBuildUpdates.find(running: running, recordURL: record), "Missing paths are ignored")
        try bundle(installed)
        XCTAssertNotNil(LocalBuildUpdates.find(running: running, recordURL: record), "Replacing the running bundle works without a record")
        XCTAssertNotEqual(AppBuild.completed(at: installed)?.id, running.id)
        info.removeValue(forKey: "PaperShelfBuildID")
        try bundle(installed)
        XCTAssertNil(AppBuild.completed(at: installed))
    }
}
