import SwiftUI
import Observation
import PaperShelfCore

enum PDFReadingAppearance: String, CaseIterable, Identifiable {
    case normal, tint, whiteOnBlack

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .tint: return "Dark tint"
        case .whiteOnBlack: return "White on black"
        }
    }
}

/// Everything the app remembers between launches, declared once.
///
/// It used to be declared once per view that read it: 145 `@AppStorage` properties across
/// ten files for 62 actual settings. `aiBaseURL` appeared six times, `aiModel` and
/// `aiUseEnvironment` five, twenty more keys three times each, and every one of those
/// copies wrote out the default value again by hand. Two things followed from that. A
/// default drifted -- change one and the other five still answer with the old value until
/// somebody happens to write the key -- and each declaration was a separate
/// `UserDefaults` observer, so a view holding thirty of them redrew whole when any
/// preference in the app changed, including thirty it never read.
///
/// `@Observable` rather than `ObservableObject` on purpose: a view that reads
/// `prefs.viewMode` is invalidated when `viewMode` changes and not when `bibIndent` does.
/// That is the whole point of putting them together, and it only works with per-property
/// tracking.
///
/// Values are held in memory and written through on set. Reading a preference is then a
/// property read rather than a trip through `UserDefaults`, which matters because some of
/// these are read inside a `GeometryReader` on every tick of a window resize.
@Observable
@MainActor
final class Prefs {
    /// One set of preferences, not one per window. The settings scene and the reader are
    /// separate scenes; the same object has to answer both, or a setting changed in one
    /// does not reach the other until the next launch.
    static let shared = Prefs()

    // MARK: - The window

    var viewMode: ViewMode = Store.choice("viewMode", .catalogue) {
        didSet { Store.put("viewMode", viewMode) }
    }
    var appearance: Appearance = Store.choice("appearance", .system) {
        didSet { Store.put("appearance", appearance) }
    }
    var sortOrder: ItemSort = Store.choice("sortOrder", .folder) {
        didSet { Store.put("sortOrder", sortOrder) }
    }
    var sortDescending: Bool = Store.flag("sortDescending", false) {
        didSet { Store.put("sortDescending", sortDescending) }
    }
    /// Hides everything already decided, so what is left is what is still asking for a
    /// decision.
    var onlyUndecided: Bool = Store.flag("onlyUndecided", false) {
        didSet { Store.put("onlyUndecided", onlyUndecided) }
    }
    var settingsPane: SettingsPane = Store.choice("settingsPane", .general) {
        didSet { Store.put("settingsPane", settingsPane) }
    }

    // MARK: - Panels

    /// How wide the document region is: the page and the inspector panel together.
    var documentRegionWidth: Double = Store.number("documentRegionWidth", 840) {
        didSet { Store.put("documentRegionWidth", documentRegionWidth) }
    }
    /// How wide the inspector is where there is no page beside it -- the shelf, the
    /// bibliography, the duplicates view.
    var inspectorPanelWidth: Double = Store.number("inspectorPanelWidth", 340) {
        didSet { Store.put("inspectorPanelWidth", inspectorPanelWidth) }
    }
    var inspectorCollapsed: Bool = Store.flag("inspectorCollapsed", false) {
        didSet { Store.put("inspectorCollapsed", inspectorCollapsed) }
    }
    var inspectorPanel: InspectorPanel = Store.choice("inspectorPanel", .details) {
        didSet { Store.put("inspectorPanel", inspectorPanel) }
    }
    var contentsShown: Bool = Store.flag("contentsShown", false) {
        didSet { Store.put("contentsShown", contentsShown) }
    }
    var contentsRailMode: ContentsRailMode = Store.choice("contentsRailMode", .outline) {
        didSet { Store.put("contentsRailMode", contentsRailMode) }
    }

    // MARK: - Reading

    var readingMode: Bool = Store.flag("readingMode", false) {
        didSet { Store.put("readingMode", readingMode) }
    }
    private static var defaultReadingAppearance: PDFReadingAppearance {
        // Migrate the old preference without writing a second key until the person
        // changes the new setting.
        Store.flag("readingTint", false) ? .tint : .normal
    }
    var readingAppearance: PDFReadingAppearance = Store.choice(
        "readingAppearance", Prefs.defaultReadingAppearance
    ) {
        didSet { Store.put("readingAppearance", readingAppearance) }
    }

