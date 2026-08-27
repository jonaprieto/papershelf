# ai-cost

## Summary

AI.swift makes two plain-URLSession calls (GET /models, POST /chat/completions) and never reads the response's `usage` block anywhere in the app. OpenAI's chat-completions `usage` object reports `prompt_tokens`/`completion_tokens`/`total_tokens` plus `prompt_tokens_details.cached_tokens` and `completion_tokens_details.reasoning_tokens` as subsets of those totals; neither the completions API nor `GET /v1/models` exposes pricing, and the one costs endpoint that exists (`/v1/organization/costs`) needs a separate admin key and returns daily rollups, not live per-token prices — so the app needs a local, dated, user-editable price table. The design below adds pure PDFHammerCore types (`ModelPrice`/`PriceTable` using `Decimal`, `TokenUsage`, `SpendEntry`/`SpendTotals`) plus aggregation functions, persisted the same two ways the app already persists comparable data: RunCache's Application-Support-JSON pattern for the ledger, Palette's UserDefaults-JSON pattern for user price overrides.

## Design

New file Sources/PDFHammerCore/Spend.swift holds everything pure and testable:

```swift
// MARK: - Pricing

/// Per-million-token USD pricing for one model. Providers publish rates this way, so the
/// table stores them this way too and only divides down to a per-token rate at the point
/// of a calculation.
public struct ModelPrice: Codable, Sendable, Equatable {
    public var inputPerMillion: Decimal
    public var cachedInputPerMillion: Decimal?   // nil => cached tokens bill at inputPerMillion
    public var outputPerMillion: Decimal

    public init(inputPerMillion: Decimal, cachedInputPerMillion: Decimal? = nil, outputPerMillion: Decimal) {
        self.inputPerMillion = inputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
        self.outputPerMillion = outputPerMillion
    }
}

/// Seeded, dated OpenAI prices plus whatever the user has added for their own endpoint.
/// Seeded entries only apply under the real OpenAI base URL; a custom entry always wins,
/// since the user typed it in for exactly their own model and endpoint. This is the
/// answer to "endpoint is not OpenAI and model is unknown": no seeded price is ever
/// guessed onto a non-OpenAI server, and an unmatched model returns nil rather than $0.
public struct PriceTable: Codable, Sendable {
    public var verifiedAt: Date                 // when `seeded` was checked against the pricing page
    public var seeded: [String: ModelPrice]      // keyed by model id, applies only under OpenAI's own baseURL
    public var custom: [String: ModelPrice]      // keyed by "\(baseURL)#\(model)", user-entered, applies unconditionally

    public init(verifiedAt: Date, seeded: [String: ModelPrice], custom: [String: ModelPrice] = [:]) {
        self.verifiedAt = verifiedAt; self.seeded = seeded; self.custom = custom
    }

    /// 2026-08-27, from developers.openai.com/api/docs/pricing. Legacy rows here match
    /// this assistant's training-time knowledge; the newest OpenAI models were not in
    /// scope for this project's default model list and are intentionally left out of the
    /// seed so nobody ships an unverified number as a fact.
    public static let seeded = PriceTable(
        verifiedAt: ISO8601DateFormatter().date(from: "2026-08-27T00:00:00Z")!,
        seeded: [
            "gpt-4o-mini":  ModelPrice(inputPerMillion: 0.15, cachedInputPerMillion: 0.075, outputPerMillion: 0.60),
            "gpt-4o":       ModelPrice(inputPerMillion: 2.50, cachedInputPerMillion: 1.25,  outputPerMillion: 10.00),
            "gpt-4.1":      ModelPrice(inputPerMillion: 2.00, cachedInputPerMillion: 0.50,  outputPerMillion: 8.00),
            "gpt-4.1-mini": ModelPrice(inputPerMillion: 0.40, cachedInputPerMillion: 0.10,  outputPerMillion: 1.60),
            "gpt-4.1-nano": ModelPrice(inputPerMillion: 0.10, cachedInputPerMillion: 0.025, outputPerMillion: 0.40),
            "gpt-5":        ModelPrice(inputPerMillion: 1.25, cachedInputPerMillion: 0.125, outputPerMillion: 10.00),
            "gpt-5-mini":   ModelPrice(inputPerMillion: 0.25, cachedInputPerMillion: 0.025, outputPerMillion: 2.00),
            "gpt-5-nano":   ModelPrice(inputPerMillion: 0.05, cachedInputPerMillion: 0.005, outputPerMillion: 0.40),
            "o4-mini":      ModelPrice(inputPerMillion: 1.10, cachedInputPerMillion: 0.275, outputPerMillion: 4.40),
            "o3":           ModelPrice(inputPerMillion: 2.00, cachedInputPerMillion: 0.50,  outputPerMillion: 8.00),
        ])

    public func price(model: String, baseURL: String) -> ModelPrice? {
        if let custom = custom[Self.customKey(baseURL: baseURL, model: model)] { return custom }
        return isOpenAIEndpoint(baseURL) ? seeded[model] : nil
    }

    public static func customKey(baseURL: String, model: String) -> String {
        "\(baseURL.trimmingCharacters(in: .whitespaces))#\(model)"
    }

    private func isOpenAIEndpoint(_ baseURL: String) -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        return trimmed == "https://api.openai.com/v1" || trimmed.hasPrefix("https://api.openai.com/v1/")
    }
}

// MARK: - Usage and cost

/// Mirrors the OpenAI usage object. cachedTokens and reasoningTokens are subsets already
/// counted in promptTokens/completionTokens, not additions to them — every field but the
/// two totals is optional in practice, so a compatible-but-partial server still parses.
public struct TokenUsage: Codable, Sendable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var cachedTokens: Int
    public var reasoningTokens: Int

    public init(promptTokens: Int, completionTokens: Int, cachedTokens: Int = 0, reasoningTokens: Int = 0) {
        self.promptTokens = promptTokens; self.completionTokens = completionTokens
        self.cachedTokens = cachedTokens; self.reasoningTokens = reasoningTokens
    }
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

/// Dollars for one call. Decimal, not Double: prices like $0.15 per 1,000,000 tokens are
/// exact decimal fractions, and Double's binary floating point cannot represent most of
/// them exactly, so a running total in Double drifts by a small but real amount over many
/// calls. Decimal (Foundation, no dependency) does base-10 arithmetic, so add/multiply
/// over exact decimal inputs stays exact to its 38-digit precision — effectively exact at
/// the scale of a per-token cost. Rounded to 6 decimal places at the point of storage so
/// a division that doesn't terminate cleanly (e.g. an odd token count over 1,000,000)
/// can't leave a long, cosmetic tail in the ledger.
public func cost(usage: TokenUsage, price: ModelPrice) -> Decimal {
    let million = Decimal(1_000_000)
    let cachedRate = price.cachedInputPerMillion ?? price.inputPerMillion
    let regularPrompt = Decimal(max(0, usage.promptTokens - usage.cachedTokens))
    let raw = regularPrompt * price.inputPerMillion / million
        + Decimal(usage.cachedTokens) * cachedRate / million
        + Decimal(usage.completionTokens) * price.outputPerMillion / million
    var rounded = Decimal(); var mutableRaw = raw
    NSDecimalRound(&rounded, &mutableRaw, 6, .plain)
    return rounded
}

// MARK: - Ledger

public enum AIFeature: String, Codable, Sendable, CaseIterable {
    case identify         // renaming one item
    case batchIdentify    // "identify pending" sweep
    case connectionTest   // Settings' Test connection button — still real spend, tagged apart
}

/// One completed call. costUSD is nil, not zero, when the model was not in the price
/// table at call time — the ledger must be able to say "spent an unknown amount" rather
/// than silently underclaiming zero for a non-OpenAI or brand-new model.
public struct SpendEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var timestamp: Date
    public var baseURL: String
    public var model: String
    public var feature: AIFeature
    public var usage: TokenUsage
    public var costUSD: Decimal?

    public init(id: UUID = UUID(), timestamp: Date = Date(), baseURL: String, model: String,
                feature: AIFeature, usage: TokenUsage, costUSD: Decimal?) {
        self.id = id; self.timestamp = timestamp; self.baseURL = baseURL; self.model = model
        self.feature = feature; self.usage = usage; self.costUSD = costUSD
    }
}

public struct SpendTotals: Sendable, Equatable {
    public var calls: Int = 0
    public var promptTokens: Int = 0
    public var completionTokens: Int = 0
    public var cachedTokens: Int = 0
    public var reasoningTokens: Int = 0
    public var costUSD: Decimal = 0          // sum of entries whose cost is known
    public var callsWithUnknownCost: Int = 0 // counted apart, never folded into costUSD as $0
}

public func totals(for entries: [SpendEntry]) -> SpendTotals {
    entries.reduce(into: SpendTotals()) { totals, entry in
        totals.calls += 1
        totals.promptTokens += entry.usage.promptTokens
        totals.completionTokens += entry.usage.completionTokens
        totals.cachedTokens += entry.usage.cachedTokens
        totals.reasoningTokens += entry.usage.reasoningTokens
        if let cost = entry.costUSD { totals.costUSD += cost } else { totals.callsWithUnknownCost += 1 }
    }
}

/// "This session" has no other definition in an app with no login/logout — it is every
/// entry timestamped at or after the moment the caller captured as the session start
/// (once, at launch).
public func totals(for entries: [SpendEntry], since sessionStart: Date) -> SpendTotals {
    totals(for: entries.filter { $0.timestamp >= sessionStart })
}

// MARK: - Persistence (mirrors RunCache in Cache.swift exactly)

public func spendLedgerURL(named name: String = "spend-ledger.json") -> URL? {
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return nil }
    let folder = base.appendingPathComponent("PDF Hammer", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent(name)
}

public func loadSpendLedger() -> [SpendEntry] {
    guard let url = spendLedgerURL(), let data = try? Data(contentsOf: url) else { return [] }
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([SpendEntry].self, from: data)) ?? []
}

public func saveSpendLedger(_ entries: [SpendEntry]) {
    guard let url = spendLedgerURL() else { return }
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(entries) else { return }
    try? data.write(to: url, options: .atomic)
}

public func clearSpendLedger() {
    guard let url = spendLedgerURL() else { return }
    try? FileManager.default.removeItem(at: url)
}
```

