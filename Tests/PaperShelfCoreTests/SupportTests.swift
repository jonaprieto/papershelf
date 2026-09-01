import XCTest
@testable import PaperShelfCore

/// The rename must not cost anybody their library. Everything the app keeps lives in one
/// folder in Application Support, and that folder used to have the old name.
final class SupportTests: XCTestCase {
    private func scratch() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName("support"), isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func testTheOldFolderIsMovedToTheNewNameOnce() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("PDF Hammer", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("a library".utf8).write(to: old.appendingPathComponent("library.sqlite"))

        let folder = supportDirectory(in: base)

        XCTAssertEqual(folder.lastPathComponent, "PaperShelf")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("library.sqlite"),
                                  encoding: .utf8), "a library")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "moved, not copied")
    }

    /// A folder already under the new name is the truth. The old one is left alone rather
    /// than merged or written over, which is the only outcome that cannot lose anything.
    func testAnExistingNewFolderIsNeverOverwritten() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("PDF Hammer", isDirectory: true)
        let new = base.appendingPathComponent("PaperShelf", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("library.sqlite"))
        try Data("current".utf8).write(to: new.appendingPathComponent("library.sqlite"))

        let folder = supportDirectory(in: base)

        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("library.sqlite"),
                                  encoding: .utf8), "current")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "left where it was")
    }

    func testAFirstRunJustGetsTheFolder() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }

        let folder = supportDirectory(in: base)

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(folder.lastPathComponent, "PaperShelf")
    }

    // MARK: - The app and the server agree on what they are

    /// `paperShelfVersion` and the app's own `CFBundleShortVersionString` are two numbers
    /// written in two files, which is exactly the shape that let the plugin listing drift
    /// to 1.3.0 while the app moved on to 1.6.0 without anyone noticing. Read from disk
    /// rather than duplicated as a literal here, so a future bump that misses one of them
    /// fails this instead of shipping quietly mismatched.
    func testTheInfoPlistVersionMatchesTheServerVersion() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)   // .../Tests/PaperShelfCoreTests/SupportTests.swift
            .deletingLastPathComponent()                        // .../Tests/PaperShelfCoreTests
            .deletingLastPathComponent()                        // .../Tests
            .deletingLastPathComponent()                        // repository root
        let plistURL = repositoryRoot.appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any])

        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, paperShelfVersion,
                       "Resources/Info.plist and paperShelfVersion have drifted apart")
    }
}
