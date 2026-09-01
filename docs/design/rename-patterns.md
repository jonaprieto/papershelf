# rename-patterns

## Summary

The current model in Sources/PaperShelfCore/Hammer.swift is a filename normalizer, not a metadata composer: NameRules (a 9 field toggle bag) drives normalizedName, which extracts a date out of a messy existing stem and tidies what is left, falling back to folder/metadata/file dates only when the name has none. Zotero 7, Better BibTeX and JabRef all expose genuine, chip friendly token grammars, verified below with direct quotes; Mendeley's is confirmed only through secondary library guides since Mendeley Desktop's own documentation is gone. I'm proposing an additive NamePattern/NameToken/NameElement/SlugStyle model plus render/preview functions that sit alongside NameRules behind a new Options.pattern field, with a lossless one time migration and four presets grounded in what the repo already collects (BookGuess, Item.documentInfo).

## Design

All additions go in Sources/PaperShelfCore/Hammer.swift itself, in a new `// MARK: - Name patterns` section, not a separate file: findDate, FoundDate, tidy, clipped, isUninformative, withoutLeadingArticles are all `private`/internal to that file (Hammer.swift:35-228), and the renderer needs to call them directly rather than have its access level loosened across files. `NamePattern`/`NameToken`/etc. themselves are `public`, same as everything else callers outside the module touch.

## Token set

Deliberately 13 tokens, not the dozens Zotero/JabRef expose, because PaperShelf's actual structured data is thin: a BookGuess (title/author/year) and six raw PDFDocumentAttribute strings (Item.documentInfo, verified at Hammer.swift:1240-1241), plus whatever the filename/folder already say. A wide token menu would mostly be options that are empty for a bank statement.

```swift
/// One placeholder. `rawValue` is also its spelling inside `[...]` in a pattern string.
public enum NameToken: String, Sendable, CaseIterable, Identifiable, Equatable {
    case date            // year or year-month lifted from the filename/folder/metadata/AI guess
    case year            // date's first 4 digits alone
    case title           // guess.title, else the tidied stem (borrowing the folder name when the stem says nothing, exactly as normalizedName does today)
    case author          // guess.author, else documentInfo[Author]
    case folder          // nearest informative ancestor folder name (today's FolderContext.slug)
    case originalStem = "stem"   // the untouched original name, extension aside
    case pdfTitle, pdfAuthor, pdfSubject, pdfCreator, pdfProducer, pdfKeywords  // raw Item.documentInfo, unparsed
    case counter         // "2", "3", ... only once a collision needs settling; empty for the first file
    public var id: String { rawValue }
}
```

## Modifiers

Six generic `String -> String` transforms, applied left to right in the order written. `compact` and `surname` are semantic and meaningful for exactly one token each, but are harmless no-ops elsewhere (no dash to strip, no space to split on), so the parser never has to know which modifier goes with which token; an inapplicable modifier just does nothing, which is also the answer to "what happens if a pattern from a future version carries a modifier this build doesn't understand for this token."

```swift
public enum NameModifier: Sendable, Equatable {
    case upper, lower, titleCase
    case truncate(Int)   // keep this many characters, word boundary, reusing clipped(_:to:)
    case compact         // strip an internal dash: date's 2024-06 -> 202406
    case surname         // keep text after the last space: "Ada Lovelace" -> "Lovelace"

    var text: String {
        switch self {
        case .upper: return "upper"
        case .lower: return "lower"
        case .titleCase: return "titlecase"
        case .truncate(let n): return "truncate\(n)"
        case .compact: return "compact"
        case .surname: return "surname"
        }
    }
    init?(text: Substring) {
        if text == "upper" { self = .upper } else if text == "lower" { self = .lower }
        else if text == "titlecase" { self = .titleCase } else if text == "compact" { self = .compact }
        else if text == "surname" { self = .surname }
        else if text.hasPrefix("truncate"), let n = Int(text.dropFirst(8)) { self = .truncate(n) }
        else { return nil }
    }
}
```

## Elements, slug cleanup, and the pattern itself

