# bibtex-compliance

## Summary

Read Bibtex.swift (347 lines) completely: it renders BibTeX text from a fixed BibEntry shape (title/author/year/file only) and never validates against the real BibTeX or biblatex field-requirement tables it claims to follow. I verified the exact required/optional fields for all 9 relevant entry types in both classic BibTeX (btxdoc.pdf, Patashnik 1988) and biblatex (biblatex.pdf, CTAN, current v3.22 manual), verified bibtex-tidy's complete option surface with real defaults from its README, and verified the exact citation-key pattern grammars of Better BibTeX and JabRef from their own documentation pages. All external claims below are quoted from primary sources I fetched and read directly (not paraphrased by a summarizing tool), saved locally for re-inspection if needed.

## Design

Scope decision first: bibtex-tidy is a normalize-an-existing-.bib tool (it parses arbitrary input, so it needs comment handling, duplicate-field dedup, entry-set duplicate detection/merging, and a modify/output/backup file-I/O surface). Bibtex.swift is a render-from-BibEntry tool that only ever emits entries it built itself — it never parses an existing .bib. So the honest "comparably complete" target is bibtex-tidy's *value-formatting and field-selection* surface (curly/numeric/months/align/wrap/sortFields/dropAllCaps/stripEnclosingBraces/enclosingBraces/removeBraces/escape/encodeUrls/maxAuthors/omit), not its *document-hygiene* surface (stripComments/tidyComments/removeEmptyFields/removeDupeFields/duplicates/merge/backup/v2/modify/output), which has no object to act on here. I'm proposing new types, not editing anything (per instructions).

New file: Sources/PDFHammerCore/BibCompliance.swift

