import Foundation
import Security
import PDFHammerCore

// MARK: - Key storage

/// The API key lives in the Keychain, not in preferences. A preferences plist is a plain
/// file any process running as you can read; a key is a credential and belongs where the
/// system already protects credentials.
enum Keychain {
    private static let service = "com.jonaprieto.pdfhammer"

    static func set(_ value: String, account: String) {
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
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

    func identify(filename: String, excerpt: String) async throws -> BookGuess {
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
        guard (200..<300).contains(code) else {
            throw AIError.http(code, String(data: data, encoding: .utf8) ?? "")
        }

        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let reply = ((object?["choices"] as? [[String: Any]])?.first?["message"]
            as? [String: Any])?["content"] as? String ?? ""
        guard let guess = parseBookGuess(reply) else { throw AIError.unreadable(reply) }
        return guess
    }
}
