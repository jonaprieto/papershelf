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
        let commands = [
            "choose theme", "choose PDF contrast", "current theme", "current PDF contrast",
            "show catalogue", "show settings", "show notes", "toggle sidebar",
            "toggle inspector", "toggle reading mode", "toggle zen mode",
            "open command palette", "copy current citation", "bookmark current page",
            "remove current bookmark", "show bookmarks", "show diagnostics log", "version",
        ]

        let dictionary = try XMLDocument(contentsOf: sdefURL, options: [])
        let commandNodes = try dictionary.nodes(forXPath: "//command")
        XCTAssertEqual(commandNodes.count, commands.count)
        for node in commandNodes {
            let element = try XCTUnwrap(node as? XMLElement)
            let name = try XCTUnwrap(element.attribute(forName: "name")?.stringValue)
            XCTAssertTrue(commands.contains(name), name)
            XCTAssertEqual(
                try element.nodes(forXPath: "cocoa[@class='PaperShelfScriptCommand']").count,
                1,
                name
            )
        }
        XCTAssertEqual(Set(commandNodes.compactMap {
            ($0 as? XMLElement)?.attribute(forName: "name")?.stringValue
        }), Set(commands))
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
        XCTAssertTrue(script.contains("__PAPERSHELF_APP_PATH__"))
        XCTAssertTrue(script.contains("__PAPERSHELF_EXECUTABLE__"))
        XCTAssertTrue(script.contains("first application process whose unix id is targetPID"))
        XCTAssertTrue(script.contains("assertCatalogueLaunchState"))
        XCTAssertTrue(script.contains("Launch opened the rename prompt instead of the catalogue"))
        XCTAssertTrue(script.contains("AXIdentifier"))

        let contentView = try String(contentsOf: repositoryRoot
            .appendingPathComponent("Sources/PaperShelf/ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(contentView.contains("if prefs.viewMode == .catalogue {\n                    libraryPreview(preservingVisibleResults: hadCache)"))

        let shell = try String(contentsOf: repositoryRoot
            .appendingPathComponent("Tools/ui-smoke-test.sh"), encoding: .utf8)
        XCTAssertTrue(shell.contains("pgrep -f -x \"$APP_EXECUTABLE\""))
        XCTAssertTrue(shell.contains("sed \"s|__PAPERSHELF_APP_PATH__|"))

        let shellURL = repositoryRoot.appendingPathComponent("Tools/ui-smoke-test.sh")
        let attributes = try FileManager.default.attributesOfItem(atPath: shellURL.path)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o111, 0o111)
    }
}
