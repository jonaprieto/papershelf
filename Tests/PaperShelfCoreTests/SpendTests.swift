import XCTest
@testable import PaperShelfCore

final class SpendTests: XCTestCase {

    // MARK: - parseTokenUsage

    func testParseTokenUsageReadsOptionalDetailFields() {
        let object: [String: Any] = ["usage": [
            "prompt_tokens": 10, "completion_tokens": 5,
            "prompt_tokens_details": ["cached_tokens": 3],
            "completion_tokens_details": ["reasoning_tokens": 2],
        ]]
        XCTAssertEqual(parseTokenUsage(object),
                        TokenUsage(promptTokens: 10, completionTokens: 5, cachedTokens: 3, reasoningTokens: 2))
    }

    func testParseTokenUsageDefaultsMissingDetailsToZero() {
        let object: [String: Any] = ["usage": ["prompt_tokens": 10, "completion_tokens": 5]]
        XCTAssertEqual(parseTokenUsage(object), TokenUsage(promptTokens: 10, completionTokens: 5))
    }

    func testParseTokenUsageReturnsNilWithoutRequiredFields() {
        XCTAssertNil(parseTokenUsage(["usage": ["prompt_tokens": 10]]), "completion_tokens is missing")
        XCTAssertNil(parseTokenUsage([:]))
    }

    // MARK: - identifyOutcome
    //
    // The one behaviour these exist to pin down: a 2xx reply the provider has already
    // billed for must keep its usage even when the content inside it never becomes a
    // usable BookGuess. AI.swift's own identify() has no test target, so this pure
    // function is the only place that contract is checked in CI.

