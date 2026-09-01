import Foundation
import SQLite3

// MARK: - Money

/// ISO 4217, e.g. "USD". A plain String rather than an enum: the app talks to any
/// OpenAI-compatible endpoint, and a fixed case list would either omit a real currency or
/// have to be maintained forever for no benefit over trusting the three letters as given.
public typealias CurrencyCode = String

/// An exact amount in one currency. Decimal, never Double: a rate like $0.15 per million
/// tokens is an exact decimal fraction, and Double's binary floating point cannot hold
/// most of them exactly, so a running total in Double drifts by a small but real amount
/// over many calls. Decimal does base-10 arithmetic, so it stays exact to its own
/// precision. The currency travels with the amount always, on purpose: a bare number is
/// meaningless once a user can point baseURL at a provider that does not bill in dollars.
public struct Money: Sendable, Equatable {
    public var amount: Decimal
    public var currency: CurrencyCode

    public init(amount: Decimal, currency: CurrencyCode) {
        self.amount = amount
        self.currency = currency
    }
}

// MARK: - Pricing

/// Per-million-token pricing for one model, in one currency. Providers publish rates this
/// way, so this stores them this way too and only divides down to a per-token rate at the
/// point of a calculation. `recordedAt` is not decoration: a price with no date attached
/// is a number nobody can judge as fresh or stale.
public struct ModelPrice: Sendable, Equatable, Codable {
    public var inputPerMillion: Decimal
    public var cachedInputPerMillion: Decimal?   // nil => cached tokens bill at inputPerMillion
    public var outputPerMillion: Decimal
    public var currency: CurrencyCode
    public var recordedAt: Date                  // when this rate was verified, or last edited

    public init(inputPerMillion: Decimal, cachedInputPerMillion: Decimal? = nil,
                outputPerMillion: Decimal, currency: CurrencyCode, recordedAt: Date) {
        self.inputPerMillion = inputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
        self.outputPerMillion = outputPerMillion
        self.currency = currency
        self.recordedAt = recordedAt
    }
}

/// Seeded OpenAI prices, plus whatever the user has added or corrected for their own
/// endpoint. Seeded entries apply only under OpenAI's own base URL; a custom entry always
/// wins, since the user typed it in for exactly their own (endpoint, model) pair. A model
/// this table has never heard of returns nil from `price(model:endpoint:)`, not zero: an
/// unpriced call is unknown cost, never free cost.
public struct PriceTable: Sendable {
    public var custom: [String: ModelPrice]   // key: customKey(endpoint:model:), user-entered

    public init(custom: [String: ModelPrice] = [:]) {
        self.custom = custom
    }

    /// 2026-08-27, fetched from developers.openai.com/api/docs/pricing (see
    /// docs/design/ai-cost.md). Only models plausible for this app's filename+excerpt
    /// classification task are included; newer models postdating this fetch are left out
    /// rather than guessed at, per the same document's own risk notes.
    public static let seededVerifiedAt: Date = ISO8601DateFormatter().date(from: "2026-08-27T00:00:00Z")!

