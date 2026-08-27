import Foundation
import PDFHammerCore

// MARK: - Key storage

/// The API key is kept in a file of its own under Application Support, readable only by
/// this user.
///
/// The Keychain would be the better home, but every rebuild of an ad-hoc signed app is a
/// different signature and the Keychain asks for permission again each time, which makes
/// development miserable. A 0600 file is not a plist that other tools sync or index, and
/// the environment variable is still the recommended route.
enum KeyStore {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDF Hammer", isDirectory: true)
    }

    private static func file(_ account: String) -> URL {
        directory.appendingPathComponent("\(account).key")
    }

    static func set(_ value: String, account: String) {
        remove(account: account)
        guard !value.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(value.utf8).write(to: file(account), options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: file(account).path)
    }

    static func get(account: String) -> String? {
        guard let data = try? Data(contentsOf: file(account)),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    static func remove(account: String) {
        try? FileManager.default.removeItem(at: file(account))
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

    /// Where a completed call is logged. Optional so every existing call site keeps
    /// compiling unchanged; nil simply means this call is not tracked.
    var spendRecorder: SpendRecorder? = nil

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

    /// Best-effort: a broken spend ledger must never be the reason an AI call fails or
    /// its error is swallowed, so a write failure here is dropped, not surfaced.
    private func record(usage: TokenUsage?, feature: AIFeature, succeeded: Bool) async {
        guard let spendRecorder else { return }
        let usage = usage ?? .zero
        let price = PriceTable.loadCustom().price(model: model, endpoint: baseURL)
        let billed = price.map { cost(usage: usage, price: $0) }
        try? await spendRecorder.recordSpend(timestamp: Date(), model: model, endpoint: baseURL,
                                              feature: feature, usage: usage, cost: billed, succeeded: succeeded)
    }
}