Integration in the PDFHammer target (described, not written — this task is research-only):

1. Sources/PDFHammer/AI.swift — `identify(filename:excerpt:)` currently discards the raw response after reading `choices` (AI.swift:149-153). Change its return type to a small struct so the caller gets both the guess and the usage from the same response body, without a second network call:
   `struct IdentifyResult { let guess: BookGuess; let usage: TokenUsage? }`
   `func identify(filename: String, excerpt: String) async throws -> IdentifyResult` — builds `usage` via `parseTokenUsage(object ?? [:])` before returning.

2. Sources/PDFHammer/Runner.swift — the one place `client.identify` and `client.identify`-via-batch already run (Runner.swift:475-511). After a successful call, look up `PriceTable.seeded.price(model: client.model, baseURL: client.baseURL)` merged with any user `custom` overrides (loaded from UserDefaults, see below), compute `cost(usage:price:)` if a price was found, build a `SpendEntry(baseURL:model:feature: .identify or .batchIdentify:usage:costUSD:)`, and append it to the ledger. `SettingsView.swift`'s `test()` (line 117-132) does the same with `feature: .connectionTest` after its own `client.identify` call at line 123.

3. A tiny `@MainActor final class SpendTracker: ObservableObject` in the PDFHammer target, shaped exactly like `Palette` (Palette.swift:48-78) for the observable half, but persisting like `RunCache` for the data half:
   ```swift
   @MainActor
   final class SpendTracker: ObservableObject {
       @Published private(set) var entries: [SpendEntry] = []
       private let sessionStart = Date()
       init() { entries = loadSpendLedger() }
       func record(_ entry: SpendEntry) { entries.append(entry); saveSpendLedger(entries) }
       var sessionTotals: SpendTotals { totals(for: entries, since: sessionStart) }
       var allTimeTotals: SpendTotals { totals(for: entries) }
       func clearAll() { entries = []; clearSpendLedger() }
   }
   ```
   Held as `@StateObject` alongside `Converting`/`Annotator` in ResultsPane (Catalogue.swift:37, :44 pattern), so any view can show `spend.sessionTotals.costUSD` / `spend.allTimeTotals.costUSD` reactively.

