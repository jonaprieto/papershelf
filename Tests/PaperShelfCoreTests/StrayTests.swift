import XCTest
@testable import PaperShelfCore

/// Which documents no source accounts for any more. The dangerous mistake here is
/// forgetting a library that is merely unplugged, so several of these are about what the
/// rule refuses to touch.
final class StrayTests: XCTestCase {

    private func strays(_ locations: [String: [String]],
                        sources: [String],
                        present: Set<String>) -> [String] {
        strayDocuments(locations, sources: sources) { present.contains($0) }
    }

    /// The case that started this: the folder stopped being a source, and its papers went
    /// on filling projects and answering searches.
    func testAFileUnderNoSourceIsAStray() {
        let out = strays(["a": ["/papers/x.pdf"]], sources: [],
                         present: ["/papers", "/papers/x.pdf"])
        XCTAssertEqual(out, ["a"], "the file is there; nothing watches where it lives")
    }

    func testAFileInsideASourceIsKept() {
        let out = strays(["a": ["/papers/x.pdf"]], sources: ["/papers"],
                         present: ["/papers", "/papers/x.pdf"])
        XCTAssertTrue(out.isEmpty)
    }

    /// A source names a folder, not a prefix: `/papers-old` is not inside `/papers`.
    func testASiblingFolderIsNotInsideTheSource() {
        let out = strays(["a": ["/papers-old/x.pdf"]], sources: ["/papers"],
                         present: ["/papers-old", "/papers-old/x.pdf"])
        XCTAssertEqual(out, ["a"])
    }

    /// A single PDF can be a source in its own right.
    func testASourceThatIsTheFileItself() {
        let out = strays(["a": ["/papers/x.pdf"]], sources: ["/papers/x.pdf"],
                         present: ["/papers", "/papers/x.pdf"])
        XCTAssertTrue(out.isEmpty)
    }

    /// Deleted out of a folder that is still watched and still there.
    func testAFileDeletedFromAWatchedFolderIsAStray() {
        let out = strays(["a": ["/papers/x.pdf"]], sources: ["/papers"], present: ["/papers"])
        XCTAssertEqual(out, ["a"])
    }

    /// An unmounted volume: the file is missing and so is its folder. One cable away is
    /// not the same as deleted.
    func testAnUnmountedSourceIsLeftAlone() {
        let out = strays(["a": ["/Volumes/Archive/x.pdf"]], sources: ["/Volumes/Archive"],
                         present: [])
        XCTAssertTrue(out.isEmpty, "the folder is missing too, so the volume may be unmounted")
    }

    /// One supporting path is enough.
    func testKnownInsideAndOutsideASource() {
        let out = strays(["a": ["/elsewhere/x.pdf", "/papers/x.pdf"]], sources: ["/papers"],
                         present: ["/papers", "/papers/x.pdf", "/elsewhere", "/elsewhere/x.pdf"])
        XCTAssertTrue(out.isEmpty)
    }

    /// Removing every source makes every document a stray, which is what emptying the
    /// list is asking for.
    func testWithNoSourcesEverythingIsAStray() {
        let out = strays(["a": ["/papers/x.pdf"], "b": ["/other/y.pdf"]], sources: [],
                         present: ["/papers", "/papers/x.pdf", "/other", "/other/y.pdf"])
        XCTAssertEqual(out, ["a", "b"])
    }

    func testADocumentWithNoKnownPathIsAStray() {
        XCTAssertEqual(strays(["a": []], sources: ["/papers"], present: ["/papers"]), ["a"])
    }
}
