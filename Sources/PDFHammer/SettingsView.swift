import SwiftUI
import PDFHammerCore

/// Settings live in their own window (⌘,) rather than the sidebar, because they are set
/// once and then forgotten, unlike the naming rules next to the results.
struct SettingsView: View {
    @AppStorage("aiModel") private var model = "gpt-4o-mini"
    @AppStorage("aiBaseURL") private var baseURL = "https://api.openai.com/v1"
    @AppStorage("aiUseEnvironment") private var useEnvironment = true

    @State private var key = ""
    @State private var status: Status = .idle
    @State private var testing = false

    private enum Status: Equatable {
        case idle, ok(String), failed(String)
    }

    private var environmentKey: String? { AIClient.environmentKey() }

    var body: some View {
        Form {
            Section {
                Toggle("Use OPENAI_API_KEY from the environment", isOn: $useEnvironment)
                if useEnvironment {
                    LabeledContent("Environment") {
                        if let found = environmentKey ?? DiscoveredKey.shared.value {
                            Label("Found, ending \(String(found.suffix(4)))",
                                  systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
                        } else {
                            Label("Not found in the environment or your login shell",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60)))
                        }
                    }
                }
                LabeledContent("API key") {
                    SecureField("", text: $key, prompt: Text(useEnvironment ? "Optional fallback" : "sk-…"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveKey)
                }
                HStack {
                    Button("Save key", action: saveKey).disabled(key.isEmpty)
                    Button("Remove") {
                        Keychain.remove(account: "openai")
                        StoredKey.shared.update(nil)
                        key = ""
                        status = .ok("Key removed")
                    }
                    .disabled(key.isEmpty)
                }
            } header: {
                Text("OpenAI")
            } footer: {
                Text("The key is kept in your Keychain, never in preferences. A Finder-launched "
                     + "app inherits launchd's environment rather than a shell's, so when the "
                     + "variable is not visible the login shell is asked once, in memory only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                TextField("Base URL", text: $baseURL)
                    .font(.system(.callout, design: .monospaced))
            } header: {
                Text("Endpoint")
            } footer: {
                Text("Any OpenAI-compatible endpoint. The model list is read from it, "
                     + "and picked in the AI panel of the sidebar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Button("Test connection", action: test).disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    switch status {
                    case .idle: EmptyView()
                    case .ok(let message):
                        Label(message, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
                    case .failed(let message):
                        Text(message)
                            .foregroundStyle(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } footer: {
                Text("Renaming with AI sends the filename and the first pages' text to the "
                     + "service above. It never sends the file itself, and never runs unless "
                     + "you ask for it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { key = StoredKey.shared.value ?? "" }
    }

    private func saveKey() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(trimmed, account: "openai")
        StoredKey.shared.update(trimmed)
        status = .ok("Key saved to the Keychain")
    }

    private func test() {
        testing = true
        status = .idle
        let client = AIClient(baseURL: baseURL, model: model, apiKey: resolvedKey(useEnvironment: useEnvironment))
        Task {
            do {
                let guess = try await client.identify(
                    filename: "godel-escher-bach.pdf",
                    excerpt: "Gödel, Escher, Bach: an Eternal Golden Braid. Douglas R. Hofstadter. 1979."
                )
                status = .ok("Answered: \(guess.title)")
            } catch {
                status = .failed(error.localizedDescription)
            }
            testing = false
        }
    }
}

/// The stored key wins when there is one; the environment is the fallback.
func resolvedKey(useEnvironment: Bool) -> String {
    if let stored = StoredKey.shared.value, !stored.isEmpty { return stored }
    guard useEnvironment else { return "" }
    if let inherited = AIClient.environmentKey() { return inherited }
    return DiscoveredKey.shared.value ?? ""
}

/// Reads the Keychain once per launch and holds the answer.
///
/// This is called from `aiClient`, which is read inside view bodies, and SwiftUI
/// evaluates those constantly. Querying the Keychain each time is what produced an
/// unlock prompt every few seconds; one read per launch produces at most one.
final class StoredKey: @unchecked Sendable {
    static let shared = StoredKey()
    private let lock = NSLock()
    private var loaded = false
    private var cached: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            loaded = true
            cached = Keychain.get(account: "openai")
        }
        return cached
    }

    /// Called after writing, so the next read does not go back to the Keychain.
    func update(_ key: String?) {
        lock.lock()
        defer { lock.unlock() }
        loaded = true
        cached = key
    }
}

/// The login shell is asked once per launch, lazily, and the answer is kept in memory
/// only. Storing it would be deciding on the user's behalf that a key belongs on disk.
final class DiscoveredKey: @unchecked Sendable {
    static let shared = DiscoveredKey()
    private let lock = NSLock()
    private var looked = false
    private var found: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        if !looked {
            looked = true
            found = AIClient.loginShellKey()
        }
        return found
    }
}