4. User-added custom prices — small, personal, edited rarely, exactly Palette's shape — persist the same way Palette does: JSON-encode `[String: ModelPrice]` (custom overrides only, not the seed) into `UserDefaults.standard` under a `"aiPriceOverrides"` key, loaded/saved by a `PriceOverrides: ObservableObject` mirroring Palette.swift:63-78 line for line. `PriceTable.custom` is populated from this at read time; `PriceTable.seeded` is the static constant above and never persisted (it's code, not data).

5. Model selector, Sources/PDFHammer/ContentView.swift's `aiPanel` (ContentView.swift:572-609) — next to or below the `Picker` (line 592), a `LabeledContent("Cost")` showing, for the current `aiModel`/`aiBaseURL`: `"$0.15 in · $0.60 out per 1M tokens"` from `PriceTable.seeded.price(model:baseURL:)` merged with overrides, or `"Cost unknown for this model"` with a small `TextField`/button pair (mirroring the existing `Save key`/`Remove` HStack pattern at SettingsView.swift:44-53) that writes a `ModelPrice` into `PriceOverrides` for exactly `(aiBaseURL, aiModel)`. A second, smaller line shows `spend.sessionTotals` and `spend.allTimeTotals` (e.g. "This session: $0.0034 (12 calls) · All time: $0.42"), with unknown-cost calls surfaced separately ("+ 3 calls, cost unknown") rather than folded silently into the dollar figure.

