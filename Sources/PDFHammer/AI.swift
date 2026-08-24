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
