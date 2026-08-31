import SwiftUI
import AppKit
import PaperShelfCore

/// The files a naming preview is drawn from.
///
/// The pattern editor shows what each field currently produces, which needs a real
/// document, and the settings window has no scanner of its own. The main window publishes
/// a handful of items here as its results move; the editor reads them. Empty is a
/// legitimate state, and the editor says so rather than drawing a row of blanks.
@MainActor
final class NamingPreviewSource: ObservableObject {
    static let shared = NamingPreviewSource()

    /// Whichever file is open for review, else the first result, so a chip means something
    /// before anything is selected.
    @Published var reference: Item?
    /// A few files to show the whole pattern against. Deliberately a handful: this is a
    /// sanity check on a pattern, not a second copy of the plan.
    @Published var samples: [Item] = []
    /// Only the guesses belonging to the items above. Copying the whole table on every
    /// change would cost more than the preview it feeds.
    @Published var guesses: [String: BookGuess] = [:]

    private init() {}

    func update(reference: Item?, samples: [Item], guesses: [String: BookGuess]) {
        let wanted = Set(samples.map(\.key) + [reference?.key].compactMap { $0 })
        let trimmed = guesses.filter { wanted.contains($0.key) }
        // Assigning identical values would publish a change and redraw the editor for
        // nothing, and the results move far more often than these five do.
        if self.reference?.key != reference?.key { self.reference = reference }
        if self.samples.map(\.key) != samples.map(\.key) { self.samples = samples }
        if self.guesses != trimmed { self.guesses = trimmed }
    }
}

/// The naming pattern and the rules applied after it.
///
/// This was the largest thing in the sidebar and the last to leave it. Chips, the text
/// form they round-trip through, the tidying rules and the date fallbacks are one subject
/// and now one pane.
struct NameRulesSettings: View {
    @Bindable private var prefs = Prefs.shared

    @ObservedObject private var source = NamingPreviewSource.shared
    @State private var draggingElementIndex: Int?
    @State private var editingElementIndex: Int?

    private static let sampleName = "Extracto Se\u{00F1}or_Acme 66 (1)_23_08_2026.pdf"

    private var rules: NameRules {
        NameRules(casing: prefs.ruleCasing, separator: prefs.ruleSeparator,
                  stripSymbols: prefs.ruleStripSymbols, stripDiacritics: prefs.ruleStripDiacritics,
                  asciiOnly: prefs.ruleAsciiOnly, dropLeadingArticles: prefs.ruleDropArticles,
                  maxLength: prefs.ruleMaxLength, datePosition: prefs.ruleDatePosition,
                  dateFormat: prefs.ruleDateFormat)
    }

    /// Casing is a no-op on a token that is already digits.
    private func showsCasing(_ kind: NameToken.Kind) -> Bool {
        switch kind {
        case .date, .year, .counter: return false
        default: return true
        }
    }

    /// The three date switches, in the form the renderer reads them.
    private var fallbacks: DateFallbacks {
        DateFallbacks(folderNames: prefs.useFolderNames,
                      metadataDate: prefs.useMetadataDate,
                      fileDate: prefs.useFileDate)
    }

    /// Rendered exactly the way Plan will render it — same rules, same fallbacks. A
    /// preview that took a shortcut the real run does not would be worse than none.
    private var namePatternReferencePreview: NamePreview? {
        guard let item = source.reference else { return nil }
        return PaperShelfCore.preview(namePattern, for: item,
                                     guess: source.guesses[item.key], under: item.root,
                                     rules: rules, fallbacks: fallbacks)
    }

    var body: some View {
        Form {
            namingPanel
            datesPanel
        }
        .formStyle(.grouped)
    }

    private var namePattern: NamePattern {
        NamePattern(parsing: prefs.namePattern, maxTotalLength: prefs.namePatternMaxLength)
    }

    /// Every chip and text-field edit goes through here, so the two stay in sync: both
    /// read and write the same pair of AppStorage values.

