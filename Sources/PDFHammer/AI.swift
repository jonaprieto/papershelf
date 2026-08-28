import Foundation
import Security
import PDFHammerCore

// MARK: - Key storage

/// The API key lives in the Keychain, where the system already protects credentials.
///
/// It spent a while in a 0600 file under Application Support instead, because an ad-hoc
/// signature changes on every rebuild and the Keychain asks for permission again each
/// time. That was a development convenience, not a better home: a file is readable by
/// anything running as this user, and the Keychain is not. A key left behind by that
/// arrangement is moved in the first time it is read, rather than being stranded.
enum KeyStore {
    private static let service = "com.jonaprieto.pdfhammer"

    /// Development and tests skip the Keychain entirely.
    ///
    /// An ad-hoc signed build gets a new signature every time it is rebuilt, and the
    /// Keychain treats each one as a different application: every launch during a working
    /// session raises a modal asking for permission to read a key it granted a minute ago.
    /// Debug builds and the test suite keep the value in memory for the life of the
    /// process instead. Release builds — the ones people actually install — are untouched
    /// and still use the Keychain, which is the whole point of it being there.
    private static var developmentOnly: Bool {
        #if DEBUG
        return true
        #else
        return ProcessInfo.processInfo.environment["PDFHAMMER_SKIP_KEYCHAIN"] != nil
        #endif
    }

    /// Only ever touched when `developmentOnly` is true, and never written to disk.
    private static var inMemory: [String: String] = [:]
    private static let lock = NSLock()

    static func set(_ value: String, account: String) {
        if developmentOnly {
            lock.lock()
            if value.isEmpty { inMemory.removeValue(forKey: account) } else { inMemory[account] = value }
            lock.unlock()
            return
        }
        setInKeychain(value, account: account)
    }

    private static func setInKeychain(_ value: String, account: String) {
        remove(account: account)
        guard !value.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        if developmentOnly {
            lock.lock()
            defer { lock.unlock() }
            return inMemory[account]
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let text = String(data: data, encoding: .utf8),
           !text.isEmpty {
            return text
        }
        return adoptFileKey(account: account)
    }

    static func remove(account: String) {
        if developmentOnly {
            lock.lock()
            inMemory.removeValue(forKey: account)
            lock.unlock()
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        try? FileManager.default.removeItem(at: legacyFile(account))
    }

    private static func legacyFile(_ account: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDF Hammer", isDirectory: true)
            .appendingPathComponent("\(account).key")
    }

    /// Moves a key saved while the file store was in use into the Keychain, once, and
    /// takes the file away afterwards so the credential is in one place only.
    private static func adoptFileKey(account: String) -> String? {
        let file = legacyFile(account)
        guard let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        set(text, account: account)
        try? FileManager.default.removeItem(at: file)
        return text
    }
}

// MARK: - Client

enum AIError: LocalizedError {
    case noKey
    case http(Int, String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "No API key. Add one in Settings, or set OPENAI_API_KEY before launching."
        case .http(let code, let body):
            let detail = body.isEmpty ? "" : ": \(body.prefix(200))"
            return "The service answered \(code)\(detail)"
        case .unreadable(let reply):
            return "Could not read a title out of the reply: \(reply.prefix(120))"
        }
    }
}

struct AIClient {
    var baseURL: String
    var model: String
    var apiKey: String

    /// Where a completed call is logged.
    ///
    /// It defaults to the library rather than to nil on purpose: this defaulted to
    /// nothing, four of the five places that build a client did not pass one, and the
    /// ledger stayed empty while real money was being spent. A client that records is the
    /// one you get by not thinking about it; pass nil deliberately to opt out.
    var spendRecorder: SpendRecorder? = Library.shared

    /// Reads the key from the environment when the field is empty, so the app can be used
    /// without the key ever being stored anywhere by us.
    static func environmentKey() -> String? {
        let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
        return key.isEmpty ? nil : key
    }

    /// An app launched from Finder inherits launchd's environment, not a shell's, so a
    /// key exported in .zshrc is invisible to us. Asking the login shell is the only way
    /// to see it. Run only when nothing else has produced a key, since it executes the
    /// user's own startup files.
    static func loginShellKey() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "printf %s \"$OPENAI_API_KEY\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let key = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }

