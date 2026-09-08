import XCTest
@testable import PaperShelf

final class OperationTimingTests: XCTestCase {
    func testTimingLabelUsesReadableUnits() {
        XCTAssertEqual(OperationTiming(name: "Refresh", seconds: 0.042).label, "Refresh 42 ms")
        XCTAssertEqual(OperationTiming(name: "Refresh", seconds: 1.25).label, "Refresh 1.25 s")
        XCTAssertEqual(OperationTiming(name: "Refresh", seconds: 12.34).label, "Refresh 12.3 s")
    }
}