    /// Every chip and text-field edit goes through here, so the two stay in sync: both
    /// read and write the same pair of AppStorage values.
    private func updateNamePattern(_ transform: (inout NamePattern) -> Void) {
        var updated = namePattern
        transform(&updated)
        prefs.namePattern = updated.text
        prefs.namePatternMaxLength = updated.maxTotalLength
    }

    private func updateNameToken(at index: Int, _ transform: (inout NameToken) -> Void) {
        updateNamePattern { pattern in
            guard pattern.elements.indices.contains(index),
                  case .token(var token) = pattern.elements[index] else { return }
            transform(&token)
            pattern.elements[index] = .token(token)
        }
    }

    /// Runs once: a user who already had toggles set gets an arranged pattern that
    /// reproduces them, rather than landing on today's plain default and looking like
    /// their settings were dropped. After this the pattern is its own preference and the
    /// toggles it replaces (date position, date format, max length) are read here only.

    /// Matched by position among token elements, not by kind: two tokens of the same
    /// kind can carry different options and must not be shown each other's value.
    private func namePatternChipPreview(atElementIndex index: Int) -> NameTokenPreview? {
        let tokenIndex = namePattern.elements[..<index].reduce(into: 0) { count, element in
            if case .token = element { count += 1 }
        }
        let tokens = namePatternReferencePreview?.tokens ?? []
        return tokens.indices.contains(tokenIndex) ? tokens[tokenIndex] : nil
    }

    private func namingLabel(for kind: NameToken.Kind) -> String {
        switch kind {
        case .date: return "Date"
        case .year: return "Year"
        case .title: return "Title"
        case .author: return "Author"
        case .publisher: return "Publisher"
        case .journal: return "Journal"
        case .folder: return "Folder"
        case .originalStem: return "Original name"
        case .counter: return "Counter"
        }
    }

    private func namingLabel(for casing: NameToken.Casing) -> String {
        switch casing {
        case .unchanged: return "As is"
        case .lower: return "lowercase"
        case .upper: return "UPPERCASE"
        case .titleCase: return "Title Case"
        }
    }

    private func namingLabel(for abbreviation: NameToken.Abbreviation) -> String {
        switch abbreviation {
        case .none: return "Full"
        case .compact: return "Compact"
        case .surname: return "Surname only"
        case .initials: return "Initials"
        }
    }

    /// Casing is a no-op on a token that is already digits.