```swift
/// One arranged piece: a placeholder with its modifiers, or text the user typed.
public enum NameElement: Sendable, Equatable {
    case token(NameToken, modifiers: [NameModifier] = [])
    case literal(String)
}

/// How free text (title/author/folder/stem/pdf* values) is cleaned up before it goes
/// into a slot. Exactly NameRules today, minus the two fields the arrangement itself now
/// expresses (datePosition, dateFormat). Reuses NameRules.Casing/Separator directly.
public struct SlugStyle: Sendable, Equatable {
    public var casing: NameRules.Casing
    public var separator: NameRules.Separator
    public var stripSymbols: Bool
    public var stripDiacritics: Bool
    public var asciiOnly: Bool
    public var dropLeadingArticles: Bool

    public init(casing: NameRules.Casing = .lowercase, separator: NameRules.Separator = .keep,
                stripSymbols: Bool = false, stripDiacritics: Bool = false,
                asciiOnly: Bool = false, dropLeadingArticles: Bool = false) { ... }
    public static let standard = SlugStyle()
}

/// An arrangeable filename pattern.
public struct NamePattern: Sendable, Equatable {
    public var elements: [NameElement]
    public var slugStyle: SlugStyle
    /// Characters, word boundary clip; 0 leaves it. Same semantics as NameRules.maxLength
    /// today, applied to the whole finished name instead of one field.
    public var maxTotalLength: Int

    public init(elements: [NameElement] = [], slugStyle: SlugStyle = .standard, maxTotalLength: Int = 0)

    /// Bracket syntax, e.g. `[date]-[title:truncate40]`. `[`, `]`, `\` inside typed
    /// literal text are escaped `\[`, `\]`, `\\`. Round-trips through init(parsing:).
    public var text: String { get }

    /// Parses the bracket syntax. A token name this build doesn't recognise (older,
    /// newer, or mistyped) is kept as an opaque `.literal` of its own bracket text,
    /// brackets included, rather than dropped: a pattern that fails to parse cleanly
    /// never silently loses a piece of itself.
    public init(parsing text: String, slugStyle: SlugStyle = .standard, maxTotalLength: Int = 0)
}
```