    public static let seeded: [String: ModelPrice] = [
        "gpt-4o-mini": ModelPrice(inputPerMillion: 0.15, cachedInputPerMillion: 0.075,
                                   outputPerMillion: 0.60, currency: "USD", recordedAt: seededVerifiedAt),
        "gpt-4o": ModelPrice(inputPerMillion: 2.50, cachedInputPerMillion: 1.25,
                              outputPerMillion: 10.00, currency: "USD", recordedAt: seededVerifiedAt),
        "gpt-4.1": ModelPrice(inputPerMillion: 2.00, cachedInputPerMillion: 0.50,
                               outputPerMillion: 8.00, currency: "USD", recordedAt: seededVerifiedAt),
        "gpt-4.1-mini": ModelPrice(inputPerMillion: 0.40, cachedInputPerMillion: 0.10,
                                    outputPerMillion: 1.60, currency: "USD", recordedAt: seededVerifiedAt),
        "gpt-4.1-nano": ModelPrice(inputPerMillion: 0.10, cachedInputPerMillion: 0.025,
                                    outputPerMillion: 0.40, currency: "USD", recordedAt: seededVerifiedAt),
        // The 5.5 pair are priced for the short-context tier, which is what a request from
        // this app is: it sends a filename and a few pages, never 272K tokens.
        "gpt-5.5": ModelPrice(inputPerMillion: 5.00, cachedInputPerMillion: 0.50,
                               outputPerMillion: 30.00, currency: "USD", recordedAt: seededVerifiedAt),
        "gpt-5.5-pro": ModelPrice(inputPerMillion: 30.00, cachedInputPerMillion: nil,
                                   outputPerMillion: 180.00, currency: "USD", recordedAt: seededVerifiedAt),
        "gpt-5.1": ModelPrice(inputPerMillion: 1.25, cachedInputPerMillion: 0.125,
                               outputPerMillion: 10.00, currency: "USD", recordedAt: seededVerifiedAt),
        "gpt-5-pro": ModelPrice(inputPerMillion: 15.00, cachedInputPerMillion: nil,
                                 outputPerMillion: 120.00, currency: "USD", recordedAt: seededVerifiedAt),
        "gpt-5": ModelPrice(inputPerMillion: 1.25, cachedInputPerMillion: 0.125,
                             outputPerMillion: 10.00, currency: "USD", recordedAt: seededVerifiedAt),
        "gpt-5-mini": ModelPrice(inputPerMillion: 0.25, cachedInputPerMillion: 0.025,
                                  outputPerMillion: 2.00, currency: "USD", recordedAt: seededVerifiedAt),
        "gpt-5-nano": ModelPrice(inputPerMillion: 0.05, cachedInputPerMillion: 0.005,
                                  outputPerMillion: 0.40, currency: "USD", recordedAt: seededVerifiedAt),
        "o4-mini": ModelPrice(inputPerMillion: 1.10, cachedInputPerMillion: 0.275,
                               outputPerMillion: 4.40, currency: "USD", recordedAt: seededVerifiedAt),
        "o3": ModelPrice(inputPerMillion: 2.00, cachedInputPerMillion: 0.50,
                          outputPerMillion: 8.00, currency: "USD", recordedAt: seededVerifiedAt),
    ]

    /// Trailing slash and surrounding whitespace are normalized before building the key,
    /// so "https://host/v1" and "https://host/v1/" are treated as the one endpoint they
    /// actually are (AIClient itself would hit the same URL either way).
    public static func customKey(endpoint: String, model: String) -> String {
        var trimmed = endpoint.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        return "\(trimmed)#\(model)"
    }

    public func price(model: String, endpoint: String) -> ModelPrice? {
        if let custom = custom[Self.customKey(endpoint: endpoint, model: model)] { return custom }
        guard isOpenAIEndpoint(endpoint) else { return nil }
        if let exact = Self.seeded[model] { return exact }
        // Model ids carry a dated suffix ("gpt-5.1-2026-03-11") and a table of bare names
        // would call every one of them unknown. The longest matching name wins, so
        // "gpt-5.5-pro-..." is priced as the pro model rather than as "gpt-5.5".
        return Self.seeded
            .filter { model.hasPrefix($0.key + "-") }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    private func isOpenAIEndpoint(_ endpoint: String) -> Bool {
        let trimmed = endpoint.trimmingCharacters(in: .whitespaces)
        return trimmed == "https://api.openai.com/v1" || trimmed.hasPrefix("https://api.openai.com/v1/")
    }

    // MARK: Persistence (UserDefaults JSON, mirrors Palette.swift's own pattern)
    //
    // Only `custom` is ever written: `seeded` is code, not data, and never touches disk.
    // This is deliberately small, personal, user-editable state, not the growing spend
    // ledger, so it does not belong in Library's SQLite database the way spend entries do.

    private static let overridesDefaultsKey = "aiPriceOverrides"

    /// `defaults` defaults to `.standard` for every real call site, and is overridable
    /// only so a test can use its own isolated suite instead of the app's real prefs.
    public static func loadCustom(from defaults: UserDefaults = .standard) -> PriceTable {
        guard let data = defaults.data(forKey: overridesDefaultsKey),
              let custom = try? JSONDecoder().decode([String: ModelPrice].self, from: data)
        else { return PriceTable() }
        return PriceTable(custom: custom)
    }

    public mutating func setCustom(_ price: ModelPrice, endpoint: String, model: String, in defaults: UserDefaults = .standard) {
        custom[Self.customKey(endpoint: endpoint, model: model)] = price
        persist(to: defaults)
    }

    public mutating func removeCustom(endpoint: String, model: String, in defaults: UserDefaults = .standard) {
        custom.removeValue(forKey: Self.customKey(endpoint: endpoint, model: model))
        persist(to: defaults)
    }

    private func persist(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(custom) else { return }
        defaults.set(data, forKey: Self.overridesDefaultsKey)
    }
}

// MARK: - Usage and cost

/// Mirrors the OpenAI chat-completion usage object. cachedTokens and reasoningTokens are
/// subsets already counted in promptTokens/completionTokens, not additions to them.
public struct TokenUsage: Sendable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var cachedTokens: Int
    public var reasoningTokens: Int