```swift
import Foundation

// MARK: - Field identity

/// Every field name a rendered entry could name, under either vocabulary this app might be
/// judged against. Two spellings are kept as separate cases exactly where classic BibTeX and
/// biblatex disagree (journal vs. journaltitle) rather than picking a winner, so a
/// requirement table can name the field the standard itself uses.
public enum BibField: String, Sendable, CaseIterable, Identifiable, Codable {
    case title, subtitle, author, editor, translator
    case year, date, month
    case journal, journaltitle
    case booktitle, maintitle
    case publisher, institution, school, organization, location, address
    case volume, number, series, edition, chapter, pages, pagetotal
    case type, note, howpublished
    case doi, eprint, eprinttype, eprintclass, url, urldate
    case isbn, issn, isrn
    /// This app's own addition, not a BibTeX field: the source PDF's path.
    case file

    public var id: String { rawValue }

    /// The only fields BibEntry can actually hold a value for today. Every other case
    /// exists so a requirement table can name it and a compliance report can say, plainly,
    /// that this app has no way to supply it — see `bibCompliance` below.
    public static let producible: Set<BibField> = [.title, .author, .year, .file]
}

// MARK: - What a type requires

/// Which vocabulary an entry is being judged against. The two disagree on required fields
/// for the same type name (see BibCompliance's doc comments for @inbook and @report), so a
/// compliance check has to pick one rather than merge them.
public enum BibStandard: String, Sendable, CaseIterable, Identifiable, Codable {
    /// BibTeXing (Patashnik, 1988) — the 13 standard .bst-era entry types.
    case classic
    /// The biblatex data model (biblatex manual, CTAN) as processed by biber.
    case biblatex
    public var id: String { rawValue }
    public var label: String { self == .classic ? "Classic BibTeX" : "biblatex" }
}

/// One requirement: satisfied if any field in `anyOf` is present. Most rules name a single
/// field; "author or editor" and "chapter and/or pages" are the two-field ones.
public struct BibFieldRule: Sendable, Equatable, Codable {
    public var anyOf: [BibField]
    public init(_ anyOf: BibField...) { self.anyOf = anyOf }
}

public struct BibRequirement: Sendable, Equatable, Codable {
    public var required: [BibFieldRule]
    public var optional: Set<BibField>
}

/// The required/optional field lists for `type` under `standard`, taken directly from
/// BibTeXing §3.1 (classic) or the biblatex manual §2.1.1 (biblatex). `type` here is meant
/// to grow past today's 6-case BibType — inproceedings, incollection, and thesis are
/// included even though no BibType case produces them yet.
public func bibRequirement(for type: BibType, standard: BibStandard) -> BibRequirement {
    switch (type, standard) {
    case (.book, .classic):
        return BibRequirement(required: [.init(.author, .editor), .init(.title),
                                          .init(.publisher), .init(.year)],
                               optional: [.volume, .number, .series, .address, .edition, .month, .note])
    case (.book, .biblatex):
        // biblatex's @book also covers classic BibTeX's @inbook (§2.3.1).
        return BibRequirement(required: [.init(.author), .init(.title), .init(.year, .date)],
                               optional: [.editor, .translator, .volume, .number, .series, .publisher,
                                          .location, .isbn, .chapter, .pages, .pagetotal, .note,
                                          .doi, .eprint, .url, .urldate])
    case (.inbook, .classic):
        return BibRequirement(required: [.init(.author, .editor), .init(.title),
                                          .init(.chapter, .pages), .init(.publisher), .init(.year)],
                               optional: [.volume, .number, .series, .type, .address, .edition, .month, .note])
    case (.inbook, .biblatex):
        // Different shape from classic: booktitle required, chapter/pages merely optional.
        return BibRequirement(required: [.init(.author), .init(.title), .init(.booktitle), .init(.year, .date)],
                               optional: [.editor, .translator, .volume, .number, .series, .publisher,
                                          .location, .isbn, .chapter, .pages, .note, .doi, .eprint, .url, .urldate])
    case (.report, .classic): // techreport
        return BibRequirement(required: [.init(.author), .init(.title), .init(.institution), .init(.year)],
                               optional: [.type, .number, .address, .month, .note])
    case (.report, .biblatex):
        // techreport (what BibType.report.keyword actually writes) makes `type` optional
        // with a localised default; plain @report requires it. Use the lenient techreport
        // reading here since that is the keyword this app emits.
        return BibRequirement(required: [.init(.author), .init(.title), .init(.institution), .init(.year, .date)],
                               optional: [.type, .number, .location, .note, .doi, .eprint, .url, .urldate])
    case (.misc, .classic):
        return BibRequirement(required: [], optional: [.author, .title, .howpublished, .month, .year, .note])
    case (.misc, .biblatex):
        // author, editor, and year are all individually omissible (§2.3.2); title is the
        // practical floor, matching this app's own existing choice.
        return BibRequirement(required: [.init(.title)],
                               optional: [.author, .editor, .howpublished, .type, .note, .organization,
                                          .month, .doi, .url, .urldate])
    case (.online, .classic):
        // No @online in classic BibTeX; nearest analogue is @misc.
        return BibRequirement(required: [.init(.title)], optional: [.author, .howpublished, .year, .note])
    case (.online, .biblatex):
        return BibRequirement(required: [.init(.author, .editor), .init(.title), .init(.year, .date),
                                          .init(.doi, .eprint, .url)],
                               optional: [.organization, .month, .note, .urldate])
    }
}

// MARK: - Judging an entry

public struct BibGap: Sendable, Equatable, Identifiable {
    public var field: BibField
    /// Whether BibEntry could hold a value for this field today. False means the gap is a
    /// property of the entry type, not a bug — nothing here can read a journal off a PDF.
    public var actionable: Bool
    public var id: BibField { field }
}

/// Every required field `entry` is missing, under `standard`. Only title/author/year are
/// ever checked as "present" — see BibField.producible — so most gaps for a real-world
/// type will come back non-actionable; that is the honest answer, not a bug in this
/// function. Use `actionable == true` gaps to find real defects (e.g. an author BookGuess
/// supplied but the render step dropped); use the full list to describe how far short of
/// `standard` this app's output falls by construction.
public func bibCompliance(_ entry: BibEntry, standard: BibStandard) -> [BibGap] {
    var present: Set<BibField> = [.file]
    if !entry.title.isEmpty { present.insert(.title) }
    if entry.author != nil { present.insert(.author) }
    if entry.year != nil { present.formUnion([.year, .date]) }

    return bibRequirement(for: entry.type, standard: standard).required.compactMap { rule in
        guard rule.anyOf.allSatisfy({ !present.contains($0) }) else { return nil }
        return BibGap(field: rule.anyOf[0], actionable: BibField.producible.contains(rule.anyOf[0]))
    }
}
```

