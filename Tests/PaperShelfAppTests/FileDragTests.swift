import XCTest
import UniformTypeIdentifiers
@testable import PaperShelf

/// What a drop reads out of a drag.
///
/// A project row catches drags from four places: the sidebar's own tree, the results
/// list, the shelf, and Finder. All four hand over an item provider, and the row turns
/// those into file URLs before it can file anything. This holds that step honest even
/// though a test cannot hold a mouse: what it cannot check is whether the row is offered
/// the drag at all, which is a question about AppKit hit-testing, not about this code.
final class FileDragTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("drag-" + UUID().uuidString.filter { !$0.isNumber })
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func paper(_ name: String = "paper.pdf") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("pdf".utf8).write(to: url)
        return url
    }

    /// The provider the list and the shelf hand out for a row, which is the drag that was
    /// landing on nothing.
    func testAFileDragCarriesThePathItStartedFrom() async throws {
        let url = try paper()
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: url))

        XCTAssertTrue(provider.registeredTypeIdentifiers.contains(UTType.fileURL.identifier),
                      "registered: \(provider.registeredTypeIdentifiers)")

        let dropped = await droppedFileURLs(from: [provider])
        XCTAssertEqual(dropped.map(\.path), [url.path],
                       "and it is the file itself, not a copy made to answer the drag")
    }

    /// Several rows dragged at once arrive as several providers, and all of them count.
    func testASetOfFilesArrivesWhole() async throws {
        let urls = try ["one.pdf", "two.pdf", "three.pdf"].map { try paper($0) }
        let providers = try urls.map { try XCTUnwrap(NSItemProvider(contentsOf: $0)) }

        let dropped = await droppedFileURLs(from: providers)

        XCTAssertEqual(dropped.map(\.lastPathComponent), ["one.pdf", "two.pdf", "three.pdf"])
    }

    /// A folder dragged from the sidebar carries a URL like anything else. What it means
    /// is decided later, by `pdfsUnder`.
    func testAFolderCarriesItsURLToo() async throws {
        let papers = folder.appendingPathComponent("papers")
        try FileManager.default.createDirectory(at: papers, withIntermediateDirectories: true)
        let provider = NSItemProvider(object: papers as NSURL)

        let dropped = await droppedFileURLs(from: [provider])

        XCTAssertEqual(dropped.map(\.path), [papers.path])
    }

    /// A drag carrying something that is not a file leaves the project alone rather than
    /// filing a URL nobody can open.
    func testADragThatIsNotAFileIsIgnored() async throws {
        let web = NSItemProvider(object: URL(string: "https://example.invalid/x.pdf")! as NSURL)
        let text = NSItemProvider(object: "not a file" as NSString)

        let dropped = await droppedFileURLs(from: [web, text])

        XCTAssertTrue(dropped.isEmpty)
    }
}