    /// Asks the endpoint what it can run. Anything that clearly is not a chat model is
    /// dropped, but the filter stays permissive: an OpenAI-compatible endpoint is free to
    /// name its models whatever it likes, and hiding one the user has is worse than
    /// listing one they cannot use.
    func models() async throws -> [String] {
        guard !apiKey.isEmpty else { throw AIError.noKey }
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces) + "/models")
        else { throw AIError.unreadable("bad base URL") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw AIError.http(code, String(data: data, encoding: .utf8) ?? "")
        }

        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let ids = ((object?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        guard !ids.isEmpty else { throw AIError.unreadable("no models listed") }
        return ids.filter(looksLikeChatModel).sorted()
    }

    /// `feature` only labels the spend entry; it changes nothing about the request. It
    /// defaults to `.identify` because that is what every caller before this round meant.
    func identify(filename: String, excerpt: String, feature: AIFeature = .identify) async throws -> BookGuess {
        guard !apiKey.isEmpty else { throw AIError.noKey }
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces) + "/chat/completions")
        else { throw AIError.unreadable("bad base URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": bookGuessInstruction],
                ["role": "user", "content": bookGuessPrompt(filename: filename, excerpt: excerpt)],
            ],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0

        // Usage is read here, before anything below can throw: a 2xx reply the provider
        // has already billed for must be recorded even when its content never turns into
        // a usable guess. See docs/design/critique.md's "real spend is dropped exactly
        // when a call goes wrong".
        let outcome = identifyOutcome(responseBody: data, statusCode: code)
        await record(usage: outcome.usage, feature: feature, succeeded: outcome.guess != nil)

        if let guess = outcome.guess { return guess }
        if (200..<300).contains(code) {
            throw AIError.unreadable(outcome.failureReason ?? "")
        }
        throw AIError.http(code, outcome.failureReason ?? "")
    }

    /// A free-text exchange, for the questions `identify` cannot carry.
    ///
    /// `identify` parses its reply into a `BookGuess` and throws when it will not parse,
    /// which is right for naming a file and useless for asking about a reading project,
    /// where the answer is prose with citations in it.
    func ask(system: String, user: String, feature: AIFeature) async throws -> String {
        guard !apiKey.isEmpty else { throw AIError.noKey }
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces) + "/chat/completions")
        else { throw AIError.unreadable("bad base URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Longer than identify's: a project question reads far more than three pages.
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        // Read before anything can throw, for the same reason identify does it: a reply
        // the provider billed for is spend whether or not it turned out to be usable.
        let usage = body.flatMap { parseTokenUsage($0) }
        let text = ((body?["choices"] as? [[String: Any]])?.first?["message"]
                    as? [String: Any])?["content"] as? String
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        await record(usage: usage, feature: feature, succeeded: !trimmed.isEmpty)

        if !trimmed.isEmpty { return trimmed }
        guard (200..<300).contains(code) else {
            throw AIError.http(code, (body?["error"] as? [String: Any])?["message"] as? String ?? "")
        }
        throw AIError.unreadable("the reply had no text in it")
    }

    /// Best-effort: a broken spend ledger must never be the reason an AI call fails or
    /// its error is swallowed, so a write failure here is dropped, not surfaced.
    private func record(usage: TokenUsage?, feature: AIFeature, succeeded: Bool) async {
        guard let spendRecorder else { return }
        let usage = usage ?? .zero
        let price = PriceTable.loadCustom().price(model: model, endpoint: baseURL)
        let billed = price.map { cost(usage: usage, price: $0) }
        try? await spendRecorder.recordSpend(timestamp: Date(), model: model, endpoint: baseURL,
                                              feature: feature, usage: usage, cost: billed, succeeded: succeeded)
        await SpendSignal.shared.bump()
    }
}


/// Bumped after every recorded call, so anything showing a total can notice.
///
/// The AI panel used to refresh on the count of naming guesses, which meant that improving
/// a citation, asking a reading project or testing the connection all spent money without
/// the number moving.
@MainActor
final class SpendSignal: ObservableObject {
    static let shared = SpendSignal()
    @Published private(set) var version = 0
    func bump() { version += 1 }
}
