import XCTest
@testable import PaperShelfCore

final class CacheTests: XCTestCase {

    private func sample() -> [Item] {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        var item = Item(root: root, source: root.appendingPathComponent("bank/Extracto.pdf"),
                        destination: root.appendingPathComponent("bank/2024-06-extracto.pdf"),
                        status: .decrypted, message: "note")
        item.byteCount = 4096
        item.pageCount = 12
        item.modifiedDate = Date(timeIntervalSince1970: 1_700_000_000)
        item.documentInfo = ["Title": "Extracto", "Author": "Someone"]
        return [item]
    }

    func testAnItemSurvivesTheRoundTrip() throws {
        let data = try JSONEncoder().encode(sample())
        let back = try JSONDecoder().decode([Item].self, from: data)

        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].key, sample()[0].key)
        XCTAssertEqual(back[0].destinationName, "2024-06-extracto.pdf")
        XCTAssertEqual(back[0].status, .decrypted)
        XCTAssertEqual(back[0].message, "note")
        XCTAssertEqual(back[0].byteCount, 4096)
        XCTAssertEqual(back[0].pageCount, 12)
        XCTAssertEqual(back[0].documentInfo["Title"], "Extracto")
        XCTAssertEqual(back[0].relativePath, "bank/Extracto.pdf")
    }

    /// The identity that matters is derived from the path, not from a per-process UUID,
    /// so a decoded item still matches the one it came from.
    func testKeysMatchAcrossEncoding() throws {
        let original = sample()[0]
        let decoded = try JSONDecoder().decode(Item.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(original.key, decoded.key)
        XCTAssertNotEqual(original.id, decoded.id, "ids are per process and are not stored")
    }

    func testTheCacheOnlyAnswersForTheSameSources() {
        let cache = RunCache(fingerprint: "sources-A", items: sample())
        saveRunCache(cache)
        defer { clearRunCache() }

        XCTAssertNotNil(loadRunCache(matching: "sources-A"))
        XCTAssertNil(loadRunCache(matching: "sources-B"), "a different selection must not reuse it")
        XCTAssertEqual(loadRunCache(matching: "sources-A")?.items.count, 1)

        clearRunCache()
        XCTAssertNil(loadRunCache(matching: "sources-A"))
    }
}