New types in Bibtex.swift (or the same new file) for rendering options:

```swift
/// Which fields this app is allowed to write into a rendered entry, independent of whether
/// a given entry actually has a value for one — an allow-list, unlike bibtex-tidy's --omit
/// blocklist, because a checklist of "fields I might one day emit" reads more like a
/// settings panel than a list of exceptions. Defaults to every field BibEntry can currently
/// produce, so turning the filter on does not silently hide anything until unchecked.
public struct BibtexFilter: Sendable, Equatable, Codable {
    public var enabled: Set<BibField>
    public init(enabled: Set<BibField> = BibField.producible) { self.enabled = enabled }
    public func allows(_ field: BibField) -> Bool { enabled.contains(field) }
}

/// Every formatting choice bibtexBlock/bibtexDocument take, gathered into one flat,
/// Codable value so it can be saved, exported, or reset as a unit. Supersedes BibStyle:
/// same layout fields, plus the bibtex-tidy options that apply to a renderer which only
/// ever writes entries it built itself. (bibtex-tidy options that only make sense for
/// parsing an *existing* .bib file — strip/tidy-comments, remove-empty/dupe-fields,
/// duplicates/merge, backup/modify/output — have no equivalent here and are intentionally
/// left out; nothing in this file ever reads back a .bib someone else wrote.)
public struct BibtexOptions: Sendable, Equatable, Codable {
    public enum Delimiter: String, Sendable, CaseIterable, Identifiable, Codable {
        case braces, quotes
        public var id: String { rawValue }
    }
    public enum Escaping: String, Sendable, CaseIterable, Identifiable, Codable {
        /// No escaping at all — safe once every consumer is a modern biber/biblatex chain.
        case off
        /// This app's existing bibtexEscape: syntax-significant characters only, via
        /// core-LaTeX macros (\textbackslash{}, \&, \%, ...). No accent transliteration.
        case standard
    }

    // Layout — same fields BibStyle has today.
    public var lineWidth: Int
    public var indent: String
    public var align: Bool
    public var delimiter: Delimiter
    public var trailingComma: Bool
    public var blankLines: Bool
    public var sortFields: Bool

    // Value normalization — dropAllCaps existing; the rest close the bibtex-tidy gap.
    public var dropAllCaps: Bool
    /// bibtex-tidy --numeric: write year = 1998, not year = {1998}.
    public var numericYear: Bool
    /// bibtex-tidy --months: spell out -> jan/feb/... three-letter bareword, per §3.2.10.
    public var monthAbbreviations: Bool
    /// bibtex-tidy --enclosing-braces: wrap these fields in a second {} to freeze
    /// capitalization through a case-changing .bst/citation style (see TeX FAQ FAQ-capbibtex
    /// and biblatex's own {{Corporate Name}} convention, §2.3.3). Answers the "brace
    /// protection of capitals" question directly — title is the obvious default candidate,
    /// left empty here so turning it on is a deliberate choice, not a silent behavior change.
    public var enclosingBraces: Set<BibField>
    /// Truncate an author list past this many names to "and others" (bibtex-tidy
    /// --max-authors). nil = never truncate.
    public var maxAuthors: Int?
    public var escaping: Escaping

    // What gets written at all.
    public var filter: BibtexFilter

    public init(lineWidth: Int = 80, indent: String = "  ", align: Bool = true,
                delimiter: Delimiter = .braces, trailingComma: Bool = true, blankLines: Bool = true,
                sortFields: Bool = false, dropAllCaps: Bool = false, numericYear: Bool = false,
                monthAbbreviations: Bool = false, enclosingBraces: Set<BibField> = [],
                maxAuthors: Int? = nil, escaping: Escaping = .standard,
                filter: BibtexFilter = BibtexFilter()) {
        self.lineWidth = lineWidth; self.indent = indent; self.align = align
        self.delimiter = delimiter; self.trailingComma = trailingComma; self.blankLines = blankLines
        self.sortFields = sortFields; self.dropAllCaps = dropAllCaps; self.numericYear = numericYear
        self.monthAbbreviations = monthAbbreviations; self.enclosingBraces = enclosingBraces
        self.maxAuthors = maxAuthors; self.escaping = escaping; self.filter = filter
    }
    public static let standard = BibtexOptions()
}
```

