import SwiftUI
import PDFHammerCore

/// The settings, as bare `Section`s for the sidebar's own `Form`.
///
/// They used to be a window of their own. That window sized itself to the whole form at
/// once (`fixedSize` vertically, on six sections including a spend ledger), so on anything
/// short of a large display the bottom of it was simply off the screen with no way to
/// scroll to it. In the sidebar they sit in the same scrolling panel as every other tab,
/// and there is one place to look for a setting rather than two.
struct SettingsPanel: View {
    /// Which of its sections to draw. The panel owns the key, the endpoint, the price
    /// table, the ledger and the plugin, and those now live on two different settings
    /// panes; a flag is cheaper than either pane owning a copy of the other's logic.
    struct Sections: OptionSet {
        let rawValue: Int
        static let ai = Sections(rawValue: 1 << 0)
        static let plugin = Sections(rawValue: 1 << 1)
        static let all: Sections = [.ai, .plugin]
    }

    var sections: Sections = .all

    @AppStorage("aiModel") private var model = "gpt-4o-mini"
    @AppStorage("aiBaseURL") private var baseURL = "https://api.openai.com/v1"
    @AppStorage("autoIdentify") private var autoIdentify = false
    /// Read from the endpoint when the key works. Empty until then, which is why the
    /// chosen model is offered as its own row: an endpoint that cannot be reached must
    /// not silently change which model is configured.
    @State private var availableModels: [String] = []
    @AppStorage("aiUseEnvironment") private var useEnvironment = true

    /// The ledger's home. Nil only when the database could not be opened at all, in
    /// which case the spend sections say so rather than showing an empty ledger as though
    /// nothing had been spent.
    var library: Library? = Library.shared

    @State private var key = ""
    @State private var status: Status = .idle
    @State private var testing = false

    @ObservedObject private var priceBook: PriceBook = .shared
    @State private var editingPrice = false
    @State private var draftInput = ""
    @State private var draftOutput = ""
    @State private var draftCurrency = "USD"

    @State private var entries: [SpendRecord] = []
    @State private var entriesLoadFailed = false

    @State private var pluginStatus = ChatGPTPlugin.status()
    @State private var pluginMessage: Status = .idle

    private enum Status: Equatable {
        case idle, ok(String), failed(String)
    }

    private var environmentKey: String? { AIClient.environmentKey() }

