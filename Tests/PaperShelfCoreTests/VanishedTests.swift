import XCTest
@testable import PaperShelfCore

/// The rule for tidying documents whose files are gone. The dangerous mistake here is
/// forgetting a library that is merely unplugged, so most of these are about what the
/// rule refuses to touch.
final class VanishedTests: XCTestCase {

    private func gone(_ locations: [String: [String]], present: Set<String>) -> [String] {
        vanishedDocuments(locations) { present.contains($0) }
    }

    func testAFileDeletedFromAFolderThatStillExists() {
        let out = gone(["a": ["/papers/gone.pdf"]], present: ["/papers"])
        XCTAssertEqual(out, ["a"])
    }

    func testAFileThatIsStillThereIsKept() {
        let out = gone(["a": ["/papers/here.pdf"]], present: ["/papers", "/papers/here.pdf"])
        XCTAssertTrue(out.isEmpty)
    }

    /// An unmounted volume: neither the file nor the folder is there. Forgetting these
    /// would throw away the tags and notes of a library that is one cable away.
    func testAnUnmountedVolumeIsLeftAlone() {
        let out = gone(["a": ["/Volumes/Archive/papers/x.pdf"]], present: [])
        XCTAssertTrue(out.isEmpty, "the folder is missing too, so the volume may be unmounted")
    }

    /// Known in two places: still here in one of them, so it stays.
    func testADocumentThatSurvivesInOnePlaceStays() {
        let out = gone(["a": ["/papers/x.pdf", "/archive/x.pdf"]],
                       present: ["/papers", "/archive", "/archive/x.pdf"])
        XCTAssertTrue(out.isEmpty)
    }

    /// Gone from both, and both folders are still there.
    func testADocumentGoneFromEverywhereIsForgotten() {
        let out = gone(["a": ["/papers/x.pdf", "/archive/x.pdf"]],
                       present: ["/papers", "/archive"])
        XCTAssertEqual(out, ["a"])
    }

    /// Gone from one folder that exists and one volume that does not: the surviving
    /// folder is enough to say the file was removed rather than unplugged.
    func testOneSurvivingFolderIsEnough() {
        let out = gone(["a": ["/papers/x.pdf", "/Volumes/Gone/x.pdf"]], present: ["/papers"])
        XCTAssertEqual(out, ["a"])
    }

    func testADocumentWithNoKnownPathIsNotTouched() {
        XCTAssertTrue(gone(["a": []], present: []).isEmpty)
    }
}