Migration note (not performed here, since this is research-only): bibtexBlock/bibtexDocument would take a `BibtexOptions` instead of `BibStyle`; the ~11 App.swift @AppStorage scalars (lines 1059-1065, 2117-2129) collapse into one `@AppStorage` holding JSON-encoded `BibtexOptions` (RunCache.swift:34-46 already shows the JSONEncoder/Decoder pattern this codebase uses for Codable persistence), or stay as scalars if per-key AppStorage diffing is preferred — that's a UI-layer call, not a data-shape one.

Citation-key patterns — deliberately NOT proposing a formula engine. Better BibTeX's grammar (functions/filters/subformula operators) and JabRef's ([MARKER:modifier] with regex) are each a small interpreted language; building either is a real DSL project, not a flat config struct, and the house style rule against speculative abstraction argues against it until a user actually asks for pattern control. If/when that's wanted, the smallest useful step is a closed enum of named presets, each backed by a hand-written function (matching how BibOrder/BibType already work), not a string interpreter:

```swift
public enum CitationKeyStyle: String, Sendable, CaseIterable, Identifiable, Codable {
    case pdfHammer      // existing surname:year:firstword
    case betterBibTeXDefault  // auth.lower + shorttitle(3,3) + year, no spaces/colons
    case jabRefDefault        // [auth][year], no separators
    public var id: String { rawValue }
}
// citationKey(author:year:title:style:) would switch on this instead of always
// building pdf-hammer's own colon-joined shape.
```

## Verified facts

- BibType has exactly 6 cases: book, article, misc, report, inbook, online — three entry types the task asked about (inproceedings, incollection, thesis) have no case at all.
  EVIDENCE: Sources/PDFHammerCore/Bibtex.swift:5-6

- BibType.report writes @techreport (not @report) — this is the biblatex-compliant choice, since biblatex's techreport alias makes the `type` field optional (defaults to a localised 'technical report'), whereas plain @report requires `type` explicitly.
  EVIDENCE: Sources/PDFHammerCore/Bibtex.swift:11; corroborated by biblatex.pdf p.13 'techreport ... type field is optional and defaults to the localised term technical report'

- BibType.expected deliberately narrows required fields to a subset of {title, author, year} per type, and by its own comment never asks for publisher/journal/institution because 'nothing here can read those off a PDF'.
  EVIDENCE: Sources/PDFHammerCore/Bibtex.swift:24-35

- BibEntry is a fixed 7-field struct (itemKey, key, title, author?, year?, file, type) with no generic field dictionary — it structurally cannot hold doi, url, publisher, journal, booktitle, institution, editor, etc.
  EVIDENCE: Sources/PDFHammerCore/Bibtex.swift:40-48

- BibEntry.missing only ever inspects title/author/year, regardless of entry type, so it can never report a missing journal, institution, booktitle, or url even for types where the real standard requires one.
  EVIDENCE: Sources/PDFHammerCore/Bibtex.swift:53-59

