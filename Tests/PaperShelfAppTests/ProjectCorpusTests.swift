import XCTest
import AppKit
import CoreGraphics
import CoreText
import PDFKit
@testable import PaperShelf
@testable import PaperShelfCore

/// The Ask flow, over a corpus rather than over one document.
///
/// Every earlier test of projects hands the views a stub environment, which is right for
/// testing what a view draws and useless for the question this file asks: does the whole
/// path hold up, from PDFs on disk through the library to what the project workspace and
/// the sidebar each believe about the same project. The two disagreed on screen, and a
/// stub cannot disagree with itself.
final class ProjectCorpusTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpus-" + UUID().uuidString.filter { !$0.isNumber })
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A real PDF with real, extractable text, so "has text yet" is answered by the file
    /// rather than by the test.
    private func writePDF(named name: String, text: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let raw = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: raw)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0),
            CGPath(rect: CGRect(x: 40, y: 40, width: 520, height: 700), transform: nil), nil
        )
        CTFrameDraw(frame, context)
        context.endPDFPage()
        context.closePDF()
        try (raw as Data).write(to: url)
        return url
    }

    /// Sixty documents: enough that a query walking the whole table, or a count taken from
    /// a different table than the list beside it, has somewhere to go wrong.
    private func corpus(_ count: Int = 60) throws -> [URL] {
        try (0..<count).map { index in
            try writePDF(named: "paper-\(scratchLabel(index)).pdf",
                         text: "Paper \(index). Conflict-free replicated data types, "
                             + "convergence, and the merge of concurrent updates.")
        }
    }

    /// Names with no digits in them: a folder or file name that reads as a year is one of
    /// the places the naming rules look for a date.
    private func scratchLabel(_ index: Int) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        return String([letters[index / 26 % 26], letters[index % 26]])
    }

    private func library() throws -> Library {
        try Library(url: folder.appendingPathComponent("library.sqlite"))
    }

    private func environment(_ library: Library) async -> ProjectsEnvironment {
        await MainActor.run {
            liveProjectsEnvironment(
                library: library,
                client: AIClient(baseURL: "https://example.invalid/v1", model: "test", apiKey: ""),
                endpoint: "https://example.invalid/v1", model: "test")
        }
    }

    /// Indexes the corpus the way a finished run does, giving text to the first `withText`
    /// of them and leaving the rest as a scan that has not been read yet.
    @discardableResult
    private func fill(_ library: Library, files: [URL], withText: Int) async throws -> [String] {
        let inputs = files.map { indexInput(for: $0) }
        let records = try await library.indexDocuments(inputs)
        let ids = records.map(\.id)
        let text = ids.prefix(withText).map {
            (documentID: $0, markdown: "Convergence is the property that two replicas "
                                     + "which have seen the same updates agree.")
        }
        try await library.setExtractedText(Array(text))
        return ids
    }

    /// The disagreement on screen: the sidebar counted one document while the workspace
    /// beside it showed none. Both numbers have to come out of the same membership.
    func testTheSidebarCountAndTheProjectListAgreeAcrossTheWholeCorpus() async throws {
        let library = try library()
        let env = await environment(library)
        let files = try corpus()
        let ids = try await fill(library, files: files, withText: 20)
        let project = try await env.createProject("crdts")

        _ = try await addToProject(files.prefix(31).map(\.path), project: project.id, library: library)

        let listed = try await env.listProjects().first { $0.id == project.id }
        let members = try await env.members(project.id)
        XCTAssertEqual(listed?.documentCount, 31, "the sidebar counts membership rows")
        XCTAssertEqual(members.count, 31, "and the workspace lists the same ones")
        XCTAssertEqual(Set(members.map(\.document.contentHash)).count, 31, "no document twice")
        XCTAssertTrue(members.allSatisfy { ids.contains($0.document.contentHash) })
    }

    /// Removing a document has to move both numbers, not just the list the removal
    /// happened in.
    func testRemovingAMemberMovesBothTheListAndTheCount() async throws {
        let library = try library()
        let env = await environment(library)
        let files = try corpus(12)
        try await fill(library, files: files, withText: 12)
        let project = try await env.createProject("crdts")
        _ = try await addToProject(files.map(\.path), project: project.id, library: library)

        let doomed = try await env.members(project.id).first!
        try await env.removeMember(project.id, doomed.document.contentHash)

        let listed = try await env.listProjects().first { $0.id == project.id }
        let members = try await env.members(project.id)
        XCTAssertEqual(members.count, 11)
        XCTAssertEqual(listed?.documentCount, 11,
                       "the sidebar's count is stale if this is still 12")
        XCTAssertFalse(members.contains { $0.document.contentHash == doomed.document.contentHash })
    }

    /// What the workspace says about itself: how many documents, and how many of them have
    /// no text and so contribute nothing but a title to an answer.
    func testTheWorkspaceKnowsWhichMembersHaveTextToAskAcross() async throws {
        let library = try library()
        let env = await environment(library)
        let files = try corpus(40)
        try await fill(library, files: files, withText: 15)
        let project = try await env.createProject("crdts")
        _ = try await addToProject(files.map(\.path), project: project.id, library: library)

        let members = try await env.members(project.id)
        let withText = members.filter { !$0.document.markdown.isEmpty }
        XCTAssertEqual(members.count, 40)
        XCTAssertEqual(withText.count, 15)
        XCTAssertTrue(withText.allSatisfy { $0.document.markdown.contains("Convergence") })
    }

    /// A project full of documents that have no text is a different state from a project
    /// with no documents at all, and the line under the question box has to tell them
    /// apart: one is waiting to be indexed, the other is waiting to be filled.
    func testTheAskLineTellsAnEmptyProjectFromAnUnindexedOne() async throws {
        let library = try library()
        let env = await environment(library)
        let files = try corpus(6)
        try await fill(library, files: files, withText: 0)
        let project = try await env.createProject("crdts")

        let empty = try await env.members(project.id)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(askReadiness(of: empty.map(\.document)), .noDocuments)

        _ = try await addToProject(files.map(\.path), project: project.id, library: library)
        let unindexed = try await env.members(project.id)
        XCTAssertEqual(unindexed.count, 6)
        XCTAssertEqual(askReadiness(of: unindexed.map(\.document)), .noText)

        try await library.setExtractedText("Convergence.", forDocument: unindexed[0].document.contentHash)
        let ready = try await env.members(project.id)
        XCTAssertEqual(askReadiness(of: ready.map(\.document)), .ready)
    }

    /// Renaming a file on disk, which is this app's whole job, must not drop it out of the
    /// projects it was filed into.
    func testARenamedDocumentStaysInItsProject() async throws {
        let library = try library()
        let env = await environment(library)
        let files = try corpus(8)
        try await fill(library, files: files, withText: 8)
        let project = try await env.createProject("crdts")
        _ = try await addToProject(files.map(\.path), project: project.id, library: library)

        let moved = files[0]
        let destination = folder.appendingPathComponent("renamed-by-the-run.pdf")
        try FileManager.default.moveItem(at: moved, to: destination)
        let record = try await library.document(atPath: moved.path)
        try await library.recordLocation(destination.path, forDocument: XCTUnwrap(record).id)

        let members = try await env.members(project.id)
        XCTAssertEqual(members.count, 8, "a rename is not a removal")
        let again = try await library.document(atPath: destination.path)
        XCTAssertEqual(again?.id, record?.id, "and it is the same document, not a new one")
    }

    /// Adding the same file twice, which is what a second drop on the same project is,
    /// must not make it two members.
    func testDroppingTheSameFileTwiceFilesItOnce() async throws {
        let library = try library()
        let env = await environment(library)
        let files = try corpus(5)
        try await fill(library, files: files, withText: 5)
        let project = try await env.createProject("crdts")

        _ = try await addToProject(files.map(\.path), project: project.id, library: library)
        _ = try await addToProject(files.map(\.path), project: project.id, library: library)

        let listed = try await env.listProjects().first { $0.id == project.id }
        let members = try await env.members(project.id)
        XCTAssertEqual(members.count, 5)
        XCTAssertEqual(listed?.documentCount, 5)
    }

    /// Opening a project has to cost about one query, not one per document. This is the
    /// shape the test guards, not a stopwatch: the number of round trips through the
    /// library actor must not grow with the size of the project.
    func testOpeningAProjectDoesNotAskThePerDocumentQuestions() async throws {
        let library = try library()
        let env = await environment(library)
        let files = try corpus(120)
        let ids = try await fill(library, files: files, withText: 120)
        let project = try await env.createProject("crdts")
        _ = try await addToProject(files.map(\.path), project: project.id, library: library)
        for id in ids.prefix(30) { try await library.addTag("crdts", toDocument: id) }

        let started = Date()
        let model = await MainActor.run {
            ProjectDetailModel(project: ProjectSummary(id: project.id, name: "crdts",
                                                       documentCount: 120),
                               env: env)
        }
        await model.load()
        let elapsed = Date().timeIntervalSince(started)

        let members = await MainActor.run { model.members }
        let tagged = await MainActor.run { model.tagsByDocument.filter { !$0.value.isEmpty } }
        XCTAssertEqual(members.count, 120)
        XCTAssertEqual(tagged.count, 30)
        // Generous on purpose: a machine under load is allowed to be slow, a load that
        // asks the library 120 separate questions for the tags alone is not.
        XCTAssertLessThan(elapsed, 2.0, "opening a project of 120 documents took \(elapsed)s")
    }
}
