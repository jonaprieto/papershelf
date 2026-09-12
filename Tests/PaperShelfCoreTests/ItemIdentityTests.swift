import XCTest
@testable import PaperShelfCore

/// `key` is what the library holds a document's tags, notes, reading position and project
/// membership against, so it has to mean the same thing before and after a run moves the
/// file. It did not: it was `source.resolvingSymlinksInPath().path`, and that expression
/// answers differently depending on whether the file is still there.
final class ItemIdentityTests: XCTestCase {

    private let fm = FileManager.default

    /// Built through `/private`, which is how `contentsOfDirectory` hands back a path
    /// under the temporary directory, and which is the spelling the old expression
    /// stripped while the file existed and kept once it did not.
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: "/private" + fm.temporaryDirectory.path)
            .appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testIdentityDoesNotMoveWhenTheFileDoes() throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let paper = root.appendingPathComponent("paper.pdf")
        try Data("%PDF-1.4".utf8).write(to: paper)

        let before = Item.identity(of: paper)
        try fm.moveItem(at: paper, to: root.appendingPathComponent("renamed.pdf"))
        XCTAssertEqual(Item.identity(of: paper), before,
                       "the file was renamed away and took its identity with it")

        // And the same through an Item, which is what everything actually holds.
        let item = Item(root: root, source: paper, destination: paper, status: .renamed)
        XCTAssertEqual(item.key, before)
    }

    /// The answer for a file that is there is the string the old expression produced, so
    /// nothing already recorded in the library is orphaned.
    func testIdentityIsUnchangedForAFileThatIsThere() throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let paper = root.appendingPathComponent("paper.pdf")
        try Data("%PDF-1.4".utf8).write(to: paper)
        XCTAssertEqual(Item.identity(of: paper), paper.resolvingSymlinksInPath().path)
    }

    /// A paper that is itself a link is still the paper it points at, so two links to one
    /// file stay one document.
    func testALinkIsTheFileItPointsAt() throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let real = root.appendingPathComponent("real.pdf")
        try Data("%PDF-1.4".utf8).write(to: real)
        let link = root.appendingPathComponent("link.pdf")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(Item.identity(of: link), Item.identity(of: real))
    }

    /// A cache written before `key` was stored carries no `key` field, and still reads:
    /// identity is worked out from `source` on the way in rather than written down twice.
    func testAnItemDecodesWithoutAStoredKey() throws {
        let root = try scratch()
        defer { try? fm.removeItem(at: root) }
        let paper = root.appendingPathComponent("paper.pdf")
        let item = Item(root: root, source: paper, destination: paper, status: .renamed)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(item)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"key\""),
                       "key is derived, not a second fact to disagree with source")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(Item.self, from: data).key, item.key)
    }
}