Grammar (hand rolled scanner, no third party parser, matching JabRef's flat bracket shape rather than Zotero's keyword-argument blocks or Better BibTeX's expression DSL, because a flat `[name:mod:mod]` block maps one to one onto a draggable chip and its own small settings popover, while a functional DSL like Better BibTeX's has no natural "one chip" reading and Zotero's keyword params need a small key=value parser for no benefit here since nothing in this token set needs a named argument, only positional modifiers):
`pattern := (literal | token)*`
`token := '[' name (':' modifier)* ']'`
`modifier := 'upper' | 'lower' | 'titlecase' | 'truncate' digits | 'compact' | 'surname'`
`literal := any run of characters with `\[`, `\]`, `\\` as escapes, up to the next unescaped `[`

## Rendering

```swift
/// Renders `pattern` for one file. Only fields already on `item`, `guess`, `folder` are
/// read, no PDF is opened, no disk is touched, matching restyled(_:options:guess:)'s own
/// promise (Hammer.swift:331-334) that a whole catalogue restyles as fast as a switch flips.
public func render(
    _ pattern: NamePattern,
    for item: Item,
    guess: BookGuess? = nil,
    folder: FolderContext = .none,
    collisionIndex: Int = 1
) -> String
```

Algorithm:
1. Resolve each `.token`'s raw value, or nil if genuinely absent: `.date` tries guess.year, then a date found in item.sourceName, then folder.prefix, then item.metadataDate, then item.modifiedDate (same order process(job:) already assembles at Hammer.swift:1249-1258, just reordered so a guess year outranks the rest, matching how filename(for guess:) already treats guess.year as if it were text found in the name, BookGuess.swift:73-81); `.year` takes date's first four characters; `.title` tries guess.title, else the tidied stem, borrowing folder.slug when that stem is uninformative (isUninformative, unchanged); `.author`/`.pdfAuthor` etc. read guess.author or item.documentInfo directly; `.counter` is nil unless collisionIndex > 1.
2. Free text tokens (title, author, folder, stem, pdfTitle, pdfAuthor, pdfSubject, pdfCreator, pdfProducer, pdfKeywords) go through `tidy(_:)` built from `pattern.slugStyle`; `withoutLeadingArticles` runs only on `.title`/`.pdfTitle` specifically, since dropping "The" from an author or a folder name is not what that rule is for. Structured tokens (date, year, counter) are left as the digits/dashes they already are.
3. Modifiers apply left to right to whatever step 1-2 produced.
4. Walk `elements` left to right. A `.literal` sitting directly next to a token that resolved empty is dropped along with it (on either side), so `[author]-[title]` with no known author renders `my-title.pdf`, not `-my-title.pdf`; nobody has to write a conditional or type a per field fallback string the way Zotero's if/endif or JabRef's `:(fallback)` require.
5. If every token resolved empty, fall back to the original stem, mirroring normalizedName's own backstop (`guard let prefix else { return slug.isEmpty ? filename : ... }`, Hammer.swift:321).
6. Clip the joined result to `maxTotalLength` with the existing `clipped(_:to:)`.
7. Pipe through the existing `sanitizedFilename`, so a raw `.pdfSubject`/`.pdfKeywords` value (unreviewed PDF metadata, can legally contain `/`, `:`, or run to any length) can never produce a broken path component.

```swift
/// render, plus the folder walk render itself does not do. Mirrors restyledFromName's
/// existing lookup (Hammer.swift:352-369), so a preview and a real run resolve the same
/// folder slug.
public func preview(
    _ pattern: NamePattern,
    for item: Item,
    guess: BookGuess? = nil,
    under root: URL,
    collisionIndex: Int = 1
) -> String {
    render(pattern, for: item, guess: guess,
           folder: folderContext(for: item.source, under: root, rules: NameRules(slug: pattern.slugStyle)),
           collisionIndex: collisionIndex)
}
```
(`NameRules(slug:)` is a tiny bridging initializer so `folderContext`'s existing `rules: NameRules` parameter, Hammer.swift:240, does not need to change; `folderContext`'s own tests, HammerTests.swift:241, stay untouched.)

## Presets

```swift
extension NamePattern {
    public static let statement = NamePattern(parsing: "[date]-[title]")                              // today's default
    public static let book = NamePattern(parsing: "[author:surname]-[year]-[title]")
    public static let authorTitle = NamePattern(parsing: "[author:surname]-[title]")
    public static let reference = NamePattern(parsing: "[year]-[author:surname]-[title:truncate40]")
    public static let presets: [(name: String, pattern: NamePattern)] = [
        ("Statement", .statement), ("Book", .book),
        ("Author + title", .authorTitle), ("Reference", .reference),
    ]
}
```

## Coexistence and migration

NameRules is not removed. `Options` gains one new field alongside `rules`:

```swift
public struct Options: Sendable {
    ...
    public var rules: NameRules          // kept, for the transition
    public var pattern: NamePattern?     // nil = today's path (normalizedName); set = render
}
```

`restyledFromName` (Hammer.swift:352-377) is the clean integration point: it already receives a full `Item`, so its one naming call becomes `if let pattern = options.pattern { render(pattern, for: item, folder: context) } else { normalizedName(...) }`. `process(job:options:)` (Hammer.swift:1195-1259) needs one adjustment: it builds facts/size/pages/info as loose locals and only assembles an `Item` at the very end via its local `item(_:_:_:)` closure, but `render` needs an `Item` as input. Fix: once facts/size/pages/info are known, call `item(source, status)` once (a throwaway destination, since `Item.destination` is a `var`) purely to hand to `render`, then call `item(realDestination, status)` again for the actual return value. This is the same "build an Item just to read one field off it" idiom the file already uses (`process(job:options:dryRunning(options),...).destinationName`, Hammer.swift:1106), not a new one.

Migration, one function, used once at first launch after upgrading:

```swift
extension NamePattern {
    public init(migrating rules: NameRules) {
        let slug = SlugStyle(casing: rules.casing, separator: rules.separator,
                              stripSymbols: rules.stripSymbols, stripDiacritics: rules.stripDiacritics,
                              asciiOnly: rules.asciiOnly, dropLeadingArticles: rules.dropLeadingArticles)
        let date = NameElement.token(.date, modifiers: rules.dateFormat == .compact ? [.compact] : [])
        let sep = NameElement.literal(rules.separator == .underscore ? "_" : "-")
        let title = NameElement.token(.title)
        self.init(elements: rules.datePosition == .prefix ? [date, sep, title] : [title, sep, date],
                  slugStyle: slug, maxTotalLength: rules.maxLength)
    }
}
```

This is lossless in the sense that it reproduces every existing NameRules combination's output exactly (every field maps onto exactly one SlugStyle field, one modifier, or one arrangement decision, with nothing dropped). In the app, `ContentView`'s ten `@AppStorage` rule* keys (ContentView.swift:24-32) are read once, converted with `NamePattern(migrating:)`, written to one new `@AppStorage("namePattern")` string via `.text`, and the old keys are left in place unread, the same way this codebase already tolerates orphaned UserDefaults keys elsewhere. `namingFingerprint` (ContentView.swift:153-160), which today hand lists eight rule fields, collapses to one line: `pattern.text`.

Once every UI call site (ContentView's namingPanel, Runner.identify/identifyPending, Catalogue) is switched onto `.pattern`, `Options.rules` and `NameRules` itself can be deleted in a separate, later commit; that is a second, independently reviewable change, not part of this one, per the project's own focused-commit convention.

## Verified facts

- NameRules holds 9 fields (casing, separator, stripSymbols, stripDiacritics, asciiOnly, dropLeadingArticles, maxLength, datePosition, dateFormat) plus a computed joiner; Casing/Separator/DatePosition/DateFormat are small String raw enums.
  EVIDENCE: Sources/PaperShelfCore/Hammer.swift:61-132

- normalizedName's actual algorithm: find a date anywhere in the stem with findDate, replace that date's range with a dash and run tidy() on the rest to get a slug, borrow the enclosing folder's slug when the stem is uninformative (generic word or digits only), drop leading articles, clip to maxLength on a word boundary, then attach the date (from the filename, else the first non-empty fallbackPrefix) at the front or back per datePosition, in dashed or compact form per dateFormat.
  EVIDENCE: Sources/PaperShelfCore/Hammer.swift:297-329, with helpers findDate:41-57, tidy:168-201, isUninformative:223-228, withoutLeadingArticles:143-151, clipped:155-163

- A date is only ever kept at year or year-month precision; even a matched YYYY-MM-DD shape discards the day when building the prefix.
  EVIDENCE: Sources/PaperShelfCore/Hammer.swift:47-49 (case .yearMonthDay, .yearMonth: return FoundDate(prefix: "\(group(1))-\(group(2))" ...))

- Fallback order for the date, all three switchable and consulted only when the filename itself has no date: folder name > PDF metadata creation date > file modification date. A date already in the filename always wins.
  EVIDENCE: Sources/PaperShelfCore/Hammer.swift:1249-1258 (process(job:)), 352-369 (restyledFromName), and the ordering comment at Hammer.swift:287-292

- Item already carries a documentInfo dictionary of raw PDF attributes (title, author, subject, creator, producer, keywords, keyed by PDFDocumentAttribute.*.rawValue) that is captured on every run but never fed into naming today.
  EVIDENCE: Sources/PaperShelfCore/Hammer.swift:522 (field), 1239-1247 (populated), 1240-1241 lists the six PDFDocumentAttribute keys read

- BookGuess (title/author/year, from an AI reading the opening pages) is the one existing path where structured fields drive a name: filename(for:rules:) joins year, title, author (in that order, empty ones dropped) into one string and re-runs it through normalizedName, so the AI's guess is treated exactly like text found in the filename, not as separate slots.
  EVIDENCE: Sources/PaperShelfCore/BookGuess.swift:71-81; called from Hammer.swift:338-339 (restyled) and Sources/PaperShelf/Runner.swift:475-488 (identify)

- A second, independent parser exists only for the bibliography view: titleWords(from:) reparses the already-normalized destination name (date out, rest split on -/_/space) to get title/year for a BibEntry when no BookGuess is known; citationKey is a fixed surname:year:firstword shape, never user configurable.
  EVIDENCE: Sources/PaperShelfCore/Bibtex.swift:82-95 (titleWords), 97-108 (citationKey), 112-131 (bibEntries)

- Collision handling today is entirely post hoc and outside any pattern: availableURL probes the filesystem and appends -2, -3, ... only once a real name clash is found; nothing before it knows about the eventual suffix.
  EVIDENCE: Sources/PaperShelfCore/Hammer.swift:993-1005; a real (non dry run) process(jobs:) run is kept serial specifically because this probing races (comment at 1082-1084)

- Two safety nets already exist that any new renderer should reuse rather than reimplement: sanitizedFilename strips / and :, trims stray punctuation, and guarantees a non-empty untitled.pdf fallback; clipped(_:to:) clips on a word boundary.
  EVIDENCE: Sources/PaperShelfCore/Hammer.swift:1066-1078 (sanitizedFilename), 153-163 (clipped)

- The UI's naming panel is literally the pile of toggles the task describes: two Pickers (Case, Separators), three plain Toggles (Remove symbols, Remove accents, ASCII only), one more Toggle (Drop leading article), two more Pickers (Date goes, Date looks like), and a Max length slider, nine controls with no way to see or change the arrangement of date vs. name.
  EVIDENCE: Sources/PaperShelf/ContentView.swift:445-482, AppStorage keys at ContentView.swift:24-32

- NameRules is decomposed field by field in three separate places today (10 @AppStorage keys, a `rules` computed property, and a hand built namingFingerprint cache key string), all of which a token based replacement would collapse to one stored string plus one field read.
  EVIDENCE: Sources/PaperShelf/ContentView.swift:24-32 (AppStorage), 121-127 (rules), 153-160 (namingFingerprint)

- The repo is Swift 6 tooling with swiftLanguageMode v5, macOS 14 minimum, no third party dependencies, split into PaperShelfCore (logic) and PaperShelf (SwiftUI) targets.
  EVIDENCE: Package.swift:1-22

- As of this session the repo went from no-git to a live git history mid task (HEAD 4d6aaea 'refactor: split the app view into files by what it draws'); the naming code (Hammer.swift, BookGuess.swift, Bibtex.swift) was untouched by that refactor, but an earlier commit (cada1ca) dropped output encryption from Hammer.swift, removing EncryptionSettings, writeOptions, and the .encrypted Status case that an initial read of the file still showed.
  EVIDENCE: git log --oneline -5 at the repository root; diff between two Hammer.swift reads in this session (1416 lines vs 1374 lines)

- Zotero 7's file renaming templates use `{{ variable param="value" }}` mustache style blocks: documented variables include authors, authorsCount, editors, creators, firstCreator, itemType, year, plus any item field (title, DOI, ISBN, citationKey); documented parameters include start, truncate, prefix, suffix, case, join, initialize, match, replaceFrom, replaceTo, regexOpts; if/elseif/else/endif blocks with ==, <, <=, >, >= handle conditional inclusion (used specifically to branch on itemType or to test a value with `match` before falling back to something else).
  EVIDENCE: https://www.zotero.org/support/file_renaming (fetched); example quoted verbatim: `{{ if itemType == "book" }} {{ISBN}} {{ elseif itemType == "preprint" }} {{ DOI }} ... {{ else }} {{ title }} {{ endif }}`

- Better BibTeX citation keys are a small functional DSL, not a flat token list: functions/filters chain with dots (`auth.lower`), fields access starts uppercase, `+` concatenates, `||` takes the first non-empty alternative, `&&` requires both, `?:` is a ternary, and whole candidate formulas are tried in order separated by `;` or `|` until one yields a non-empty string.
  EVIDENCE: https://retorque.re/zotero-better-bibtex/citing/ (fetched); example quoted: `auth.lower + shorttitle(3,3) + year` as the default pattern, and `(auth || shorttitle || year) ? (auth + title) : (year || title)`

- JabRef citation key patterns are bracket tokens with colon chained modifiers sitting inside otherwise free literal text: field markers like [auth], [year], [shorttitle], [authorsAlpha]; modifiers :lower, :upper, :capitalize, :titlecase, :sentencecase, :abbr, :truncateN (no parentheses, digits appended directly), :regex("pattern","replacement"), and :(fallback_text) for an explicit fallback when the field is empty.
  EVIDENCE: https://docs.jabref.org/setup/citationkeypatterns (fetched); example quoted: `[auth.etal:regex("\\.etal","EtAl"):regex("\\.","And")]`, and the default pattern `[auth][year]`

- Mendeley Desktop's File Organizer is drag and drop chips into a filename box (Author, Year, Title, Journal are the fields named in the guides), with a global separator dropdown (hyphen/underscore/comma/period) rather than per field modifiers, and automatic numbering rather than overwriting when two files would collide; this is confirmed only through university library research guides, since I found no surviving primary Elsevier/Mendeley documentation page for the discontinued Mendeley Desktop.
  EVIDENCE: https://researchguides.uoregon.edu/Mendeley/desktops/advanced (fetched, quoted: "Files shows the files in this library are formatted by Author - Year. pdf, i.e.: Gierdowski - 2019.pdf"); corroborated by search snippets from researchguides.uoregon.edu/Mendeley/desktop/tipsandtricks and sites.google.com/a/mendeley.com/mendeley-training (not independently fetched)


## Risks

- Double suffixing: if a pattern includes an explicit [counter] token, the batch driver must compute collisionIndex before calling render and then skip availableURL's own probe based -2/-3 suffix once the rendered name already differs from the collisionIndex:1 render, or a colliding file could get both a pattern counter and a filesystem suffix stacked on one name. This is new coordination between the render loop and availableURL that does not exist today and is easy to get wrong.

- clipped(_:to:) and the proposed maxTotalLength both count Swift Characters (grapheme clusters), not UTF-8 bytes; a title full of combining marks or emoji could exceed a filesystem's actual byte limit on a path component while reading as well under the character limit. This is an existing gap in clipped() today, inherited rather than introduced, but worth fixing if this work touches that function at all.

- 13 arrangeable tokens plus 6 modifiers is more surface than the current 9 toggles; a drag and drop chip UI has to make the six pdfX tokens feel optional/advanced (most PDFs have empty or junk metadata) rather than presenting 13 equally-weighted choices, or the picker becomes its own pile of options.

- The process(job:options:) integration requires constructing Item twice per file when pattern is set (once to feed render, once for the real return value); Item is small (URLs plus scalars plus a String dictionary) so this is unlikely to matter, but it is a real, measurable change to a function whose serial real-run path is deliberately not parallelized (Hammer.swift:1082-1084), worth a quick benchmark rather than an assumption.

- Mendeley's exact syntax (per field modifiers if any, exact separator list, exact numbering scheme on collision) is confirmed only through secondary university library guides, not primary Elsevier documentation, because Mendeley Desktop's own docs no longer appear to be live; treat Mendeley facts in this report as directionally right, not byte exact.

- The repo's git state changed twice during this session (git absent to present, then two more commits landing) while this was meant to be a read-only research pass; the design above reflects the latest read I took (HEAD 4d6aaea), but if it moves again before this design is acted on, Hammer.swift's line numbers and the current Options/Item shape should be re-verified before writing any code.


## Unverified (do not build on this without checking)

- Mendeley Desktop's exact File Organizer syntax beyond Author/Year/Title/Journal fields and a global separator dropdown (hyphen/underscore/comma/period): no live primary documentation page was found to fetch directly, only secondary library guides.

- The exact macOS/APFS filename length ceiling (commonly cited as 255 UTF-8 bytes per path component) was not verified against Apple's own documentation in this session; the design flags maxTotalLength as character based like today's maxLength rather than asserting a specific byte number.

- Whether day level date precision is wanted: findDate can match a day but normalizedName's FoundDate.prefix already discards it down to year-month today (Hammer.swift:47-49), and the proposed .date token deliberately mirrors that rather than extending precision, since extending it would require changing FoundDate/DateShape, which is out of this design's scope.

- Actual performance cost of building Item twice per file inside process(job:options:) when a pattern is set: reasoned about, not measured.

- Whether the eventual UI wants nested/grouped chips (e.g. a single 'Book' preset chip that expands into three sub-tokens) versus the flat token list this design assumes; the task asked for the model, not the UI, so this was intentionally left open.