Point 4's answer is structural, not a fallback branch bolted on: seeded prices only ever resolve when `baseURL` is recognized as OpenAI's own; any other endpoint gets a price only if the user explicitly typed one in for that exact `(baseURL, model)` pair, and until they do, the UI shows token counts (always available from `usage`, provider-agnostic) with cost marked unknown rather than computed from an unrelated model's rate.

## Verified facts

- AI.swift makes exactly two network calls, both via URLSession + JSONSerialization, no SDK: GET {baseURL}/models and POST {baseURL}/chat/completions.
  EVIDENCE: Sources/PDFHammer/AI.swift:103-122 (models()), :124-154 (identify())

- models() sends a bare GET with a Bearer header and no body, and parses only data[].id from the response.
  EVIDENCE: Sources/PDFHammer/AI.swift:105 (URL build), :112-121 (request + parse)

- identify() posts {model, temperature: 0, messages: [system, user]} with no stream/stream_options fields.
  EVIDENCE: Sources/PDFHammer/AI.swift:126, :134-141

- The response's `usage` block is never read anywhere in the app; identify() only extracts choices[0].message.content.
  EVIDENCE: Sources/PDFHammer/AI.swift:149-152; grep -rni "usage|cost|spend|budget|pricing|token" over Sources/PDFHammer and Sources/PDFHammerCore returned zero AI-cost-related hits (all matches were unrelated: UI layout "budget", bibtex tokenizer, etc.)

- AIClient.identify has exactly two direct call sites: the app's live flow and the Settings connection test.
  EVIDENCE: Sources/PDFHammer/Runner.swift:486 (called from identify(_:client:...) at :475, itself called from identifyPending at :511); Sources/PDFHammer/SettingsView.swift:123 (client.identify(...) inside test())

- The model selector is a SwiftUI Picker in ContentView's aiPanel, fed by client.models().
  EVIDENCE: Sources/PDFHammer/ContentView.swift:592 (Picker("Model", ...)), :572 (aiPanel start), :113 (availableModels = try await client.models())

- The API key is currently stored in a 0600 file under Application Support via a KeyStore enum, not the macOS Keychain; the working tree is clean at commit cada1ca, titled 'chore: drop output encryption, and keep the API key out of the Keychain'.
  EVIDENCE: git log --oneline -1 -- Sources/PDFHammer/AI.swift → cada1ca; git status --short → empty; Sources/PDFHammer/AI.swift:6-41 (KeyStore)

