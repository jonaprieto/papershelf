import XCTest
@testable import PaperShelf
@testable import PaperShelfCore

/// Dropping a file on a project. The library files documents, not paths, so the question
/// this answers is what happens to a file it has never been told about.
final class AddToProjectTests: XCTestCase {

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("addtoproject-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The drop that used to do nothing: a file scanned but never synced, dragged onto a
    /// project. It is indexed on the spot and filed.
    func testAFileTheLibraryHasNeverSeenIsIndexedAndFiled() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = try Library(url: folder.appendingPathComponent("library.sqlite"))
        let file = folder.appendingPathComponent("paper.pdf")
        try Data("not really a pdf".utf8).write(to: file)
        let project = try await library.createProject(name: "crdts")

        let added = try await addToProject([file.path], project: project.id, library: library)

        XCTAssertEqual(added, 1)
        let members = try await library.members(ofProject: project.id)
        XCTAssertEqual(members.count, 1)
        let record = try await library.document(atPath: file.path)
        XCTAssertEqual(members.first?.id, record?.id)
    }

    /// A file already on record keeps the row it has, tags, notes and all, rather than
    /// being indexed a second time under the same path.
    func testAKnownFileIsFiledAgainstTheRowItAlreadyHas() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = try Library(url: folder.appendingPathComponent("library.sqlite"))
        let file = folder.appendingPathComponent("known.pdf")
        try Data("not really a pdf".utf8).write(to: file)
        let record = try await library.indexDocument(path: file.path, contentHash: nil)
        let project = try await library.createProject(name: "crdts")

        let added = try await addToProject([file.path], project: project.id, library: library)

        XCTAssertEqual(added, 1)
        let members = try await library.members(ofProject: project.id)
        XCTAssertEqual(members.map(\.id), [record.id])
    }

    /// A path with nothing behind it is skipped rather than invented.
    func testAMissingFileIsSkipped() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = try Library(url: folder.appendingPathComponent("library.sqlite"))
        let project = try await library.createProject(name: "crdts")

        let added = try await addToProject([folder.appendingPathComponent("gone.pdf").path],
                                           project: project.id, library: library)

        XCTAssertEqual(added, 0)
        let members = try await library.members(ofProject: project.id)
        XCTAssertTrue(members.isEmpty)
    }
}