    private func chatResponse(content: String?, usage: [String: Any]?) -> Data {
        var object: [String: Any] = [:]
        if let content { object["choices"] = [["message": ["content": content]]] }
        if let usage { object["usage"] = usage }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testIdentifyOutcomeReturnsGuessAndUsageOnSuccess() {
        let data = chatResponse(
            content: #"{"title": "Dune", "author": "Herbert", "year": "1965"}"#,
            usage: ["prompt_tokens": 120, "completion_tokens": 40,
                    "prompt_tokens_details": ["cached_tokens": 20],
                    "completion_tokens_details": ["reasoning_tokens": 5]])
        let outcome = identifyOutcome(responseBody: data, statusCode: 200)
        XCTAssertEqual(outcome.guess, BookGuess(title: "Dune", author: "Herbert", year: "1965"))
        XCTAssertEqual(outcome.usage, TokenUsage(promptTokens: 120, completionTokens: 40,
                                                  cachedTokens: 20, reasoningTokens: 5))
        XCTAssertNil(outcome.failureReason)
    }

    func testIdentifyOutcomeKeepsUsageWhenContentDoesNotParse() {
        let data = chatResponse(content: "Sorry, I could not read this file.",
                                 usage: ["prompt_tokens": 300, "completion_tokens": 12])
        let outcome = identifyOutcome(responseBody: data, statusCode: 200)
        XCTAssertNil(outcome.guess)
        XCTAssertEqual(outcome.usage, TokenUsage(promptTokens: 300, completionTokens: 12),
                        "the provider billed for this reply even though its content was useless")
        XCTAssertEqual(outcome.failureReason, "Sorry, I could not read this file.")
    }

    func testIdentifyOutcomeHasNoUsageOnHTTPError() {
        let data = #"{"error": {"message": "rate limited"}}"#.data(using: .utf8)!
        let outcome = identifyOutcome(responseBody: data, statusCode: 429)
        XCTAssertNil(outcome.guess)
        XCTAssertNil(outcome.usage)
        XCTAssertEqual(outcome.failureReason, #"{"error": {"message": "rate limited"}}"#)
    }

    func testIdentifyOutcomeHandlesAnUnparseableBody() {
        let data = "not json".data(using: .utf8)!
        let outcome = identifyOutcome(responseBody: data, statusCode: 200)
        XCTAssertNil(outcome.guess)
        XCTAssertNil(outcome.usage)
        XCTAssertEqual(outcome.failureReason, "")
    }

    // MARK: - cost, exact and rounded

    private func price(input: Decimal, cachedInput: Decimal? = nil, output: Decimal,
                        currency: String = "USD") -> ModelPrice {
        ModelPrice(inputPerMillion: input, cachedInputPerMillion: cachedInput, outputPerMillion: output,
                   currency: currency, recordedAt: Date(timeIntervalSince1970: 0))
    }

    func testCostIsExactWhereDoubleWouldDrift() {
        // 1,000,000 prompt + 500,000 completion tokens at $0.15 / $0.60 per million is
        // exactly $0.15 + $0.30 = $0.45; Decimal must land on it precisely.
        let usage = TokenUsage(promptTokens: 1_000_000, completionTokens: 500_000)
        let result = cost(usage: usage, price: price(input: 0.15, output: 0.60))
        XCTAssertEqual(result.amount, Decimal(string: "0.45"))
        XCTAssertEqual(result.currency, "USD")
    }

    func testCostUsesInputRateWhenNoCachedRateGiven() {
        let usage = TokenUsage(promptTokens: 100, completionTokens: 0, cachedTokens: 100)
        let result = cost(usage: usage, price: price(input: 1, output: 1))
        XCTAssertEqual(result.amount, Decimal(string: "0.0001"))
    }

    func testCostSplitsRegularAndCachedPromptTokensAtDifferentRates() {
        // 60 regular tokens at $2/M + 40 cached tokens at $0.5/M.
        let usage = TokenUsage(promptTokens: 100, completionTokens: 0, cachedTokens: 40)
        let result = cost(usage: usage, price: price(input: 2, cachedInput: 0.5, output: 1))
        XCTAssertEqual(result.amount, Decimal(string: "0.00014"))
    }

    func testCostRoundsToSixDecimalPlaces() {
        let usage = TokenUsage(promptTokens: 7, completionTokens: 0)
        let result = cost(usage: usage, price: price(input: Decimal(string: "1.23456789")!, output: 1))
        XCTAssertEqual(result.amount, Decimal(string: "0.000009"))
    }

    // MARK: - PriceTable

    func testCustomKeyNormalizesTrailingSlashAndWhitespace() {
        XCTAssertEqual(PriceTable.customKey(endpoint: "https://host/v1/", model: "m"),
                       PriceTable.customKey(endpoint: " https://host/v1 ", model: "m"))
    }

    func testSeededPricesOnlyApplyToOpenAIsOwnEndpoint() {
        let table = PriceTable()
        XCTAssertNotNil(table.price(model: "gpt-4o-mini", endpoint: "https://api.openai.com/v1"))
        XCTAssertNil(table.price(model: "gpt-4o-mini", endpoint: "https://my-proxy.example.com/v1"),
                     "a seeded OpenAI price must never be guessed onto a different provider's model of the same name")
    }

    func testCustomPriceOverridesSeeded() {
        var table = PriceTable()
        let override = price(input: 99, output: 99)
        table.custom[PriceTable.customKey(endpoint: "https://api.openai.com/v1", model: "gpt-4o-mini")] = override
        XCTAssertEqual(table.price(model: "gpt-4o-mini", endpoint: "https://api.openai.com/v1"), override)
    }

    func testUnknownModelReturnsNilNotZero() {
        let table = PriceTable()
        XCTAssertNil(table.price(model: "some-brand-new-model", endpoint: "https://api.openai.com/v1"))
    }

    func testCustomPricePersistsThroughASeparateDefaultsSuite() {
        let suiteName = "SpendTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let empty = PriceTable.loadCustom(from: defaults)
        XCTAssertTrue(empty.custom.isEmpty)

        var table = PriceTable.loadCustom(from: defaults)
        let mine = price(input: 3, output: 6, currency: "EUR")
        table.setCustom(mine, endpoint: "https://local.example.com/v1", model: "local-model", in: defaults)

        let reloaded = PriceTable.loadCustom(from: defaults)
        XCTAssertEqual(reloaded.price(model: "local-model", endpoint: "https://local.example.com/v1"), mine)
    }

    // MARK: - spendTotals

    private func record(model: String = "gpt-4o-mini", feature: AIFeature = .identify,
                         cost costValue: Money? = nil, succeeded: Bool = true,
                         at timestamp: Date = Date(timeIntervalSince1970: 1_000)) -> SpendRecord {
        SpendRecord(id: Int64.random(in: 1...1_000_000), timestamp: timestamp, model: model,
                    endpoint: "https://api.openai.com/v1", feature: feature,
                    usage: TokenUsage(promptTokens: 10, completionTokens: 5), cost: costValue, succeeded: succeeded)
    }

    func testSpendTotalsGroupsCostByCurrencyRatherThanSumming() {
        let entries = [
            record(cost: Money(amount: 1, currency: "USD")),
            record(cost: Money(amount: 2, currency: "EUR")),
        ]
        let totals = spendTotals(for: entries)
        XCTAssertEqual(totals.byCurrency, ["USD": 1, "EUR": 2],
                        "a dollar and a euro must never be added into one figure")
        XCTAssertEqual(totals.calls, 2)
        XCTAssertEqual(totals.callsWithUnknownCost, 0)
    }

    func testSpendTotalsCountsUnknownCostSeparatelyRatherThanAsZero() {
        let entries = [record(cost: Money(amount: 1, currency: "USD")), record(cost: nil)]
        let totals = spendTotals(for: entries)
        XCTAssertEqual(totals.byCurrency, ["USD": 1])
        XCTAssertEqual(totals.callsWithUnknownCost, 1, "an unpriced call must not be folded in as free")
    }

    func testSpendTotalsCountsFailedCallsSeparately() {
        let entries = [record(succeeded: true), record(succeeded: false), record(succeeded: false)]
        let totals = spendTotals(for: entries)
        XCTAssertEqual(totals.calls, 3)
        XCTAssertEqual(totals.failedCalls, 2)
    }

    func testSpendTotalsGroupedByModel() {
        let entries = [record(model: "gpt-4o-mini"), record(model: "gpt-4o-mini"), record(model: "gpt-4o")]
        let byModel = spendTotals(for: entries, groupedBy: \.model)
        XCTAssertEqual(byModel["gpt-4o-mini"]?.calls, 2)
        XCTAssertEqual(byModel["gpt-4o"]?.calls, 1)
    }

    func testSpendTotalsGroupedByFeature() {
        let entries = [record(feature: .identify), record(feature: .batchIdentify), record(feature: .identify)]
        let byFeature = spendTotals(for: entries, groupedBy: \.feature)
        XCTAssertEqual(byFeature[.identify]?.calls, 2)
        XCTAssertEqual(byFeature[.batchIdentify]?.calls, 1)
    }

    func testSpendTotalsSinceFiltersOlderEntries() {
        let cutoff = Date(timeIntervalSince1970: 2_000)
        let entries = [
            record(at: Date(timeIntervalSince1970: 1_000)),
            record(at: Date(timeIntervalSince1970: 2_000)),
            record(at: Date(timeIntervalSince1970: 3_000)),
        ]
        let totals = spendTotals(for: entries, since: cutoff)
        XCTAssertEqual(totals.calls, 2)
    }

    // MARK: - AIFeature

    func testAIFeatureRawValuesAreStable() {
        // These strings are what lands in the `feature` column; changing one silently
        // orphans every historical row already written with the old spelling.
        XCTAssertEqual(AIFeature.identify.rawValue, "identify")
        XCTAssertEqual(AIFeature.batchIdentify.rawValue, "batchIdentify")
        XCTAssertEqual(AIFeature.connectionTest.rawValue, "connectionTest")
        XCTAssertEqual(AIFeature.noteTranscription.rawValue, "noteTranscription")
    }
}

/// The ledger against a real database. The rest of these tests work on values, which left
/// the one seam that talks to SQLite, and therefore the table and column names, uncovered.
final class SpendLedgerTests: XCTestCase {

    private func temporaryLibrary() throws -> (Library, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spend-\(UUID().uuidString).sqlite")
        return (try Library(url: url), url)
    }

    func testACallIsRecordedAndReadBack() async throws {
        let (library, url) = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: url) }

        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try await library.recordSpend(
            timestamp: when, model: "gpt-5", endpoint: "https://api.openai.com/v1",
            feature: .identify,
            usage: TokenUsage(promptTokens: 1200, completionTokens: 80, cachedTokens: 400),
            cost: Money(amount: Decimal(string: "0.0123")!, currency: "USD"),
            succeeded: true)

        let entries = try await library.spendEntries()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.model, "gpt-5")
        XCTAssertEqual(entry.feature, .identify)
        XCTAssertEqual(entry.usage.promptTokens, 1200)
        XCTAssertEqual(entry.usage.cachedTokens, 400)
        XCTAssertEqual(entry.cost?.amount, Decimal(string: "0.0123"))
        XCTAssertEqual(entry.cost?.currency, "USD")
        XCTAssertTrue(entry.succeeded)
        XCTAssertEqual(entry.timestamp.timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 1)
    }

    /// A model with no known price still costs money and still gets recorded. Storing that
    /// as zero is the failure this ledger exists to prevent.
    func testAnUnknownPriceIsRecordedAsUnknownRatherThanZero() async throws {
        let (library, url) = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: url) }

        try await library.recordSpend(
            timestamp: Date(), model: "someone-elses-model", endpoint: "http://localhost:1234/v1",
            feature: .identify, usage: TokenUsage(promptTokens: 10, completionTokens: 5),
            cost: nil, succeeded: true)

        let recorded = try await library.spendEntries()
        let entry = try XCTUnwrap(recorded.first)
        XCTAssertNil(entry.cost, "an unknown price must not come back as an amount")
    }

    /// A call the provider billed for and then failed to answer usefully is the one most
    /// worth seeing, so it has to be in the ledger too.
    func testAFailedCallIsStillRecorded() async throws {
        let (library, url) = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: url) }

        try await library.recordSpend(
            timestamp: Date(), model: "gpt-5", endpoint: "https://api.openai.com/v1",
            feature: .identify, usage: TokenUsage(promptTokens: 900, completionTokens: 40),
            cost: Money(amount: Decimal(string: "0.005")!, currency: "USD"), succeeded: false)

        let recorded = try await library.spendEntries()
        let entry = try XCTUnwrap(recorded.first)
        XCTAssertFalse(entry.succeeded)
        XCTAssertEqual(entry.usage.promptTokens, 900)
    }

    func testEntriesCanBeReadFromAPointInTime() async throws {
        let (library, url) = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: url) }

        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let recent = Date(timeIntervalSince1970: 1_700_000_000)
        for when in [old, recent] {
            try await library.recordSpend(
                timestamp: when, model: "gpt-5", endpoint: "e", feature: .identify,
                usage: TokenUsage(promptTokens: 1, completionTokens: 1),
                cost: nil, succeeded: true)
        }

        let all = try await library.spendEntries()
        let session = try await library.spendEntries(since: recent.addingTimeInterval(-60))
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.map(\.timestamp), [old, recent].map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded()) },
                       "oldest first, so a running total reads in the order it happened")
        XCTAssertEqual(session.count, 1, "a session total is this: everything since the app started")
    }
}