    public init(promptTokens: Int, completionTokens: Int, cachedTokens: Int = 0, reasoningTokens: Int = 0) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedTokens = cachedTokens
        self.reasoningTokens = reasoningTokens
    }

    public static let zero = TokenUsage(promptTokens: 0, completionTokens: 0)
}

/// Reads whatever usage a response has. Every nested field is optional because an
/// OpenAI-compatible server is only conventionally, not contractually, shaped this way.
public func parseTokenUsage(_ responseObject: [String: Any]) -> TokenUsage? {
    guard let usage = responseObject["usage"] as? [String: Any],
          let prompt = usage["prompt_tokens"] as? Int,
          let completion = usage["completion_tokens"] as? Int else { return nil }
    let promptDetails = usage["prompt_tokens_details"] as? [String: Any]
    let completionDetails = usage["completion_tokens_details"] as? [String: Any]
    return TokenUsage(promptTokens: prompt, completionTokens: completion,
                       cachedTokens: (promptDetails?["cached_tokens"] as? Int) ?? 0,
                       reasoningTokens: (completionDetails?["reasoning_tokens"] as? Int) ?? 0)
}

/// Cost of one call. Rounded to 6 decimal places at the point of calculation so a
/// division that doesn't terminate cleanly (an odd token count over 1,000,000) can't
/// leave a long, cosmetic tail in the ledger.
public func cost(usage: TokenUsage, price: ModelPrice) -> Money {
    let million = Decimal(1_000_000)
    let cachedRate = price.cachedInputPerMillion ?? price.inputPerMillion
    let regularPrompt = Decimal(max(0, usage.promptTokens - usage.cachedTokens))
    let raw = regularPrompt * price.inputPerMillion / million
        + Decimal(usage.cachedTokens) * cachedRate / million
        + Decimal(usage.completionTokens) * price.outputPerMillion / million
    var rounded = Decimal()
    var mutableRaw = raw
    NSDecimalRound(&rounded, &mutableRaw, 6, .plain)
    return Money(amount: rounded, currency: price.currency)
}

// MARK: - Identify outcome (usage read before content can fail to parse)

/// What one identify() HTTP round trip produced. Usage is read here, before the reply's
/// content is judged usable, and kept even when it turns out `guess` cannot be built: a
/// 2xx reply the provider has already billed for does not stop being billed just because
/// its content did not parse into a title. `failureReason` carries the raw body (a
/// non-2xx reply) or the raw reply text (a 2xx reply with unusable content), for the
/// caller to build its own error message from.
public struct IdentifyOutcome: Sendable, Equatable {
    public var guess: BookGuess?
    public var usage: TokenUsage?
    public var failureReason: String?
}

/// Pure: given exactly what a network call produced, decides the outcome. Kept apart from
/// AI.swift's actual URLSession call so this behaviour is testable without a server —
/// PaperShelf/AI.swift itself has no test target, so this is the only place the "usage
/// survives an unparseable reply" contract can be verified in CI.
public func identifyOutcome(responseBody: Data, statusCode: Int) -> IdentifyOutcome {
    let object = (try? JSONSerialization.jsonObject(with: responseBody)) as? [String: Any]
    let usage = parseTokenUsage(object ?? [:])
    guard (200..<300).contains(statusCode) else {
        return IdentifyOutcome(guess: nil, usage: usage,
                                failureReason: String(data: responseBody, encoding: .utf8) ?? "")
    }
    let reply = ((object?["choices"] as? [[String: Any]])?.first?["message"]
        as? [String: Any])?["content"] as? String ?? ""
    guard let guess = parseBookGuess(reply) else {
        return IdentifyOutcome(guess: nil, usage: usage, failureReason: reply)
    }
    return IdentifyOutcome(guess: guess, usage: usage, failureReason: nil)
}

// MARK: - Ledger

/// What kind of call spent the tokens. Kept as a fixed, small list rather than a free
/// string: every AI call site in the app today is one of these three, and a typo in a
/// free-form label would silently split one feature's totals into two rows.
public enum AIFeature: String, Sendable, CaseIterable, Codable, Hashable {
    case identify         // renaming one item
    case batchIdentify    // "identify pending" sweep
    case connectionTest   // Settings' Test connection button, still real spend, tagged apart
    case readingProject   // a question asked of a reading project
    case bibtex           // improving a bibliography entry
    case noteTranscription // dictating a note

