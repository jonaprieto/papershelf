import SwiftUI
import AppKit
import PDFHammerCore

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
    @AppStorage("namePattern") private var namePatternText = ""
    @AppStorage("namePatternMaxLength") private var namePatternMaxLength = 0
    @AppStorage("ruleCasing") private var ruleCasing: NameRules.Casing = .lowercase
    @AppStorage("ruleSeparator") private var ruleSeparator: NameRules.Separator = .keep
    @AppStorage("ruleStripSymbols") private var ruleStripSymbols = false
    @AppStorage("ruleStripDiacritics") private var ruleStripDiacritics = false
    @AppStorage("ruleAsciiOnly") private var ruleAsciiOnly = false
    @AppStorage("ruleDropArticles") private var ruleDropArticles = false
    @AppStorage("ruleMaxLength") private var ruleMaxLength = 0
    @AppStorage("ruleDatePosition") private var ruleDatePosition: NameRules.DatePosition = .prefix
    @AppStorage("ruleDateFormat") private var ruleDateFormat: NameRules.DateFormat = .dashed
    @AppStorage("useFolderNames") private var useFolderNames = true
    @AppStorage("useMetadataDate") private var useMetadataDate = true
    @AppStorage("useFileDate") private var useFileDate = false

    @ObservedObject private var source = NamingPreviewSource.shared
    @State private var draggingElementIndex: Int?
    @State private var editingElementIndex: Int?

    private static let sampleName = "Extracto Se\u{00F1}or_Acme 66 (1)_23_08_2026.pdf"

    private var rules: NameRules {
        NameRules(casing: ruleCasing, separator: ruleSeparator,
                  stripSymbols: ruleStripSymbols, stripDiacritics: ruleStripDiacritics,
                  asciiOnly: ruleAsciiOnly, dropLeadingArticles: ruleDropArticles,
                  maxLength: ruleMaxLength, datePosition: ruleDatePosition,
                  dateFormat: ruleDateFormat)
    }

    /// Casing is a no-op on a token that is already digits.
    private func showsCasing(_ kind: NameToken.Kind) -> Bool {
        switch kind {
        case .date, .year, .counter: return false
        default: return true
        }
    }

    private var namePatternReferencePreview: NamePreview? {
        guard let item = source.reference else { return nil }
        return PDFHammerCore.preview(namePattern, for: item,
                                     guess: source.guesses[item.key], under: item.root)
    }

    var body: some View {
        Form {
            namingPanel
            datesPanel
        }
        .formStyle(.grouped)
    }

    private var namePattern: NamePattern {
        NamePattern(parsing: namePatternText, maxTotalLength: namePatternMaxLength)
    }

    /// Every chip and text-field edit goes through here, so the two stay in sync: both
    /// read and write the same pair of AppStorage values.

    /// Every chip and text-field edit goes through here, so the two stay in sync: both
    /// read and write the same pair of AppStorage values.
    private func updateNamePattern(_ transform: (inout NamePattern) -> Void) {
        var updated = namePattern
        transform(&updated)
        namePatternText = updated.text
        namePatternMaxLength = updated.maxTotalLength
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
                HStack(spacing: 6) {
                    ForEach(NamePattern.presets) { preset in
                        Button(preset.name) {
                            updateNamePattern { $0 = preset.pattern }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(preset.summary)
                    }
                }
                .padding(.vertical, 2)

                namingChipRow
                    .tip("Drag a field to reorder it, click one to adjust it")

                LabeledContent("Pattern") {
                    TextField("", text: $namePatternText, prompt: Text("[date]-[title]"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                }
                .tip("Chips and this text describe the same pattern; edit whichever is easier")
            } header: {
                Text("Naming pattern")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Note(icon: "info.circle.fill", tint: .secondary,
                         text: "Not used yet: Plan and Apply still use Name rules below.",
                         size: .caption)
                    namingPreviewFooter
                }
            }

            Section {
                Picker("Case", selection: $ruleCasing) {
                    ForEach(NameRules.Casing.allCases) { Text($0.label).tag($0) }
                }
                .help("Applied to the whole name, date aside")
                Picker("Separators", selection: $ruleSeparator) {
                    ForEach(NameRules.Separator.allCases) { Text($0.label).tag($0) }
                }
                .tip("How runs of spaces, dashes and underscores are written")
                Toggle("Remove symbols", isOn: $ruleStripSymbols)
                    .tip("Punctuation becomes a separator: report (1)! reads report-1")
                Toggle("Remove accents", isOn: $ruleStripDiacritics)
                    .help("señor becomes senor. Separate from Remove symbols, since ñ is a letter")
                Toggle("ASCII only", isOn: $ruleAsciiOnly)
                    .tip("Non-ASCII becomes a separator, so words stay apart")
                Toggle("Drop a leading The, A, El…", isOn: $ruleDropArticles)
                    .help("So a shelf sorts by what the book is called rather than by its article")
                Picker("Date goes", selection: $ruleDatePosition) {
                    ForEach(NameRules.DatePosition.allCases) { Text($0.label).tag($0) }
                }
                .help("Whether the date leads the name or trails it")
                Picker("Date looks like", selection: $ruleDateFormat) {
                    ForEach(NameRules.DateFormat.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Max length") {
                    HStack(spacing: 6) {
                        Slider(value: Binding(get: { Double(ruleMaxLength) },
                                              set: { ruleMaxLength = Int($0) }),
                               in: 0...120, step: 5)
                        Text(ruleMaxLength == 0 ? "off" : "\(ruleMaxLength)")
                            .monospacedDigit()
                            .frame(width: 26, alignment: .trailing)
                    }
                }
                .tip("Trims the name on a word boundary; the date is never cut")
            } header: {
                // These three, plus everything above, are what Preview and Apply actually
                // use (NameRules/normalizedName, Hammer.swift): the Naming pattern section
                // above is not wired into that pipeline yet (render()'s own header comment
                // in Patterns.swift says as much), so these controls stay here rather than
                // being retired in favour of a pattern that does not yet drive real output.
                Text("Name rules")
            } footer: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.sampleName)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.turn.down.right")
                            .foregroundStyle(.tertiary)
                        Text(normalizedName(for: Self.sampleName, rules: rules))
                    }
                }
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 2)
            }
    }

    private var namingChipRow: some View {
        FlowLayout(spacing: 6) {
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
        return HStack(spacing: 5) {
            VStack(alignment: .leading, spacing: 0) {
                Text(namingLabel(for: token.kind))
                    .font(.caption2.weight(.semibold))
                if let preview, !preview.isEmpty {
                    Text(preview.value)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 90, alignment: .leading)
                } else {
                    Text("empty")
                        .font(.caption2.italic())
                        .foregroundStyle(.tertiary)
                }
            }
            Button {
                updateNamePattern { $0.elements.remove(at: index) }
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Remove \(namingLabel(for: token.kind))")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.tertiary.opacity(0.35)))
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
        HStack(spacing: 3) {
            Text(text.isEmpty ? "·" : text)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            Button {
                updateNamePattern { $0.elements.remove(at: index) }
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Remove separator")
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
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
        .padding(14)
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
        VStack(alignment: .leading, spacing: 3) {
            if samples.isEmpty {
                Text("The plan appears once files are found.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(samples) { item in
                    let rendered = PDFHammerCore.preview(namePattern, for: item, guess: source.guesses[item.key], under: item.root)
                    HStack(spacing: 4) {
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
        .font(.caption.monospaced())
        .padding(.top, 2)
    }

    @ViewBuilder
    private var datesPanel: some View {
            Section {
                Toggle("Use the folder name", isOn: $useFolderNames)
                    .tip("Take the date, and a name for scan001, from the folder")
                Toggle("Use the PDF's creation date", isOn: $useMetadataDate)
                    .tip("When the PDF was written, often long after the period it covers")
                Toggle("Use the file's modification date", isOn: $useFileDate)
                    .tip("Least trustworthy: often just when the file landed here")
            } header: {
                Text("When the filename has no date")
            } footer: {
                Text("Tried in this order. A date already in the filename always wins, "
                     + "since it is the only one the document itself states.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }
}