extension SpendTests {

    /// The user picked gpt-5.5-pro and was told the price was unknown, because the table
    /// only knew the models that existed when it was written.
    func testTheCurrentModelsHaveAPrice() {
        let table = PriceTable()
        for model in ["gpt-5.5", "gpt-5.5-pro", "gpt-5.1", "gpt-5-pro", "gpt-5", "gpt-5-mini"] {
            XCTAssertNotNil(table.price(model: model, endpoint: "https://api.openai.com/v1"),
                            "no price for \(model)")
        }
        XCTAssertEqual(table.price(model: "gpt-5.5-pro",
                                   endpoint: "https://api.openai.com/v1")?.outputPerMillion,
                       Decimal(string: "180.00"))
    }

    /// A dated id is the same model, and the longest name wins so the pro variant is not
    /// priced as the cheaper one it shares a prefix with.
    func testADatedModelIdIsPricedAsItsBaseModel() {
        let table = PriceTable()
        let endpoint = "https://api.openai.com/v1"
        XCTAssertEqual(table.price(model: "gpt-5.1-2026-03-11", endpoint: endpoint)?.inputPerMillion,
                       table.price(model: "gpt-5.1", endpoint: endpoint)?.inputPerMillion)
        XCTAssertEqual(table.price(model: "gpt-5.5-pro-2026-05-01", endpoint: endpoint)?.outputPerMillion,
                       Decimal(string: "180.00"),
                       "the pro variant must not be priced as plain gpt-5.5")
    }

    /// A name this table has never heard of stays unknown rather than borrowing a price.
    func testAnUnrelatedModelIsStillUnknown() {
        let table = PriceTable()
        XCTAssertNil(table.price(model: "llama-3-70b", endpoint: "https://api.openai.com/v1"))
        XCTAssertNil(table.price(model: "gpt-5", endpoint: "http://localhost:1234/v1"),
                     "someone else's endpoint does not bill at OpenAI's rates")
    }
}
