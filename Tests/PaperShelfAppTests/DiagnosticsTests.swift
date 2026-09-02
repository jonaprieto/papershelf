import XCTest
@testable import PaperShelf

final class DiagnosticsTests: XCTestCase {
    func testDiagnosticsRecordIsWrittenToShareableURL() throws {
        let marker = "diagnostics-test-\(UUID().uuidString)"
        let diagnostics = AppDiagnostics.shared
        diagnostics.record(marker)

        XCTAssertTrue(FileManager.default.fileExists(atPath: diagnostics.url.path))
        XCTAssertTrue(try String(contentsOf: diagnostics.url, encoding: .utf8).contains(marker))
    }
}
