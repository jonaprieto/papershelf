import XCTest
@testable import PaperShelf

/// ⌘K over a paper opened from Finder stands the window in that paper's folder, for the
/// session only. The decision about whether to do that at all is this.
final class StandInFolderTests: XCTestCase {

    private let paper = URL(fileURLWithPath: "/Users/someone/Downloads/2025/paper.pdf")

    func testAPaperOpenedFromFinderLendsItsFolder() {
        XCTAssertEqual(folderToStandIn(document: paper, isReader: true, showsLibrary: false)?.path,
                       "/Users/someone/Downloads/2025")
    }

    /// The sources behind an open library are sources somebody chose. ⌘K is a request for
    /// the palette, not a request to replace them.
    func testALibraryAlreadyOnScreenKeepsItsOwnSources() {
        XCTAssertNil(folderToStandIn(document: paper, isReader: true, showsLibrary: true))
    }

    /// The window has to be one the delegate opened for a file. On an ordinary launch
    /// nothing has set `wantsLibrary` either, so that flag cannot be the test: without
    /// this condition, ⌘K while reading in the library would scope the library.
    func testAPaperBeingReadInsideTheLibraryLendsNothing() {
        XCTAssertNil(folderToStandIn(document: paper, isReader: false, showsLibrary: false))
    }

    func testAWindowShowingNoFileLendsNothing() {
        XCTAssertNil(folderToStandIn(document: nil, isReader: true, showsLibrary: false))
        XCTAssertNil(folderToStandIn(document: URL(string: "https://example.com/a.pdf"),
                                     isReader: true, showsLibrary: false))
    }
}