    public var displayName: String {
        switch self {
        case .identify: return "Identify"
        case .batchIdentify: return "Identify pending"
        case .connectionTest: return "Connection test"
        case .readingProject: return "Reading project"
        case .bibtex: return "Bibliography"
        case .noteTranscription: return "Note transcription"
        }
    }
}

/// One completed call, success or failure. `cost` is nil, not zero, exactly when the
/// model was not in the price table at call time, or the call failed before any usage
/// came back — the ledger says "unknown" rather than silently claiming free.
public struct SpendRecord: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var timestamp: Date
    public var model: String
    public var endpoint: String
    public var feature: AIFeature
    public var usage: TokenUsage
    public var cost: Money?
    public var succeeded: Bool

    public init(id: Int64, timestamp: Date, model: String, endpoint: String, feature: AIFeature,
                usage: TokenUsage, cost: Money?, succeeded: Bool) {
        self.id = id
        self.timestamp = timestamp
        self.model = model
        self.endpoint = endpoint
        self.feature = feature
        self.usage = usage
        self.cost = cost
        self.succeeded = succeeded
    }
}

/// Aggregated over some set of entries. Money is grouped by currency and never summed
/// across currencies into one figure — a user pointed at a non-USD-billed endpoint must
/// see that total kept apart, not folded into a number that quietly means the wrong thing.
public struct SpendTotals: Sendable, Equatable {
    public var calls: Int = 0
    public var failedCalls: Int = 0
    public var promptTokens: Int = 0
    public var completionTokens: Int = 0
    public var cachedTokens: Int = 0
    public var reasoningTokens: Int = 0
    public var byCurrency: [CurrencyCode: Decimal] = [:]
    public var callsWithUnknownCost: Int = 0   // never folded into byCurrency as zero

    public init() {}
}

public func spendTotals(for entries: [SpendRecord]) -> SpendTotals {
    entries.reduce(into: SpendTotals()) { totals, entry in
        totals.calls += 1
        if !entry.succeeded { totals.failedCalls += 1 }
        totals.promptTokens += entry.usage.promptTokens
        totals.completionTokens += entry.usage.completionTokens
        totals.cachedTokens += entry.usage.cachedTokens
        totals.reasoningTokens += entry.usage.reasoningTokens
        if let cost = entry.cost {
            totals.byCurrency[cost.currency, default: 0] += cost.amount
        } else {
            totals.callsWithUnknownCost += 1
        }
    }
}

public func spendTotals<Key: Hashable>(for entries: [SpendRecord], groupedBy key: (SpendRecord) -> Key) -> [Key: SpendTotals] {
    Dictionary(grouping: entries, by: key).mapValues(spendTotals(for:))
}

/// "This session" has no other definition in an app with no login/logout — it is every
/// entry timestamped at or after `sessionStart`.
public func spendTotals(for entries: [SpendRecord], since sessionStart: Date) -> SpendTotals {
    spendTotals(for: entries.filter { $0.timestamp >= sessionStart })
}

/// The moment this run of the app first asked about spend. A module-level `let` is
/// initialized lazily, once, on first access — for a single-window app with no other
/// login/logout boundary, that is effectively launch time.
public let sessionStart = Date()

// MARK: - Spend recording (the write side AIClient depends on)

/// Lets AI.swift log a completed call without knowing how or where the ledger is stored.
/// Library is the only conformer today. The "record even on failure" behaviour this
/// exists for is decided in AI.swift's identify(), which has no test target of its own.
/// SpendTests only covers the pure identifyOutcome()/cost() functions that feed it, not
/// the actual recordSpend call AIClient makes, so that wiring is unverified by CI.
public protocol SpendRecorder: Sendable {
    func recordSpend(timestamp: Date, model: String, endpoint: String, feature: AIFeature,
                      usage: TokenUsage, cost: Money?, succeeded: Bool) async throws
}

