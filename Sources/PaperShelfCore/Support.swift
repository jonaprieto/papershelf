import Foundation

/// The one place a version number is written. The MCP server reports it as its
/// `serverInfo`, the plugin listing declares it, and `Tools/mcp-check.sh` checks the two
/// against each other, which is how they drifted to 1.1.0 and 1.2.3 without anyone
/// noticing. Bumped to 1.3.0 there, then left alone while the app's own
/// `CFBundleShortVersionString` moved on to 1.6.0, which is a second way for the same
/// drift to happen: a plugin listing showing an older number than the app it ships
/// inside. Kept level with that number now, and a test holds the two together so they
/// cannot quietly separate again.
public let paperShelfVersion = "1.7.0"

/// Where the app keeps what it must not lose: the library, the last run, anything else
/// that outlives a launch.
///
/// The folder used to be called "PDF Hammer", which is what the app used to be called. A
/// rename that simply started writing somewhere else would leave a person's library,
/// their tags, their notes and their reading positions in a directory nothing opens any
/// more, which reads as the app having forgotten everything. So the old folder is moved
/// to the new name the first time this is asked for, once, and only when there is nothing
/// at the new name to overwrite.
public func supportDirectory(named name: String = "PaperShelf",
                             legacy: String = "PDF Hammer") -> URL? {
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask).first else { return nil }
    return supportDirectory(in: base, named: name, legacy: legacy)
}

/// The same, against a given base directory, so the move can be tested without touching
/// the Application Support folder of whoever is running the tests.
public func supportDirectory(in base: URL, named name: String = "PaperShelf",
                             legacy: String = "PDF Hammer") -> URL {
    let manager = FileManager.default
    let folder = base.appendingPathComponent(name, isDirectory: true)
    let old = base.appendingPathComponent(legacy, isDirectory: true)

    if !manager.fileExists(atPath: folder.path), manager.fileExists(atPath: old.path) {
        // A failed move is not worth interrupting anyone over: the new folder is created
        // below either way, and the old one is left exactly where it was rather than
        // half-copied. Someone can still find it; nothing is destroyed to make room.
        try? manager.moveItem(at: old, to: folder)
    }
    try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}
