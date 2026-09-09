import XCTest
@testable import PaperShelf

final class AppBuildTests: XCTestCase {
    func testTheRunningIdentityIsASnapshotAndSigningDoesNotChooseItsChannel() {
        let id = UUID()
        var info: [String: Any] = [
            "CFBundleShortVersionString": "1.14.1", "CFBundleVersion": "23",
            "PaperShelfGitCommit": "abc123+dirty", "PaperShelfBuildID": id.uuidString,
            "PaperShelfBuildChannel": "release", "PaperShelfBuiltAt": "2026-09-08T12:00:00Z",
            "PaperShelfAdHocBuild": true,
        ]
        let running = AppBuild(info: info, at: URL(fileURLWithPath: "/tmp/PaperShelf.app"))
        info["CFBundleShortVersionString"] = "1.15.0"
        info["PaperShelfBuildID"] = UUID().uuidString
        XCTAssertEqual(running.version, "1.14.1")
        XCTAssertEqual(running.id, id)
        XCTAssertEqual(running.revision, "abc123+dirty")
        XCTAssertEqual(running.channel, .release)
        XCTAssertNotNil(running.builtAt)
        XCTAssertEqual(AppBuild(info: [:], at: running.bundleURL).channel, .development)
    }
}
