import XCTest
import PaperShelfCore
@testable import PaperShelf

/// The app target's first tests.
///
/// It had none, which is exactly how the bug these cover survived: `AIClient` took a spend
/// recorder that defaulted to nil, four of the five places that build a client did not
/// pass one, and every real call in the app recorded nothing while the whole ledger
/// feature sat there looking finished. A reviewer reverted the fix and the entire suite
/// still passed.
final class AIClientTests: XCTestCase {

    /// Constructing a client reaches for `Library.shared`, which opens the store at the
    /// standard path. Left alone, running these tests would open and migrate the library a
    /// person keeps their books in, so the suite is pointed at a scratch file instead.
    override class func setUp() {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("papershelf-tests-\(UUID().uuidString).sqlite")
        setenv("PAPERSHELF_LIBRARY_PATH", scratch.path, 1)
    }

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

    func testTranscriptionMultipartBodyCarriesTheModelAndAudio() {
        let boundary = "test-boundary"
        let body = audioMultipartBody(audio: Data([1, 2, 3]), filename: "note.m4a",
                                      model: "gpt-4o-transcribe", boundary: boundary)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"model\""))
        XCTAssertTrue(text.contains("gpt-4o-transcribe"))
        XCTAssertTrue(text.contains("filename=\"note.m4a\""))
        XCTAssertNotNil(body.range(of: Data([1, 2, 3])))
        XCTAssertTrue(text.contains("--test-boundary--"))
    }

    func testTranscriptionRequiresAnAPIKeyBeforeNetworking() async {
        do {
            _ = try await AIClient(baseURL: "https://example.invalid/v1", model: "test", apiKey: "")
                .transcribe(audio: Data())
            XCTFail("a transcription without a key must not reach the network")
        } catch let error as AIError {
            XCTAssertEqual(error.errorDescription,
                           "No API key. Add one in Settings, or set OPENAI_API_KEY before launching.")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
