import XCTest
import PaperShelfCore
@testable import PaperShelf

@MainActor
final class ReleaseUpdatesTests: XCTestCase {
    private func store() -> UserDefaults {
        let name = "ReleaseUpdatesTests.\(UUID())"
        let store = UserDefaults(suiteName: name)!
        addTeardownBlock { store.removePersistentDomain(forName: name) }
        return store
    }

    private func build(_ version: String = "1.9.0") -> AppBuild {
        AppBuild(info: ["CFBundleShortVersionString": version], at: URL(fileURLWithPath: "/tmp/Test.app"))
    }

    private func payload(_ tag: String = "v1.10.0", changes: [String: Any] = [:]) throws -> Data {
        var body: [String: Any] = ["tag_name": tag,
            "html_url": "https://github.com/jonaprieto/papershelf/releases/tag/\(tag)",
            "draft": false, "prerelease": false,
            "assets": [["name": "PaperShelf-\(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag).dmg",
                        "state": "uploaded", "size": 123]]]
        body.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: body)
    }

    func testNumericVersionsAndReleaseValidation() throws {
        XCTAssertLessThan(StableVersion("v1.9.0")!, StableVersion("1.10.0")!)
        XCTAssertEqual(StableVersion("v1.10.0"), StableVersion("1.10.0"))
        for invalid in ["", "1.2", "1.2.3.4", "1..3", "01.2.3", "1.2.3-beta", "1.2.3+dirty",
                        " 1.2.3", "1.2.3\n", "-1.2.3", "١.2.3", "9999999999999999999999.0.0"] {
            XCTAssertNil(StableVersion(invalid), invalid)
        }
        let decoder = JSONDecoder()
        XCTAssertTrue(try decoder.decode(PublishedRelease.self, from: payload()).isValid)
        for changes: [String: Any] in [["draft": true], ["prerelease": true], ["assets": []],
            ["assets": [["name": "PaperShelf-1.10.0.dmg", "state": "starter", "size": 123]]],
            ["assets": [["name": "PaperShelf-1.10.0.dmg", "state": "uploaded", "size": 0]]],
            ["html_url": "http://github.com/jonaprieto/papershelf/releases/tag/v1.10.0"],
            ["html_url": "https://github.com/other/papershelf/releases/tag/v1.10.0"],
            ["html_url": "https://github.com.evil.test/jonaprieto/papershelf/releases/tag/v1.10.0"],
            ["html_url": "https://user@github.com/jonaprieto/papershelf/releases/tag/v1.10.0"],
            ["html_url": "https://github.com/jonaprieto/papershelf/releases/tag/v1.11.0"]] {
            XCTAssertFalse(try decoder.decode(PublishedRelease.self, from: payload(changes: changes)).isValid)
        }
    }

    func testCachingDismissalAndFailedVerification() async throws {
        let defaults = store()
        let network = UpdateNetwork(data: try payload())
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        let checker = ReleaseUpdates(running: build(), defaults: defaults, now: { time }, fetch: { try await network.fetch($0) })
        await checker.check(manual: false, automaticChecks: false)
        let firstCount = await network.count
        XCTAssertEqual(firstCount, 0)
        await checker.check(manual: true, automaticChecks: false)
        XCTAssertTrue(checker.showsBadge)
        XCTAssertEqual(checker.lastSuccess, time)
        checker.dismissRelease()
        XCTAssertFalse(checker.showsBadge)
        XCTAssertNotNil(checker.newerRelease)
        let restored = ReleaseUpdates(running: build(), defaults: defaults, fetch: { try await network.fetch($0) })
        XCTAssertFalse(restored.showsBadge)
        XCTAssertEqual(restored.release?.version, StableVersion("1.10.0"))
        XCTAssertFalse(restored.statusText.contains("up to date"))
        var releaseInfo: [String: Any] = ["CFBundleShortVersionString": "1.10.0", "PaperShelfBuildChannel": "release"]
        let released = ReleaseUpdates(running: AppBuild(info: releaseInfo, at: build().bundleURL), defaults: defaults,
                                      fetch: { try await network.fetch($0) })
        XCTAssertEqual(released.statusText, "Your release is up to date.")
        releaseInfo["CFBundleShortVersionString"] = "1.11.0"
        XCTAssertEqual(ReleaseUpdates(running: AppBuild(info: releaseInfo, at: build().bundleURL), defaults: defaults,
                                      fetch: { try await network.fetch($0) }).statusText,
                       "Your version is newer than the latest published release.")
        for current in ["1.10.0", "1.11.0"] {
            XCTAssertNil(ReleaseUpdates(running: build(current), defaults: defaults, fetch: { try await network.fetch($0) }).newerRelease)
        }
        await checker.check(manual: false, automaticChecks: true)
        let throttledCount = await network.count
        XCTAssertEqual(throttledCount, 1)
        time = time.addingTimeInterval(86_401)
        await network.set(data: try payload("v1.11.0"))
        await checker.check(manual: false, automaticChecks: true)
        XCTAssertTrue(checker.showsBadge)
        let success = checker.lastSuccess
        for error in [URLError.notConnectedToInternet, .timedOut] {
            await network.set(error: error)
            await checker.check(manual: true, automaticChecks: false)
            XCTAssertNotNil(checker.failure)
            XCTAssertTrue(checker.statusText.hasPrefix("Could not verify"))
            XCTAssertEqual(checker.lastSuccess, success)
            XCTAssertEqual(checker.release?.version, StableVersion("1.11.0"))
        }
        await network.set(data: Data("invalid".utf8))
        await checker.check(manual: true, automaticChecks: false)
        XCTAssertNotNil(checker.failure)
        XCTAssertEqual(checker.lastSuccess, success)
    }

    func testRetryInstructionsPersistAndOnlyOneRequestRuns() async throws {
        let defaults = store()
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        let network = UpdateNetwork(data: try payload(), status: 429,
                                    headers: ["Retry-After": "120", "X-RateLimit-Remaining": "0",
                                              "X-RateLimit-Reset": "1800000300"])
        let checker = ReleaseUpdates(running: build(), defaults: defaults, now: { time }, fetch: { try await network.fetch($0) })
        await checker.check(manual: true, automaticChecks: false)
        XCTAssertEqual(checker.retryAfter, time.addingTimeInterval(300))
        let restored = ReleaseUpdates(running: build(), defaults: defaults, now: { time }, fetch: { try await network.fetch($0) })
        await restored.check(manual: true, automaticChecks: false)
        let count = await network.count
        XCTAssertEqual(count, 1)
        XCTAssertNotNil(restored.failure)
        time = time.addingTimeInterval(301)
        await network.set(data: try payload(), delay: true)
        let first = Task { await checker.check(manual: true, automaticChecks: false) }
        while !checker.checking { await Task.yield() }
        await checker.check(manual: true, automaticChecks: false)
        await first.value
        let finalCount = await network.count
        XCTAssertEqual(finalCount, 2)
        XCTAssertNil(checker.failure)
        XCTAssertNil(checker.retryAfter)
        XCTAssertNotNil(checker.lastSuccess)
    }
}

private actor UpdateNetwork {
    var data: Data
    var status: Int
    var headers: [String: String]
    var error: URLError.Code?
    var delay = false
    var count = 0

    init(data: Data, status: Int = 200, headers: [String: String] = [:]) {
        self.data = data
        self.status = status
        self.headers = headers
    }
    func set(data: Data, delay: Bool = false) {
        self.data = data; self.status = 200; self.headers = [:]; self.error = nil; self.delay = delay
    }
    func set(error: URLError.Code) { self.error = error }
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        count += 1
        XCTAssertEqual(request.url, ReleaseUpdates.endpoint)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.timeoutInterval, 15)
        if delay { try await Task.sleep(for: .milliseconds(50)) }
        if let error { throw URLError(error) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}