    var body: some View {
        // Bare Sections, like every other tab: the sidebar owns the Form, and nesting a
        // second one inside it boxes and indents this tab differently from its siblings.
        Group {
            if sections.contains(.ai) {
            Section {
                Toggle("Use OPENAI_API_KEY from the environment", isOn: $useEnvironment)
                if useEnvironment {
                    LabeledContent("Environment") {
                        if let found = environmentKey ?? DiscoveredKey.shared.value {
                            Label("Found, ending \(String(found.suffix(4)))",
                                  systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Ink.green)
                        } else {
                            Label("Not found in the environment or your login shell",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Ink.amber)
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
                        KeyStore.remove(account: "openai")
                        StoredKey.shared.update(nil)
                        key = ""
                        status = .ok("Key removed")
                    }
                    .disabled(key.isEmpty)
                }
            } header: {
                Text("OpenAI")
            } footer: {
                Text("The key is kept in your Keychain, never in preferences, which are a plain "
                     + "file anything running as you can read. A Finder-launched app inherits "
                     + "launchd's environment rather than a shell's, so when the variable is "
                     + "not visible the login shell is asked once, in memory only.")
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
                Picker("Model", selection: $model) {
                    if !availableModels.contains(model) { Text(model).tag(model) }
                    ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Ask on each new file as I reach it", isOn: $autoIdentify)
            } header: {
                Text("Model")
            } footer: {
                Text("Only for a file that is undecided and has never been asked about, so "
                     + "browsing back over files already dealt with costs nothing.")
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
                            .foregroundStyle(Ink.green)
                    case .failed(let message):
                        Text(message)
                            .foregroundStyle(Ink.red)
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

            Section {
                priceRow
            } header: {
                Text("Price for \(model)")
            } footer: {
                Text("Seeded prices are dated, not guaranteed current. Edit one here if it "
                     + "has changed, or add one for an endpoint that is not OpenAI's own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                spendSummary
            } header: {
                Text("AI spend")
            }
            }

            if sections.contains(.plugin) {
            Section {
                chatGPTPluginRow
            } header: {
                Text("ChatGPT plugin")
            } footer: {
                Text("Writes ~/.agents/plugins/pdf-hammer and lists it in "
                     + "~/.agents/plugins/marketplace.json, merging with whatever plugins are "
                     + "already listed there rather than replacing them. Nothing is published, "
                     + "reviewed, or leaves this machine: the ChatGPT app only reads these "
                     + "files locally. It has to be restarted afterwards to notice; this does "
                     + "not restart it for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            }
        }
        .onAppear { key = StoredKey.shared.value ?? "" }
        .task {
            guard sections.contains(.ai) else { return }
            await loadEntries()
            let client = AIClient(baseURL: baseURL, model: model,
                                  apiKey: resolvedKey(useEnvironment: useEnvironment))
            guard !client.apiKey.isEmpty else { return }
            availableModels = (try? await client.models()) ?? []
        }
    }

    // MARK: - Price for the currently chosen model

    private var currentPrice: ModelPrice? {
        priceBook.table.price(model: model, endpoint: baseURL)
    }

    @ViewBuilder
    private var priceRow: some View {
        if let price = currentPrice {
            LabeledContent("Input") { Text(perMillion(price.inputPerMillion, price.currency)) }
            LabeledContent("Output") { Text(perMillion(price.outputPerMillion, price.currency)) }
            if let cached = price.cachedInputPerMillion {
                LabeledContent("Cached input") { Text(perMillion(cached, price.currency)) }
            }
            Text("Recorded \(price.recordedAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("Cost unknown for this model", systemImage: "questionmark.circle")
                .foregroundStyle(Ink.amber)
        }
        if editingPrice {
            priceEditor
        } else {
            Button(currentPrice == nil ? "Add a price" : "Edit price", action: beginEditingPrice)
        }
    }

    private var priceEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Input $/1M", text: $draftInput).textFieldStyle(.roundedBorder)
                TextField("Output $/1M", text: $draftOutput).textFieldStyle(.roundedBorder)
                TextField("Currency", text: $draftCurrency)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
            }
            HStack {
                Button("Save", action: savePrice).disabled(!draftIsValid)
                Button("Cancel") { editingPrice = false }
            }
        }
    }

    private var draftIsValid: Bool {
        Decimal(string: draftInput) != nil && Decimal(string: draftOutput) != nil
            && draftCurrency.trimmingCharacters(in: .whitespaces).count == 3
    }

    private func perMillion(_ amount: Decimal, _ currency: String) -> String {
        "\(amount.formatted(.currency(code: currency))) / 1M tokens"
    }

    private func beginEditingPrice() {
        if let price = currentPrice {
            draftInput = "\(price.inputPerMillion)"
            draftOutput = "\(price.outputPerMillion)"
            draftCurrency = price.currency
        } else {
            draftInput = ""
            draftOutput = ""
            draftCurrency = "USD"
        }
        editingPrice = true
    }

    private func savePrice() {
        guard let input = Decimal(string: draftInput), let output = Decimal(string: draftOutput) else { return }
        let price = ModelPrice(inputPerMillion: input, outputPerMillion: output,
                                currency: draftCurrency.trimmingCharacters(in: .whitespaces).uppercased(),
                                recordedAt: Date())
        priceBook.setCustom(price, endpoint: baseURL, model: model)
        editingPrice = false
    }

    // MARK: - Spend

    @ViewBuilder
    private var spendSummary: some View {
        if library == nil {
            Text("Spend tracking is not connected in this build.")
                .foregroundStyle(.secondary)
        } else if entriesLoadFailed {
            // Distinct from the empty-ledger case below: this is "could not read the
            // ledger," not "nothing has been spent," and must not be shown as $0.
            Text("Could not read the spend ledger.")
                .foregroundStyle(Ink.red)
        } else if entries.isEmpty {
            Text("No AI calls recorded yet.")
                .foregroundStyle(.secondary)
        } else {
            totalsRow(label: "All time", totals: spendTotals(for: entries))
            totalsRow(label: "This session", totals: spendTotals(for: entries, since: sessionStart))

            Divider()
            Text("By model").font(.caption).foregroundStyle(.secondary)
            let byModel = spendTotals(for: entries, groupedBy: \.model)
            ForEach(byModel.keys.sorted(), id: \.self) { key in
                totalsRow(label: key, totals: byModel[key]!)
            }

            Divider()
            Text("By feature").font(.caption).foregroundStyle(.secondary)
            let byFeature = spendTotals(for: entries, groupedBy: \.feature)
            ForEach(AIFeature.allCases, id: \.self) { feature in
                if let totals = byFeature[feature] {
                    totalsRow(label: feature.displayName, totals: totals)
                }
            }
        }
        if library != nil {
            Button("Refresh", action: { Task { await loadEntries() } })
        }
    }

    private func totalsRow(label: String, totals: SpendTotals) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(costSummary(totals))
            }
            Text(callSummary(totals))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Currencies are never added together: each gets its own term, joined for display.
    private func costSummary(_ totals: SpendTotals) -> String {
        guard !totals.byCurrency.isEmpty else { return "—" }
        return totals.byCurrency.sorted { $0.key < $1.key }
            .map { $0.value.formatted(.currency(code: $0.key)) }
            .joined(separator: " + ")
    }

    private func callSummary(_ totals: SpendTotals) -> String {
        var parts = ["\(totals.calls) call\(totals.calls == 1 ? "" : "s")"]
        if totals.failedCalls > 0 { parts.append("\(totals.failedCalls) failed") }
        if totals.callsWithUnknownCost > 0 { parts.append("\(totals.callsWithUnknownCost) cost unknown") }
        return parts.joined(separator: ", ")
    }

    private func loadEntries() async {
        guard let library else { return }
        do {
            entries = try await library.spendEntries()
            entriesLoadFailed = false
        } catch {
            // A read failure must not be shown as "no calls recorded" -- that would
            // report real, possibly nonzero spend as zero merely because it could not
            // be read back.
            entriesLoadFailed = true
        }
    }

    // MARK: - ChatGPT plugin

    @ViewBuilder
    private var chatGPTPluginRow: some View {
        if pluginStatus.installed {
            Label("Installed at \(pluginStatus.destination.path)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Ink.green)
        } else {
            Text("Not installed").foregroundStyle(.secondary)
        }

        // Missing a server only blocks (re)install, which needs one to point the plugin
        // at. Removal does not: it must stay reachable even when the plugin was installed
        // from a build (or a copy of PDF Hammer.app) that is no longer around, otherwise
        // there would be no way out of Settings short of deleting files by hand.
        let serverFound = ChatGPTPlugin.serverExecutableURL() != nil
        if !serverFound {
            Label("No pdf-hammer-mcp next to this build. Install PDF Hammer.app first.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Ink.amber)
                .fixedSize(horizontal: false, vertical: true)
        }
        if serverFound || pluginStatus.installed {
            HStack {
                if serverFound {
                    Button(pluginStatus.installed ? "Reinstall" : "Install", action: installPlugin)
                }
                if pluginStatus.installed {
                    Button("Remove", action: removePlugin)
                }
            }
        }

        switch pluginMessage {
        case .idle: EmptyView()
        case .ok(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(Ink.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Text(message)
                .foregroundStyle(Ink.red)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func installPlugin() {
        do {
            let destination = try ChatGPTPlugin.install()
            pluginStatus = ChatGPTPlugin.status()
            pluginMessage = .ok("Installed. Restart ChatGPT to see it at \(destination.path).")
        } catch {
            pluginMessage = .failed(error.localizedDescription)
        }
    }

    private func removePlugin() {
        do {
            try ChatGPTPlugin.uninstall()
            pluginStatus = ChatGPTPlugin.status()
            pluginMessage = .ok("Removed.")
        } catch {
            pluginMessage = .failed(error.localizedDescription)
        }
    }

    private func saveKey() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        KeyStore.set(trimmed, account: "openai")
        StoredKey.shared.update(trimmed)
        status = .ok("Key saved to the Keychain")
    }

    private func test() {
        testing = true
        status = .idle
        let client = AIClient(baseURL: baseURL, model: model, apiKey: resolvedKey(useEnvironment: useEnvironment),
                               spendRecorder: library)
        Task {
            do {
                let guess = try await client.identify(
                    filename: "godel-escher-bach.pdf",
                    excerpt: "Gödel, Escher, Bach: an Eternal Golden Braid. Douglas R. Hofstadter. 1979.",
                    feature: .connectionTest
                )
                status = .ok("Answered: \(guess.title)")
            } catch {
                status = .failed(error.localizedDescription)
            }
            testing = false
            await loadEntries()
            availableModels = (try? await client.models()) ?? availableModels
        }
    }
}

/// The user's own corrections and additions to the price table: small, personal, edited
/// rarely, so it is held and persisted exactly the way Palette holds highlight styles.
@MainActor
final class PriceBook: ObservableObject {
    /// One table, shared. Two windows each holding their own copy meant a price edited in
    /// Settings did not reach the panel where the model is chosen until the next launch.
    static let shared = PriceBook()

    @Published private(set) var table: PriceTable

    init() {
        table = PriceTable.loadCustom()
    }

    func setCustom(_ price: ModelPrice, endpoint: String, model: String) {
        table.setCustom(price, endpoint: endpoint, model: model)
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
            cached = KeyStore.get(account: "openai")
        }
        return cached
    }

    /// Called after writing, so the next read does not go back to the KeyStore.
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
