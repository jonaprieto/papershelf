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
                        if let environmentKey {
                            Label("Found, ending \(String(environmentKey.suffix(4)))",
                                  systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
                        } else {
                            Label("Not set for this app", systemImage: "exclamationmark.triangle.fill")
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
                        key = ""
                        status = .ok("Key removed")
                    }
                    .disabled(key.isEmpty)
                }
            } header: {
                Text("OpenAI")
            } footer: {
                Text("The key is kept in your Keychain, never in preferences. "
                     + "An app launched from Finder does not inherit a shell's environment, "
                     + "so the variable only helps when the app is launched from a terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Model") {
                TextField("Model", text: $model)
                TextField("Base URL", text: $baseURL)
                    .font(.system(.callout, design: .monospaced))
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
        .onAppear { key = Keychain.get(account: "openai") ?? "" }
    }

    private func saveKey() {
        Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), account: "openai")
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
    if let stored = Keychain.get(account: "openai"), !stored.isEmpty { return stored }
    return useEnvironment ? (AIClient.environmentKey() ?? "") : ""
}