// MARK: - Library integration
//
// ASSUMED SHAPE, because Sources/PaperShelfCore/Library.swift does not exist in this
// worktree (another agent adds it this round — see docs/design/knowledge-graph.md):
//   - `public actor Library` exposes its one SQLite connection to same-module code as
//     `db: OpaquePointer`, at least `internal`, per that document's actor-per-connection
//     design (a single GUI read/write connection, WAL, wrapped in one actor).
//   - a table named `spend` already exists with columns: timestamp, model, endpoint,
//     feature, input_tokens, output_tokens, cached_tokens, reasoning_tokens, cost (TEXT,
//     an exact decimal, NULL when unknown), currency (TEXT, NULL exactly when cost is),
//     succeeded (INTEGER 0/1). No explicit id column is assumed; SQLite's own `rowid` is
//     used as `SpendRecord.id`.
// If the real file differs, only this section needs to change — everything above this
// point compiles and is tested without Library existing at all.

private let spendTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SpendStoreError: Error {
    case sql(String)
}

extension Library: SpendRecorder {
    public func recordSpend(timestamp: Date, model: String, endpoint: String, feature: AIFeature,
                             usage: TokenUsage, cost: Money?, succeeded: Bool) async throws {
        let sql = """
            INSERT INTO spend_ledger (at, model, endpoint, feature, input_tokens, output_tokens,
                                cached_tokens, reasoning_tokens, cost, currency, succeeded)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SpendStoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, ISO8601DateFormatter().string(from: timestamp), -1, spendTransientDestructor)
        sqlite3_bind_text(statement, 2, model, -1, spendTransientDestructor)
        sqlite3_bind_text(statement, 3, endpoint, -1, spendTransientDestructor)
        sqlite3_bind_text(statement, 4, feature.rawValue, -1, spendTransientDestructor)
        sqlite3_bind_int64(statement, 5, Int64(usage.promptTokens))
        sqlite3_bind_int64(statement, 6, Int64(usage.completionTokens))
        sqlite3_bind_int64(statement, 7, Int64(usage.cachedTokens))
        sqlite3_bind_int64(statement, 8, Int64(usage.reasoningTokens))
        if let cost {
            sqlite3_bind_text(statement, 9, "\(cost.amount)", -1, spendTransientDestructor)
            sqlite3_bind_text(statement, 10, cost.currency, -1, spendTransientDestructor)
        } else {
            sqlite3_bind_null(statement, 9)
            sqlite3_bind_null(statement, 10)
        }
        sqlite3_bind_int(statement, 11, succeeded ? 1 : 0)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SpendStoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// All recorded calls, oldest first, or only those at or after `since`.
    public func spendEntries(since: Date? = nil) throws -> [SpendRecord] {
        let sql = since == nil
            ? """
              SELECT id, at, model, endpoint, feature, input_tokens, output_tokens,
                     cached_tokens, reasoning_tokens, cost, currency, succeeded
              FROM spend_ledger ORDER BY at ASC
              """
            : """
              SELECT id, at, model, endpoint, feature, input_tokens, output_tokens,
                     cached_tokens, reasoning_tokens, cost, currency, succeeded
              FROM spend_ledger WHERE at >= ? ORDER BY at ASC
              """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SpendStoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        if let since {
            sqlite3_bind_text(statement, 1, ISO8601DateFormatter().string(from: since), -1, spendTransientDestructor)
        }

        let iso = ISO8601DateFormatter()
        var results: [SpendRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let timestampCString = sqlite3_column_text(statement, 1),
                  let timestamp = iso.date(from: String(cString: timestampCString)),
                  let modelCString = sqlite3_column_text(statement, 2),
                  let endpointCString = sqlite3_column_text(statement, 3),
                  let featureCString = sqlite3_column_text(statement, 4),
                  let feature = AIFeature(rawValue: String(cString: featureCString))
            else { continue }

            var cost: Money?
            if let costCString = sqlite3_column_text(statement, 9),
               let currencyCString = sqlite3_column_text(statement, 10),
               let amount = Decimal(string: String(cString: costCString)) {
                cost = Money(amount: amount, currency: String(cString: currencyCString))
            }

            results.append(SpendRecord(
                id: sqlite3_column_int64(statement, 0),
                timestamp: timestamp,
                model: String(cString: modelCString),
                endpoint: String(cString: endpointCString),
                feature: feature,
                usage: TokenUsage(promptTokens: Int(sqlite3_column_int64(statement, 5)),
                                   completionTokens: Int(sqlite3_column_int64(statement, 6)),
                                   cachedTokens: Int(sqlite3_column_int64(statement, 7)),
                                   reasoningTokens: Int(sqlite3_column_int64(statement, 8))),
                cost: cost,
                succeeded: sqlite3_column_int(statement, 11) != 0))
        }
        return results
    }
}