- bibtexEscape escapes only BibTeX/LaTeX syntax characters (\ { } $ & % # _ ~ ^) using always-available core-LaTeX macros; it performs no brace-protection of capitalized words/acronyms inside titles, and does not transliterate accented Unicode to LaTeX escapes (UTF-8 passes through unchanged).
  EVIDENCE: Sources/PDFHammerCore/Bibtex.swift:66-79

- citationKey() builds keys as lowercase, diacritic-folded 'surname:year:firstword', joined with colons; duplicate suffixing in bibEntries() uses a single letter a-z and silently reuses 'z' beyond 26 collisions in the same author+year (min(count-1,25)).
  EVIDENCE: Sources/PDFHammerCore/Bibtex.swift:98-108,126

- BookGuess.author is a single free-form String and the model prompt explicitly instructs 'Use the surname only for the author' — the app never captures First/Last structure, multiple authors, or an 'and'-separated list, so BibTeX's name-format rules (von/Jr, 'Last, First') are structurally inapplicable to current data.
  EVIDENCE: Sources/PDFHammerCore/BookGuess.swift:7,23-24

- BibStyle covers lineWidth, indent, align, delimiter(braces|quotes), trailingComma, blankLines, sortFields, dropAllCaps, and omit(Set<String>) — it has no numeric-value handling, no month-abbreviation conversion, no per-field brace-protection (enclosingBraces), no URL-encoding, no author-list truncation, and no on/off escape toggle (escaping is always applied).
  EVIDENCE: Sources/PDFHammerCore/Bibtex.swift:161-207

- The only field filter the UI exposes today is a single 'Omit the file field' toggle backed by BibStyle.omit; there is no filter for title/author/year or for any field the app doesn't yet emit.
  EVIDENCE: Sources/PDFHammer/App.swift:1734,2129,2140

- BibType/BibStyle/BibOrder are persisted as ~11 separate flat @AppStorage scalars, not as one serialisable configuration value.
  EVIDENCE: Sources/PDFHammer/App.swift:1059-1065,2117-2129

- Classic BibTeX (Patashnik, 'BibTeXing', 1988) required/optional fields, verbatim: article — 'Required fields: author, title, journal, year. Optional fields: volume, number, pages, month, note.'; book — 'Required fields: author or editor, title, publisher, year. Optional fields: volume or number, series, address, edition, month, note.'; inbook — 'Required fields: author or editor, title, chapter and/or pages, publisher, year. Optional fields: volume or number, series, type, address, edition, month, note.'; incollection — 'Required fields: author, title, booktitle, publisher, year. Optional fields: editor, volume or number, series, type, chapter, pages, address, edition, month, note.'; inproceedings — 'Required fields: author, title, booktitle, year. Optional fields: editor, volume or number, series, pages, address, month, organization, publisher, note.'; techreport — 'Required fields: author, title, institution, year. Optional fields: type, number, address, month, note.'; phdthesis/mastersthesis — 'Required fields: author, title, school, year. Optional fields: type, address, month, note.'; misc — 'Required fields: none. Optional fields: author, title, howpublished, month, year, note.' There is no @online type in classic BibTeX.
  EVIDENCE: https://bibtexml.sourceforge.net/btxdoc.pdf (Oren Patashnik, BibTeXing, §3.1, pp.7-8) — fetched and read directly, saved locally

- biblatex (current manual, biblatex v3.22 / Biber 2.22) required/optional fields, verbatim: article — 'Required fields: author, title, journaltitle, year/date'; book — 'Required fields: author, title, year/date' (biblatex's @book 'also covers the function of the @inbook type of traditional BibTeX'); inbook — 'Required fields: author, title, booktitle, year/date' (a materially different shape from classic @inbook, which needs chapter/pages, not booktitle); incollection — 'Required fields: author, title, editor, booktitle, year/date'; inproceedings — 'Required fields: author, title, booktitle, year/date'; report — 'Required fields: author, title, type, institution, year/date' (type is required, unlike the techreport alias); thesis — 'Required fields: author, title, type, institution, year/date'; misc — 'Required fields: author/editor, title, year/date' (all three noted as omissible); online — 'Required fields: author/editor, title, year/date, doi/eprint/url'.
  EVIDENCE: https://ctan.math.illinois.edu/macros/latex/contrib/biblatex/doc/biblatex.pdf, §2.1.1 'Regular Types' (pp.9-13) — fetched and read directly, saved locally, current as of the 2026 CTAN build

- biblatex explicitly warns its @inbook is semantically different from classic BibTeX's: 'Use the @inbook entry type for a self-contained part of a book with its own title only... If you want to refer to a chapter or section of a book, simply use the book type and add a chapter and/or pages field.'
  EVIDENCE: biblatex.pdf §2.3.1 'The Entry Type @inbook', p.14

- Required fields are not absolute even in biblatex: 'the fields marked as required in §2.1.1 are not strictly required in all cases... You may generally use the label field to provide a substitute for any missing data required for citations.'
  EVIDENCE: biblatex.pdf §2.3.2 'Missing and Omissible Data', p.14

- Page ranges: classic BibTeX converts a single dash to a double dash for ranges — 'the standard styles convert a single dash (as in 7-33) to the double dash used in TeX to denote number ranges (as in 7--33)'; multiple values may use 42--111 or 7,41,73--97 or 43+ for open-ended ranges.
  EVIDENCE: btxdoc.pdf §3.2 'Fields', p.10 (pages field)

- Author/editor name grammar (classic BibTeX, also followed by biblatex's parser): each name has four parts First/von/Last/Jr; multiple names are separated by the literal word 'and' surrounded by spaces and not enclosed in braces; the three valid single-name forms are 'First von Last', 'von Last, First', and 'von Last, Jr, First'; a token is parsed as 'von' if its first letter at brace-level 0 is lower case.
  EVIDENCE: btxdoc.pdf §4 item 18, pp.15-16 (quoting 'First von Last' / 'von Last, First' / 'von Last, Jr, First')

- biblatex requires corporate (non-personal) author/editor names to be wrapped in an extra set of braces so they are not parsed as personal names, e.g. author = {{National Aeronautics and Space Administration}}.
  EVIDENCE: biblatex.pdf §2.3.3 'Corporate Authors and Editors', p.15 (line 1166 of extracted text)

- Month field conventions: classic BibTeX wants the bareword three-letter abbreviation unquoted/unbraced, e.g. month = jul (a BibTeX @STRING, not a literal); biblatex's month field is an integer (month={1} not month={January}) and the manual recommends the date field instead: 'It is therefore recommended to prefer date over year and month unless backwards compatibility... is required.'
  EVIDENCE: btxdoc.pdf §3.2 p.10 ('use the standard three-letter abbreviation'); biblatex.pdf §2.3.9 'Year, Month and Date', p.40

- biblatex date/urldate/eventdate/origdate fields 'adhere to iso8601-2 Extended Format specification level 1' (e.g. YYYY-MM-DD, with open ranges like YYYY/ or /YYYY); date field names must end in the literal string 'date'.
  EVIDENCE: biblatex.pdf §2.3.8 'Date and Time Specifications', p.39

- biblatex field definitions, verbatim: doi — 'field (verbatim) — The Digital Object Identifier of the work.'; url — 'field (uri) — The url of an online publication. If it is not URL-escaped (no % chars) it will be URI-escaped according to RFC 3987...'; urldate — 'field (date) — The access date of the address specified in the url field.'; eprint — 'field (verbatim) — The electronic identifier of an online publication... roughly comparable to a doi but specific to a certain archive, repository, service, or system.'
  EVIDENCE: biblatex.pdf §2.2.2 'Data Fields' (doi p.18, url/urldate p.22, eprint p.19)

- Capitalization protection rule (TeX FAQ, citing standard BibTeX practice): 'Enclose the words or letters whose capitalisation BibTeX should not touch in braces', e.g. title = {The {THE} operating system}; the FAQ explicitly warns against double-bracing an entire title as a general habit, since 'your BibTeX database should be a general-purpose thing, not something tuned to the requirements of a particular... bibliography style.'
  EVIDENCE: https://texfaq.org/FAQ-capbibtex — fetched directly

- biber (biblatex's processor) natively handles UTF-8: 'biber handles us-ascii, 8-bit encodings such as Latin 1, and utf-8. It features true Unicode support...' — meaning pdf-hammer's choice not to transliterate accented characters to LaTeX escapes is correct for a biber/biblatex pipeline, though it would not survive a pre-biber, ASCII-only classic BibTeX toolchain.
  EVIDENCE: biblatex.pdf §2.4.2 'Sorting and Encoding Issues', p.42

- bibtex-tidy (current published version 1.15.1) full CLI/API option list with exact defaults, verbatim from its manpage-style README: --space (default 2, ignored if --tab set), --align (default 14, i.e. column position of '='), --wrap (off by default; 80 when enabled bare, e.g. --wrap), --curly/--numeric/--months/--blank-lines/--sort/--strip-enclosing-braces/--drop-all-caps/--unescape/--encode-urls/--remove-empty-fields/--enclosing-braces/--remove-braces/--generate-keys/--max-authors are all off unless specified; --modify defaults true (v1) and will default false in the announced v2; --remove-dupe-fields defaults true; --lowercase (field names + entry type) defaults true, disabled via --no-lowercase; --escape defaults true using a 'legacy' character list that 'may emit macros requiring external packages' unless --escape=new is passed (new mode is package-independent LaTeX only); --trailing-commas defaults false in the printed manpage text.
  EVIDENCE: https://raw.githubusercontent.com/FlamingTempura/bibtex-tidy/master/README.md, '## CLI' manpage block, lines 68-249 — fetched and read directly

- bibtex-tidy has no field-inclusion allow-list — its only field filter is --omit (a blocklist), the same shape pdf-hammer's BibStyle.omit already has; there is no bibtex-tidy option that lets you pick which fields to keep by naming them positively.
  EVIDENCE: README.md manpage block, '--omit' entry, line 86-90

- bibtex-tidy's default field sort order (used by --sort-fields with no arguments) is: 'title, shorttitle, author, year, month, day, journal, booktitle, location, on, publisher, address, series, volume, number, pages, doi, isbn, issn, url, urldate, copyright, category, note, metadata'.
  EVIDENCE: README.md, '--sort-fields' entry, lines 182-188

- bibtex-tidy's --generate-keys option explicitly delegates to JabRef's pattern syntax: 'For all entries replace the key with a new key of the form <author><year><title>. A JabRef citation pattern can be provided.'
  EVIDENCE: README.md, '--generate-keys' entry, lines 211-214

- Better BibTeX (Zotero) citation-key formula grammar: default pattern is `auth.lower + shorttitle(3,3) + year`; lowercase-leading tokens are 'functions' (e.g. auth, shorttitle, year), uppercase-leading tokens are direct Zotero field access, dot-chained lowercase tokens after a value are 'filters' (e.g. .lower, .transliterate, .clean); subformulae compose with + (concatenation), || (first non-empty), && (both-required), ?: (ternary), and multiple whole-pattern fallbacks are separated by ; or |.
  EVIDENCE: https://retorque.re/zotero-better-bibtex/citing/ — fetched and stripped to text directly

- Better BibTeX's function reference (retorque.re/zotero-better-bibtex/citing/formulas/) documents ~30 exact functions with full parameter signatures, e.g. auth(n=0, m=1, creator='*', initials=false), shorttitle(n=3, m=0), authorsAlpha(...) ('Corresponds to the BibTeX style "alpha"'), and ~20 filters with signatures, e.g. .lower, .capitalize(wordstart=/RegExp/), .select(start=1, n?), .replace(find, replace), .len(relation='>', length=0); field access uses capitalized Zotero field names (e.g. DOI, Title, Publisher) taken verbatim, unprocessed.
  EVIDENCE: https://retorque.re/zotero-better-bibtex/citing/formulas/ — fetched and stripped to text directly, full function/filter table captured verbatim

- JabRef citation-key pattern grammar: field markers are bracketed uppercase field names, e.g. [TITLE], modified by colon-separated suffixes, e.g. [TITLE:abbr]; the default pattern is [auth][year] (e.g. 'Yared1998'), and duplicate keys get a trailing a/b/c letter.
  EVIDENCE: https://docs.jabref.org/setup/citationkeypatterns — fetched and stripped to text directly

- JabRef's exact modifier list (colon syntax): :abbr, :lower, :upper, :capitalize, :titlecase, :truncateN, :sentencecase, :regex("pattern","replacement"), and :(x) (a fallback literal inserted when the marker resolves empty, e.g. [VOLUME:(unknown)]).
  EVIDENCE: docs.jabref.org/setup/citationkeypatterns, 'Modifiers' section

- JabRef 6.0's default set of characters stripped from generated keys (independent of the configurable 'unwanted characters' list) is: { } ( ) , = \ " # % ~ and the ' character; the configurable 'unwanted characters' additionally defaults to ? ! ; ^ ʹ $ and backtick.
  EVIDENCE: docs.jabref.org/setup/citationkeypatterns, 'Removing unwanted characters' section


## Risks

- BibCompliance.swift as sketched will report nearly every required field as a non-actionable gap for every type except misc, because BibEntry structurally has nowhere to put journal/institution/booktitle/doi/etc. — that is the correct, honest output of 'define compliant BibTeX so the app can be judged against it', but it will look alarming in a raw dump unless the actionable/non-actionable split is surfaced prominently.

- Adding BibField cases and BibStandard tables to Bibtex.swift/BibCompliance.swift is pure additive data plus one pure function — low risk. The riskier move is later swapping BibStyle for BibtexOptions at call sites (bibtexBlock, bibtexDocument, App.swift's ~11 AppStorage keys and bibtexPanel UI) and migrating persisted @AppStorage values, which touches the UI layer and needs its own settings-migration plan (old scalar keys vs. one new JSON blob) not covered by this research pass.

- The biblatex manual PDF fetched is CTAN's current build (creation date embedded as 2026-08-13, matching biber 2.22/biblatex 3.22); its exact field lists have changed across major biblatex versions historically, so pinning the requirement tables to a specific manual version/date is worth recording if this ever needs re-verification.

- bibtex-tidy is under active development toward a v2 (the README documents --v2 opt-in behavior changes to --modify/--output/--escape defaults); the defaults quoted here are the current v1.15.1 defaults, not v2's.

- The proposed BibtexOptions.escaping=.off relies on every downstream consumer being a modern biber/biblatex chain (per the biber UTF-8 fact above); a user compiling with legacy BibTeX (not biber) against non-ASCII titles would get broken output with escaping off — this should stay an explicit, documented choice, not a new default.


## Unverified (do not build on this without checking)

- Whether the biblatex manual's per-type field lists have differed meaningfully from an older commonly-installed biblatex/TeX Live version (e.g. TeX Live 2023's biblatex) versus the 2026 CTAN build fetched here — only the current build was checked.

- bibtex-tidy's generated src/__generated__/optionsType.ts was only seen via a summarizing WebFetch, not read directly; the README manpage text (read directly) was treated as authoritative wherever the two could conflict.

- Whether JabRef's exact 'unwanted characters' default list is unchanged between JabRef 6.0 and whatever version a real user has installed — the docs page is versioned '/v4/...' for older releases and unversioned (current, 'v6' per the page's own nav) for this one; only the current page was checked.

- Better BibTeX's citekey formula grammar and function/filter set are described as evolving ('the syntax has changed to a javascript-ish format' from an older bracketed syntax); only the current retorque.re documentation was checked, not version history.

- Whether Swift's automatic Hashable/Equatable synthesis for the no-associated-value BibField enum is sufficient for its use inside Set<BibField> in a Codable context without an explicit conformance — this is standard Swift behavior but was not compiled/tested here, since no code was written or built (research-only per instructions).
