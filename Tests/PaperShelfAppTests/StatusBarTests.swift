import XCTest
@testable import PaperShelf

/// The bar along the bottom answers two questions a shelf of fourteen thousand books
/// raises constantly: how big is this, and when did I last read that.
final class StatusBarTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testWhenAFileWasLastOpenedIsSaidTheWayAPersonWouldSayIt() {
        func label(_ ago: TimeInterval) -> String {
            openedLabel(now.addingTimeInterval(-ago), now: now)
        }

        XCTAssertEqual(label(60), "opened in the last hour")
        XCTAssertEqual(label(7 * 3600), "opened today")
        XCTAssertEqual(label(30 * 3600), "opened yesterday")
        XCTAssertEqual(label(5 * 86_400), "opened 5 days ago")
        XCTAssertEqual(label(70 * 86_400), "opened 2 months ago")
        XCTAssertEqual(label(800 * 86_400), "opened 2 years ago")
    }

    /// A clock that has gone backwards, or a file written by a machine a minute ahead, is
    /// not a file opened in negative time.
    func testAFutureDateReadsAsJustNow() {
        XCTAssertEqual(openedLabel(now.addingTimeInterval(120), now: now), "opened just now")
    }
}
