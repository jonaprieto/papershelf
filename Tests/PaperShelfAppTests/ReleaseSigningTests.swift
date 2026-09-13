import XCTest
import Foundation

/// A notarized build runs under the hardened runtime, which refuses any protected resource the
/// app has not declared. None of that shows in a local build, which is ad-hoc signed without
/// one, so these pin what the release pipeline needs before the day it first notarizes.
final class ReleaseSigningTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// Dictation records from the microphone. Without this the permission prompt never
    /// appears in a notarized build and dictation simply stops.
    func testTheEntitlementsDeclareAudioInputForDictation() throws {
        let data = try Data(contentsOf: repositoryRoot
            .appendingPathComponent("Resources/PaperShelf.entitlements"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any])
        XCTAssertEqual(plist["com.apple.security.device.audio-input"] as? Bool, true)

        let dictation = try text("Sources/PaperShelf/NoteDictation.swift")
        XCTAssertTrue(dictation.contains("requestRecordPermission"),
                      "if dictation stopped using the microphone, this entitlement can go")
    }

    func testTheReleaseSignsTheAppWithThoseEntitlements() throws {
        let script = try text("Tools/make-dmg.sh")
        XCTAssertTrue(script.contains("ENTITLEMENTS=\"Resources/PaperShelf.entitlements\""))
        XCTAssertTrue(script.contains("--entitlements \"$ENTITLEMENTS\""))
        XCTAssertTrue(script.contains("--options runtime --timestamp"))
        XCTAssertTrue(script.contains("refusing to build a release"))
    }

    /// codesign only finds an identity on the keychain search list, and a keychain the
    /// workflow creates is not on it until it is added.
    func testTheWorkflowPutsItsKeychainWhereCodesignLooks() throws {
        let workflow = try text(".github/workflows/release.yml")
        XCTAssertTrue(workflow.contains("security list-keychains -d user -s \"$KEYCHAIN\""))
        XCTAssertTrue(workflow.contains("security set-keychain-settings -lut 21600"))
        XCTAssertTrue(workflow.contains("xcrun stapler validate"))
    }
}
