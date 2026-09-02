import XCTest
import Foundation

final class AppleScriptTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testScriptingDefinitionCoversTheSemanticSurface() throws {
        let sdefURL = repositoryRoot.appendingPathComponent("Resources/PaperShelf.sdef")
        let sdef = try String(contentsOf: sdefURL, encoding: .utf8)
        let commands = [
            "choose theme", "choose PDF contrast", "current theme", "current PDF contrast",
            "show catalogue", "show settings", "show notes", "toggle sidebar",
            "toggle inspector", "toggle reading mode", "toggle zen mode",
            "open command palette", "copy current citation", "bookmark current page",
            "remove current bookmark", "show bookmarks", "show diagnostics log", "version",
        ]

        for command in commands {
            XCTAssertTrue(sdef.contains("name=\"\(command)\""), command)
        }
        XCTAssertEqual(sdef.components(separatedBy: "PaperShelfScriptCommand").count - 1,
                       commands.count)
    }

    func testBundleDeclaresCocoaScriptingAndTheUIHarnessUsesOsascript() throws {
        let plistURL = repositoryRoot.appendingPathComponent("Resources/Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(
            from: plistData, format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSAppleScriptEnabled"] as? Bool, true)
        XCTAssertEqual(plist["OSAScriptingDefinition"] as? String, "PaperShelf.sdef")

        let script = try String(contentsOf: repositoryRoot
            .appendingPathComponent("Tools/ui-smoke-test.applescript"), encoding: .utf8)
        XCTAssertTrue(script.contains("auditToolbar"))
        XCTAssertTrue(script.contains("auditSettings"))
        XCTAssertTrue(script.contains("key code 53"))

        let shellURL = repositoryRoot.appendingPathComponent("Tools/ui-smoke-test.sh")
        let attributes = try FileManager.default.attributesOfItem(atPath: shellURL.path)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o111, 0o111)
    }
}