    /// Compatibility for callers that only need the old on/off question.
    var readingTint: Bool {
        get { readingAppearance == .tint }
        set { readingAppearance = newValue ? .tint : .normal }
    }
    var pageFit: PageFit = Store.choice("pageFit", .width) {
        didSet { Store.put("pageFit", pageFit) }
    }
    var autoPreview: Bool = Store.flag("autoPreview", true) {
        didSet { Store.put("autoPreview", autoPreview) }
    }
    /// Whether a mark made in another app is named after the nearest colour here.
    ///
    /// A preference rather than always-on: a person who highlights in Preview with
    /// whatever colour it offered does not necessarily mean "definition" by blue, and a
    /// note that says so is worse than one that says "Highlight".
    var labelForeignMarks: Bool = Store.flag("labelForeignMarks", true) {
        didSet { Store.put("labelForeignMarks", labelForeignMarks) }
    }
    /// The highlighter last used, so the next mark is the same colour as the last one.
    var lastHighlightColour: String = Store.text("lastHighlightColour", "") {
        didSet { Store.put("lastHighlightColour", lastHighlightColour) }
    }
    /// Whether selecting text in the reader window pops the row of highlighters beside it.
    /// On by default: the keys are faster once you know them, and nothing says they exist.
    var selectionPalette: Bool = Store.flag("selectionPalette", true) {
        didSet { Store.put("selectionPalette", selectionPalette) }
    }

    // MARK: - Sources

    /// The folders the library is built from, one per line.
    var sources: String = Store.text("sources", "") {
        didSet { Store.put("sources", sources) }
    }
    var watchSources: Bool = Store.flag("watchSources", true) {
        didSet { Store.put("watchSources", watchSources) }
    }
    /// Passwords to try on a locked document, one per line.
    var passwords: String = Store.text("passwords", "") {
        didSet { Store.put("passwords", passwords) }
    }

    // MARK: - Renaming

    var namePattern: String = Store.text("namePattern", "") {
        didSet { Store.put("namePattern", namePattern) }
    }
    var namePatternMaxLength: Int = Store.count("namePatternMaxLength", 0) {
        didSet { Store.put("namePatternMaxLength", namePatternMaxLength) }
    }
    var returnAppliesRename: Bool = Store.flag("returnAppliesRename", true) {
        didSet { Store.put("returnAppliesRename", returnAppliesRename) }
    }
    var moveOriginals: Bool = Store.flag("moveOriginals", true) {
        didSet { Store.put("moveOriginals", moveOriginals) }
    }
    /// Whether the MCP server may move files. Off, because a model asking to tidy a folder
    /// is a different thing from a person deciding to.
    var mcpFileOperations: Bool = Store.flag("mcpFileOperations", false) {
        didSet { Store.put("mcpFileOperations", mcpFileOperations) }
    }
    var backupFolderName: String = Store.text("backupFolderName", defaultBackupFolderName) {
        didSet { Store.put("backupFolderName", backupFolderName) }
    }
    var backupCustomPath: String = Store.text("backupCustomPath", "") {
        didSet { Store.put("backupCustomPath", backupCustomPath) }
    }
    var useFolderNames: Bool = Store.flag("useFolderNames", true) {
        didSet { Store.put("useFolderNames", useFolderNames) }
    }
    var useMetadataDate: Bool = Store.flag("useMetadataDate", true) {
        didSet { Store.put("useMetadataDate", useMetadataDate) }
    }
    var useFileDate: Bool = Store.flag("useFileDate", false) {
        didSet { Store.put("useFileDate", useFileDate) }
    }
    var ruleCasing: NameRules.Casing = Store.choice("ruleCasing", .lowercase) {
        didSet { Store.put("ruleCasing", ruleCasing) }
    }
    var ruleSeparator: NameRules.Separator = Store.choice("ruleSeparator", .keep) {
        didSet { Store.put("ruleSeparator", ruleSeparator) }
    }
    var ruleDatePosition: NameRules.DatePosition = Store.choice("ruleDatePosition", .prefix) {
        didSet { Store.put("ruleDatePosition", ruleDatePosition) }
    }
    var ruleDateFormat: NameRules.DateFormat = Store.choice("ruleDateFormat", .dashed) {
        didSet { Store.put("ruleDateFormat", ruleDateFormat) }
    }
    var ruleStripDiacritics: Bool = Store.flag("ruleStripDiacritics", false) {
        didSet { Store.put("ruleStripDiacritics", ruleStripDiacritics) }
    }
    var ruleStripSymbols: Bool = Store.flag("ruleStripSymbols", false) {
        didSet { Store.put("ruleStripSymbols", ruleStripSymbols) }
    }
    var ruleAsciiOnly: Bool = Store.flag("ruleAsciiOnly", false) {
        didSet { Store.put("ruleAsciiOnly", ruleAsciiOnly) }
    }
    var ruleDropArticles: Bool = Store.flag("ruleDropArticles", false) {
        didSet { Store.put("ruleDropArticles", ruleDropArticles) }
    }
    var ruleMaxLength: Int = Store.count("ruleMaxLength", 0) {
        didSet { Store.put("ruleMaxLength", ruleMaxLength) }
    }
    var encryptOutput: Bool = Store.flag("encryptOutput", false) {
        didSet { Store.put("encryptOutput", encryptOutput) }
    }

    // MARK: - BibTeX

