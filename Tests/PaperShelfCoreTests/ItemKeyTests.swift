import XCTest
@testable import PaperShelfCore

/// `Item.key` is what every index in the app is keyed on -- `Runner.indexByKey`,
/// `decisions`, `byFolder`, the tag cache -- and what the shelf looks the selected file up
/// by. Two things have to hold for those to keep working, and neither is obvious from the
/// one line that computes it.
final class ItemKeyTests: XCTestCase {

    private func scratch(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("papershelf-key-\(name)-\(UUID().uuidString)")
    }

    /// The key must not move when the file it names stops existing.
    ///
    /// It is `source.resolvingSymlinksInPath().path`, and resolution is a question about
    /// the filesystem, so a key read while a file was there and a key read after it was
    /// applied, moved or trashed are two separate answers. An index built from the first
    /// is only valid if the second agrees: otherwise looking a file up would start
    /// returning nothing the moment it was acted on, while the state keyed under the old
    /// string sat there unreachable.
    func testAKeyDoesNotMoveWhenTheFileGoesAway() throws {
        let fm = FileManager.default
        let root = scratch("gone")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let pdf = root.appendingPathComponent("paper.pdf")
        fm.createFile(atPath: pdf.path, contents: Data())

        let item = Item(root: root, source: pdf, destination: pdf, status: .renamed)
        let before = item.key
        try fm.removeItem(at: pdf)

        XCTAssertEqual(item.key, before, "the key moved when the file was removed")
    }

    /// And it must not move when the file is reached through a symlink, which on macOS is
    /// the ordinary case rather than an exotic one: a library under a linked folder, and
    /// every temporary directory, arrives as /var and resolves to /private/var.
    func testAKeyIsTheResolvedPathWhicheverWayTheFileIsReached() throws {
        let fm = FileManager.default
        let root = scratch("link")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("real"),
                               withIntermediateDirectories: true)
        let pdf = root.appendingPathComponent("real/paper.pdf")
        fm.createFile(atPath: pdf.path, contents: Data())
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("real"))

        let direct = Item(root: root, source: pdf, destination: pdf, status: .renamed)
        let through = Item(root: root, source: link.appendingPathComponent("paper.pdf"),
                           destination: pdf, status: .renamed)

        XCTAssertEqual(direct.key, through.key,
                       "the same file reached two ways has to be the same file")
    }

    /// Changing what an item is going to be called does not change what it is. `key` comes
    /// from `source`, which never moves, so an index built once stays valid across a
    /// rename, a decision and an apply.
    func testDecidingOnAnItemDoesNotMoveItsKey() throws {
        let fm = FileManager.default
        let root = scratch("rename")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let pdf = root.appendingPathComponent("scan001.pdf")
        fm.createFile(atPath: pdf.path, contents: Data())

        var item = Item(root: root, source: pdf, destination: pdf, status: .renamed)
        let before = item.key
        item.destination = root.appendingPathComponent("2017-gomes-verifying.pdf")
        item.carriedOut = true
        item.status = .renamed

        XCTAssertEqual(item.key, before)
    }
}