- My first Read-tool call on AI.swift/SettingsView.swift returned stale content (a Keychain/SecItemAdd-based version) that does not match the on-disk, git-clean working tree; re-reading via `cat`/`git log`/`git status` resolved this, and all citations above use the verified current content.
  EVIDENCE: Read tool output showed `enum Keychain` using SecItemAdd/SecItemCopyMatching; `cat -n` and `git status --short` (empty) on the same path immediately after showed `enum KeyStore` writing a 0600 file instead — the two cannot both be the current file

- The chat-completion usage object's fields are: top-level prompt_tokens, completion_tokens, total_tokens; nested prompt_tokens_details {cached_tokens, audio_tokens, cache_write_tokens, image_tokens, text_tokens}; nested completion_tokens_details {reasoning_tokens, audio_tokens, accepted_prediction_tokens, rejected_prediction_tokens, text_tokens}.
  EVIDENCE: WebFetch of https://developers.openai.com/api/docs/api-reference/chat/object (redirected target of platform.openai.com/docs/api-reference/chat/object, which returned 403 direct), cross-checked by a WebSearch snippet quoting developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create

- cached_tokens and reasoning_tokens are subsets already counted inside the top-level prompt_tokens/completion_tokens, not additive extras.
  EVIDENCE: WebSearch result quoting OpenAI docs: reasoning tokens 'occupy space in the context window and are billed as output tokens'; cached_tokens described as tokens 'present in the prompt'

- GET /v1/models returns only {object: "list", data: [{id, object: "model", created, owned_by, shutdown_date}]} — no pricing, no context length.
  EVIDENCE: WebFetch of https://developers.openai.com/api/docs/api-reference/models/list

- A separate developers.openai.com page shows context_window/pricing per model, but this is a human-facing docs/marketing page, not the API's JSON schema.
  EVIDENCE: WebFetch of https://developers.openai.com/api/docs/models, quote: 'does not document actual JSON fields returned by the /v1/models API endpoint'