    @ViewBuilder
    private var namingPanel: some View {
            Section {
                HStack(spacing: Space.snug) {
                    ForEach(NamePattern.presets) { preset in
                        Button(preset.name) {
                            updateNamePattern { $0 = preset.pattern }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(preset.summary)
                    }
                }
                .padding(.vertical, Space.hair)

                namingChipRow
                    .tip("Drag a field to reorder it, click one to adjust it")

                LabeledContent("Pattern") {
                    TextField("", text: $prefs.namePattern, prompt: Text("[date]-[title]"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(Face.code)
                }
                .tip("Chips and this text describe the same pattern; edit whichever is easier")
            } header: {
                Text("Naming pattern")
            } footer: {
                namingPreviewFooter
            }

            Section {
                Picker("Case", selection: $prefs.ruleCasing) {
                    ForEach(NameRules.Casing.allCases) { Text($0.label).tag($0) }
                }
                .help("Applied to the whole name, date aside")
                Picker("Separators", selection: $prefs.ruleSeparator) {
                    ForEach(NameRules.Separator.allCases) { Text($0.label).tag($0) }
                }
                .tip("How runs of spaces, dashes and underscores are written")
                Toggle("Remove symbols", isOn: $prefs.ruleStripSymbols)
                    .tip("Punctuation becomes a separator: report (1)! reads report-1")
                Toggle("Remove accents", isOn: $prefs.ruleStripDiacritics)
                    .help("señor becomes senor. Separate from Remove symbols, since ñ is a letter")
                Toggle("ASCII only", isOn: $prefs.ruleAsciiOnly)
                    .tip("Non-ASCII becomes a separator, so words stay apart")
                Toggle("Drop a leading The, A, El…", isOn: $prefs.ruleDropArticles)
                    .help("So a shelf sorts by what the book is called rather than by its article")
                Picker("Date goes", selection: $prefs.ruleDatePosition) {
                    ForEach(NameRules.DatePosition.allCases) { Text($0.label).tag($0) }
                }
                .help("Whether the date leads the name or trails it")
                Picker("Date looks like", selection: $prefs.ruleDateFormat) {
                    ForEach(NameRules.DateFormat.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Max length") {
                    HStack(spacing: Space.snug) {
                        Slider(value: Binding(get: { Double(prefs.ruleMaxLength) },
                                              set: { prefs.ruleMaxLength = Int($0) }),
                               in: 0...120, step: 5)
                        Text(prefs.ruleMaxLength == 0 ? "off" : "\(prefs.ruleMaxLength)")
                            .monospacedDigit()
                            .frame(width: 26, alignment: .trailing)
                    }
                }
                .tip("Trims the name on a word boundary; the date is never cut")
            } header: {
                // These decide how each piece of a name is written; the pattern above
                // decides what pieces there are and in what order. Both reach Plan and
                // Apply, the pattern by way of `Options.pattern` and these through the
                // same `NameRules` the renderer is handed.
                Text("Tidying")
            } footer: {
                VStack(alignment: .leading, spacing: Space.hair) {
                    Text(Self.sampleName)
                        .foregroundStyle(.secondary)
                    HStack(spacing: Space.tight) {
                        Image(systemName: "arrow.turn.down.right")
                            .foregroundStyle(.tertiary)
                        Text(normalizedName(for: Self.sampleName, rules: rules))
                    }
                }
                .font(Face.mono)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, Space.hair)
            }
    }

    private var namingChipRow: some View {
        FlowLayout(spacing: Space.snug) {
            ForEach(Array(namePattern.elements.enumerated()), id: \.offset) { index, element in
                chipView(for: element, at: index)
                    .onDrag {
                        draggingElementIndex = index
                        return NSItemProvider(object: String(index) as NSString)
                    }
                    .onDrop(of: [.text], delegate: ChipDropDelegate(
                        index: index,
                        draggingIndex: $draggingElementIndex,
                        reorder: { from, to in
                            updateNamePattern { pattern in
                                guard pattern.elements.indices.contains(from),
                                      pattern.elements.indices.contains(to) else { return }
                                let moved = pattern.elements.remove(at: from)
                                pattern.elements.insert(moved, at: to)
                            }
                        }
                    ))
            }
            addTokenMenu
        }
    }

    @ViewBuilder
    private func chipView(for element: NameElement, at index: Int) -> some View {
        switch element {
        case .token(let token):
            tokenChip(token, at: index)
        case .literal(let text):
            literalChip(text, at: index)
        }
    }

    private func tokenChip(_ token: NameToken, at index: Int) -> some View {
        let preview = namePatternChipPreview(atElementIndex: index)
        return HStack(spacing: Space.tight) {
            VStack(alignment: .leading, spacing: 0) {
                Text(namingLabel(for: token.kind))
                    .font(Face.micro.weight(.semibold))
                if let preview, !preview.isEmpty {
                    Text(preview.value)
                        .font(Face.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 90, alignment: .leading)
                } else {
                    Text("empty")
                        .font(Face.micro.italic())
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                updateNamePattern { $0.elements.remove(at: index) }
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove \(namingLabel(for: token.kind))")
        }
        .padding(.horizontal, Space.step)
        .padding(.vertical, Space.tight)
        .background(RoundedRectangle(cornerRadius: Metric.card).fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: Metric.card).strokeBorder(.tertiary.opacity(0.35)))
        .contentShape(Rectangle())
        .onTapGesture { editingElementIndex = index }
        .popover(isPresented: Binding(
            get: { editingElementIndex == index },
            set: { if !$0 { editingElementIndex = nil } }
        )) {
            tokenOptions(token, at: index)
        }
    }

    private func literalChip(_ text: String, at index: Int) -> some View {
        HStack(spacing: Space.tight) {
            Text(text.isEmpty ? "·" : text)
                .font(Face.mono)
                .foregroundStyle(.secondary)
            Button {
                updateNamePattern { $0.elements.remove(at: index) }
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove separator")
        }
        .padding(.horizontal, Space.tight)
        .padding(.vertical, Space.tight)
    }

    @ViewBuilder
    private func tokenOptions(_ token: NameToken, at index: Int) -> some View {
        let maxLengthLabel = token.maxLength == 0 ? "Max length: off" : "Max length: \(token.maxLength)"
        Form {
            if showsCasing(token.kind) {
                Picker("Case", selection: Binding(
                    get: { token.casing },
                    set: { newValue in updateNameToken(at: index) { $0.casing = newValue } }
                )) {
                    ForEach(NameToken.Casing.allCases) { Text(namingLabel(for: $0)).tag($0) }
                }
            }
            Picker("Shorten", selection: Binding(
                get: { token.abbreviation },
                set: { newValue in updateNameToken(at: index) { $0.abbreviation = newValue } }
            )) {
                ForEach(NameToken.Abbreviation.allCases) { Text(namingLabel(for: $0)).tag($0) }
            }
            Stepper(maxLengthLabel, value: Binding(
                get: { token.maxLength },
                set: { newValue in updateNameToken(at: index) { $0.maxLength = newValue } }
            ), in: 0...80, step: 5)
        }
        .padding(Space.roomy)
        .frame(width: 230)
    }

    private var addTokenMenu: some View {
        Menu {
            ForEach(NameToken.Kind.allCases) { kind in
                Button(namingLabel(for: kind)) {
                    updateNamePattern { pattern in
                        // A token landing directly against another token with nothing
                        // between them renders glued together (assemble() in
                        // Patterns.swift only drops a separator, never adds one), so a
                        // dash goes in first when the pattern does not already end on
                        // one of its own.
                        if case .token = pattern.elements.last {
                            pattern.elements.append(.literal("-"))
                        }
                        pattern.elements.append(.token(NameToken(kind)))
                    }
                }
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .tip("Add a field to the pattern")
    }

    @ViewBuilder
    private var namingPreviewFooter: some View {
        let samples = source.samples
        VStack(alignment: .leading, spacing: Space.tight) {
            if samples.isEmpty {
                Text("The plan appears once files are found.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(samples) { item in
                    let rendered = PaperShelfCore.preview(
                        namePattern, for: item, guess: source.guesses[item.key],
                        under: item.root, rules: rules, fallbacks: fallbacks)
                    HStack(spacing: Space.tight) {
                        Text(rendered.originalName)
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text(rendered.renderedName)
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }
        }
        .font(Face.mono)
        .padding(.top, Space.hair)
    }

    @ViewBuilder
    private var datesPanel: some View {
            Section {
                Toggle("Use the folder name", isOn: $prefs.useFolderNames)
                    .tip("Take the date, and a name for scan001, from the folder")
                Toggle("Use the PDF's creation date", isOn: $prefs.useMetadataDate)
                    .tip("When the PDF was written, often long after the period it covers")
                Toggle("Use the file's modification date", isOn: $prefs.useFileDate)
                    .tip("Least trustworthy: often just when the file landed here")
            } header: {
                Text("When the filename has no date")
            } footer: {
                Text("Tried in this order. A date already in the filename always wins, "
                     + "since it is the only one the document itself states.")
                    .font(Face.caption)
                    .foregroundStyle(.secondary)
            }
    }
}