    var bibStandard: BibStandard = Store.choice("bibStandard", .biblatex) {
        didSet { Store.put("bibStandard", bibStandard) }
    }
    var bibType: BibType = Store.choice("bibType", .book) {
        didSet { Store.put("bibType", bibType) }
    }
    var bibOrder: BibOrder = Store.choice("bibOrder", .alphabetical) {
        didSet { Store.put("bibOrder", bibOrder) }
    }
    var bibDelimiter: BibStyle.Delimiter = Store.choice("bibDelimiter", .braces) {
        didSet { Store.put("bibDelimiter", bibDelimiter) }
    }
    var bibLineWidth: Int = Store.count("bibLineWidth", 80) {
        didSet { Store.put("bibLineWidth", bibLineWidth) }
    }
    var bibIndent: Int = Store.count("bibIndent", 2) {
        didSet { Store.put("bibIndent", bibIndent) }
    }
    var bibAlign: Bool = Store.flag("bibAlign", true) {
        didSet { Store.put("bibAlign", bibAlign) }
    }
    var bibWrapped: Bool = Store.flag("bibWrapped", true) {
        didSet { Store.put("bibWrapped", bibWrapped) }
    }
    var bibTrailingComma: Bool = Store.flag("bibTrailingComma", true) {
        didSet { Store.put("bibTrailingComma", bibTrailingComma) }
    }
    var bibBlankLines: Bool = Store.flag("bibBlankLines", true) {
        didSet { Store.put("bibBlankLines", bibBlankLines) }
    }
    var bibSortFields: Bool = Store.flag("bibSortFields", false) {
        didSet { Store.put("bibSortFields", bibSortFields) }
    }
    var bibDropAllCaps: Bool = Store.flag("bibDropAllCaps", false) {
        didSet { Store.put("bibDropAllCaps", bibDropAllCaps) }
    }
    var bibOmitFile: Bool = Store.flag("bibOmitFile", true) {
        didSet { Store.put("bibOmitFile", bibOmitFile) }
    }
    var bibShowsFile: Bool = Store.flag("bibShowsFile", false) {
        didSet { Store.put("bibShowsFile", bibShowsFile) }
    }
    var bibCompleteOnly: Bool = Store.flag("bibCompleteOnly", false) {
        didSet { Store.put("bibCompleteOnly", bibCompleteOnly) }
    }
    var bibValidOnly: Bool = Store.flag("bibValidOnly", false) {
        didSet { Store.put("bibValidOnly", bibValidOnly) }
    }

    // MARK: - The model, and what it is allowed to do

    var aiModel: String = Store.text("aiModel", "gpt-4o-mini") {
        didSet { Store.put("aiModel", aiModel) }
    }
    var aiBaseURL: String = Store.text("aiBaseURL", "https://api.openai.com/v1") {
        didSet { Store.put("aiBaseURL", aiBaseURL) }
    }
    var aiUseEnvironment: Bool = Store.flag("aiUseEnvironment", true) {
        didSet { Store.put("aiUseEnvironment", aiUseEnvironment) }
    }
    var autoIdentify: Bool = Store.flag("autoIdentify", false) {
        didSet { Store.put("autoIdentify", autoIdentify) }
    }
    var offerChatGPT: Bool = Store.flag("offerChatGPT", true) {
        didSet { Store.put("offerChatGPT", offerChatGPT) }
    }
    var offerChatGPTCopy: Bool = Store.flag("offerChatGPTCopy", true) {
        didSet { Store.put("offerChatGPTCopy", offerChatGPTCopy) }
    }

    // MARK: - Converting

    var defaultConverter: String = Store.text("defaultConverter", "") {
        didSet { Store.put("defaultConverter", defaultConverter) }
    }

    private init() {}
}

/// Reading and writing `UserDefaults`, spelled once per kind rather than once per key.
///
/// `object(forKey:)` rather than `bool(forKey:)` and friends: those return `false` and
/// `0` for a key that was never written, which is the wrong answer for every preference
/// here whose default is `true` or non-zero.
private enum Store {
    private static let defaults = UserDefaults.standard

    static func text(_ key: String, _ fallback: String) -> String {
        defaults.string(forKey: key) ?? fallback
    }
    static func flag(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }
    static func count(_ key: String, _ fallback: Int) -> Int {
        defaults.object(forKey: key) as? Int ?? fallback
    }
    static func number(_ key: String, _ fallback: Double) -> Double {
        defaults.object(forKey: key) as? Double ?? fallback
    }
    static func choice<T: RawRepresentable>(_ key: String, _ fallback: T) -> T
    where T.RawValue == String {
        defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }

    static func put(_ key: String, _ value: String) { defaults.set(value, forKey: key) }
    static func put(_ key: String, _ value: Bool) { defaults.set(value, forKey: key) }
    static func put(_ key: String, _ value: Int) { defaults.set(value, forKey: key) }
    static func put(_ key: String, _ value: Double) { defaults.set(value, forKey: key) }
    static func put<T: RawRepresentable>(_ key: String, _ value: T) where T.RawValue == String {
        defaults.set(value.rawValue, forKey: key)
    }
}
