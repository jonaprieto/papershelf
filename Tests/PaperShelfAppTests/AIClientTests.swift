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

    func testLocalEndpointsNeedNoCloudKey() throws {
        for base in ["http://localhost:1234/v1", "http://127.0.0.1:8080/v1/", "http://[::1]:8080/v1"] {
            let client = AIClient(baseURL: base, model: "local-model", apiKey: "", spendRecorder: nil)
            let request = try client.request(path: "chat/completions")
            XCTAssertTrue(client.isConfigured)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertTrue(request.url!.path.hasSuffix("/v1/chat/completions"))
        }
        for base in ["https://localhost.example.org/v1", "https://example.org/v1", "http://192.168.1.4/v1"] {
            XCTAssertThrowsError(try AIClient(baseURL: base, model: "test", apiKey: "", spendRecorder: nil).request(path: "models"))
        }
    }

    @MainActor
    func testDisablingAIBlocksEveryRequestAndCancelsPendingWork() async throws {
        let wasEnabled = Prefs.shared.aiEnabled
        let previousSession = AIRequests.session
        defer {
            AIRequests.session.invalidateAndCancel()
            AIRequests.session = previousSession
            Prefs.shared.aiEnabled = wasEnabled
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalAIProtocol.self]
        AIRequests.session = URLSession(configuration: configuration)
        Prefs.shared.aiEnabled = true
        LocalAIProtocol.holding = false
        LocalAIProtocol.started = nil
        let client = AIClient(baseURL: "http://localhost:1234/v1", model: "local-model", apiKey: "", spendRecorder: nil)
        let answer = try await client.ask(system: "Test", user: "A local question", feature: .readingAssistant)
        XCTAssertEqual(answer, "Local answer")

        LocalAIProtocol.holding = true
        let started = expectation(description: "Local request started")
        LocalAIProtocol.started = { started.fulfill() }
        let pending = Task { try await client.ask(system: "Test", user: "Pending", feature: .readingAssistant) }
        await fulfillment(of: [started], timeout: 2)
        Prefs.shared.aiEnabled = false
        do { _ = try await pending.value; XCTFail("Disabling AI must cancel a pending request") }
        catch { XCTAssertEqual((error as NSError).code, NSURLErrorCancelled) }
        LocalAIProtocol.started = nil

        let calls: [() async throws -> Void] = [
            { _ = try await client.models() },
            { _ = try await client.identify(filename: "test.pdf", excerpt: "test") },
            { _ = try await client.ask(system: "Test", user: "Blocked", feature: .readingAssistant) },
            { _ = try await client.transcribe(audio: Data()) },
        ]
        for call in calls {
            do { try await call(); XCTFail("AI-off must refuse before networking") }
            catch AIError.disabled { }
            catch { XCTFail("Wrong error: \(error)") }
        }
        XCTAssertFalse(ChatGPTHandoff.open("Do not open"))
        XCTAssertFalse(ChatGPTHandoff.isInstalled)
        XCTAssertEqual(resolvedKey(useEnvironment: true), "")
    }

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

    func testLoginShellReadsZshrcForFinderLaunches() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("papershelf-zshrc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("export OPENAI_API_KEY=from-zshrc\n".utf8)
            .write(to: home.appendingPathComponent(".zshrc"))

        XCTAssertEqual(AIClient.loginShellKey(shell: "/bin/zsh", home: home.path), "from-zshrc")
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

private final class LocalAIProtocol: URLProtocol {
    static var holding = false
    static var started: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.started?()
        guard !Self.holding else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"content":"Local answer"}}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