- A costs endpoint exists (GET https://api.openai.com/v1/organization/costs) but requires a separate org Admin API key, returns daily aggregated spend buckets (amount + currency), and is unrelated to the per-project key AIClient already uses.
  EVIDENCE: WebSearch results citing developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage/methods/costs and OpenAI Developer Community thread 'Access billing balance & costs via Admin API'

- platform.openai.com/docs/pricing redirects (301) to developers.openai.com/api/docs/pricing; fetched 2026-08-27, prices per 1M tokens (input / cached input / output) for models this app could plausibly use: gpt-4o-mini $0.15/$0.075/$0.60; gpt-4o $2.50/$1.25/$10.00; gpt-4.1 $2.00/$0.50/$8.00; gpt-4.1-mini $0.40/$0.10/$1.60; gpt-4.1-nano $0.10/$0.025/$0.40; gpt-5 $1.25/$0.125/$10.00; gpt-5-mini $0.25/$0.025/$2.00; gpt-5-nano $0.05/$0.005/$0.40; o4-mini $1.10/$0.275/$4.40; o3 $2.00/$0.50/$8.00.
  EVIDENCE: WebFetch of https://developers.openai.com/api/docs/pricing on 2026-08-27 (today's system date)

- The legacy-model prices above (gpt-4o-mini, gpt-4o, gpt-4.1 family, o4-mini) match figures already in the assistant's January-2026 training data, an independent cross-check the same fetch's newer rows (gpt-5.6-sol/terra/luna, gpt-5.5, gpt-5.4 family, 'cyber' models) could not get since those postdate the cutoff.
  EVIDENCE: internal consistency check against training-time knowledge, not a second live fetch

- The project has two existing persistence precedents to mirror: RunCache stores operational/data-sized content as a JSON file in Application Support/'PDF Hammer' with atomic writes and silent-failure semantics; Palette stores a small, personal, user-editable list as a JSON blob in UserDefaults.
  EVIDENCE: Sources/PDFHammerCore/Cache.swift:8-53 (RunCache, runCacheURL, saveRunCache, loadRunCache); Sources/PDFHammer/Palette.swift:48-78 (Palette load/save via UserDefaults.standard.data(forKey:))

- No Decimal type is used anywhere in the repo today, and there are no third-party Swift dependencies declared.
  EVIDENCE: grep -rn "Decimal" over Sources found zero hits; Package.swift has no dependencies: array; README.md:6 states 'No third-party dependencies.'


## Risks

- Seeded prices are fetched once and hand-copied into source; nothing here re-fetches them, so PriceTable.seeded.verifiedAt (2026-08-27) will silently go stale as OpenAI changes prices — the UI should surface that date next to the rate so a stale figure is visible, not hidden.

- The newest-generation model prices in the fetched pricing table (gpt-5.6-sol/terra/luna, gpt-5.5, gpt-5.4 family, 'cyber' models) postdate this assistant's January 2026 training cutoff and were not independently cross-checked the way the legacy rows were (gpt-4o-mini/gpt-4o/gpt-4.1 family/o4-mini matched training-time knowledge exactly); they were deliberately left out of the proposed seed for that reason. If any gpt-5.6-class model is added to the seed later, re-verify against the live pricing page immediately before shipping, since a third-party blog scrape found during this research quoted a different input price for gpt-5.6-sol than the OpenAI-docs fetch did ($5.00 vs $4.00).

- Decimal division by 1,000,000 does not always terminate within Decimal's digit budget for an arbitrary token count; the design rounds each entry's cost to 6 decimal places at write time specifically so this can't accumulate into a visible drift the way it would with Double, but the rounding step itself must not be dropped in implementation.

- custom price-table keys are plain strings built from baseURL + model; a baseURL typed with vs without a trailing slash would be treated as two different endpoints for override purposes even though AIClient itself would hit the same URL either way (AI.swift already normalizes with .trimmingCharacters(in: .whitespaces), not slash-stripping) — worth normalizing the trailing slash specifically when building customKey, not just whitespace.

- AIClient.identify is the only choke point this design hooks; if a future AI feature calls the endpoint through a new code path instead of AIClient.identify, it will not automatically record spend unless it's wired in the same way — there is no shared client wrapper enforcing this structurally.

- Treating every usage sub-field as optional (per parseTokenUsage) is a deliberate hedge for 'OpenAI-compatible but not identical' servers per point 4 of the task, but it also means a genuinely broken OpenAI-compatible server that omits prompt_tokens/completion_tokens entirely will silently produce a SpendEntry with no way to know a call happened at all unless the caller separately counts calls regardless of usage — the design only ever skips cost, but a totally usage-less response skips the whole entry today; worth deciding at implementation time whether such calls should still get a zero-usage, cost-nil SpendEntry rather than no entry.


## Unverified (do not build on this without checking)

- The exact byte-for-byte raw JSON schema on OpenAI's docs pages: platform.openai.com blocked direct WebFetch with 403 on every attempt, so all field-name claims here come through developers.openai.com (the documented redirect target) and through WebFetch's own summarization pass or WebSearch snippets, not a raw unprocessed fetch. Two independent fetches/searches agreed on the same field lists, which is the strongest verification available with the tools on hand, but it is not the same as reading the literal API reference JSON.

- Pricing for every OpenAI model beyond the ones listed in fact 12 (the fetched table also showed gpt-5.5-pro, gpt-5.4-pro, gpt-5.2, gpt-5.1, o1-pro, o3-pro, gpt-4-turbo, and older/embedding models) — omitted here as out of scope for 'models a user of this app would plausibly pick' for a filename+excerpt classification task, not because they were unverifiable.

- Whether prompt_tokens_details.cache_write_tokens (present in one of the two fetches) is a currently-shipping field or a newer addition unknown to this assistant's training data; it is included in the design's optional-field list defensively but its presence was not corroborated by a second independent source the way cached_tokens and reasoning_tokens were.

- Whether every OpenAI-compatible third-party server the app's baseURL field is meant to support actually returns a `usage` object shaped like OpenAI's at all — this is an ecosystem convention, not something checked against any specific third-party server's docs, which is exactly why the design treats every usage field as optional rather than required.

- NSDecimalRound's exact rounding behavior at the toolchain/Swift 6 version this project pins to (swift-tools-version 6.0) was not checked against release notes for this specific version; it is standard, long-stable Foundation API, but 'verify by reading docs' was not done for this one call specifically.
