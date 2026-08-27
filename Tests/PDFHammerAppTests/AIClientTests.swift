import XCTest
import PDFHammerCore
@testable import PDFHammer

/// The app target's first tests.
///
/// It had none, which is exactly how the bug these cover survived: `AIClient` took a spend
/// recorder that defaulted to nil, four of the five places that build a client did not
/// pass one, and every real call in the app recorded nothing while the whole ledger
/// feature sat there looking finished. A reviewer reverted the fix and the entire suite
/// still passed.
final class AIClientTests: XCTestCase {

    func testAClientRecordsSpendWithoutBeingAskedTo() {
        let client = AIClient(baseURL: "https://api.openai.com/v1", model: "gpt-5", apiKey: "k")
        XCTAssertNotNil(client.spendRecorder,
                        "a client built the ordinary way must record what it spends")
    }

    /// Opting out stays possible; it just has to be deliberate.
    func testARecorderCanStillBeRefusedOnPurpose() {
        let client = AIClient(baseURL: "https://api.openai.com/v1", model: "gpt-5", apiKey: "k",
                              spendRecorder: nil)
        XCTAssertNil(client.spendRecorder)
    }

    /// The library is the recorder, so a call made through a default client lands in the
    /// same ledger the interface reads.
    func testTheDefaultRecorderIsTheLibrary() {
        let client = AIClient(baseURL: "https://api.openai.com/v1", model: "gpt-5", apiKey: "k")
        XCTAssertTrue(client.spendRecorder is Library,
                      "got \(String(describing: client.spendRecorder))")
    }
}
