import Foundation

/// The portable palette shared by the app and the MCP process.
///
/// UserDefaults belongs to the process that reads it. This small JSON file lives in the
/// same Application Support folder instead, so a profile changed from ChatGPT is visible
/// to PaperShelf after its palette reloads.
public struct HighlightProfileStyle: Codable, Equatable, Sendable {
    public var id: String
    public var red: Double
    public var green: Double
    public var blue: Double
    public var meaning: String

    public init(id: String, red: Double, green: Double, blue: Double, meaning: String) {
        self.id = id
        self.red = red
        self.green = green
        self.blue = blue
        self.meaning = meaning
    }
}

/// The fields a document, folder, or project changes; missing fields inherit the library
/// palette. A scope with no remaining fields is removed rather than stored as dead data.
public struct HighlightProfileOverride: Codable, Equatable, Sendable {
    public var red: Double?
    public var green: Double?
    public var blue: Double?
    public var meaning: String?

    public init(red: Double? = nil, green: Double? = nil, blue: Double? = nil,
                meaning: String? = nil) {
        self.red = red
        self.green = green
        self.blue = blue
        self.meaning = meaning
    }

    public var isEmpty: Bool {
        red == nil && green == nil && blue == nil && meaning == nil
    }
}

public struct HighlightProfile: Codable, Equatable, Sendable {
    public var styles: [HighlightProfileStyle]
    public var overrides: [String: [String: HighlightProfileOverride]]

    public init(styles: [HighlightProfileStyle],
                overrides: [String: [String: HighlightProfileOverride]] = [:]) {
        self.styles = styles
        self.overrides = overrides
    }

    public static let defaults = HighlightProfile(styles: [
        HighlightProfileStyle(id: "00000000-0000-0000-0000-000000000001",
                              red: 1.00, green: 0.85, blue: 0.30,
                              meaning: "Worth remembering"),
        HighlightProfileStyle(id: "00000000-0000-0000-0000-000000000002",
                              red: 0.55, green: 0.87, blue: 0.55,
                              meaning: "Agree, or confirmed"),
        HighlightProfileStyle(id: "00000000-0000-0000-0000-000000000003",
                              red: 0.55, green: 0.78, blue: 1.00,
                              meaning: "Definition or key term"),
        HighlightProfileStyle(id: "00000000-0000-0000-0000-000000000004",
                              red: 1.00, green: 0.65, blue: 0.75,
                              meaning: "Disagree, or doubtful"),
        HighlightProfileStyle(id: "00000000-0000-0000-0000-000000000005",
                              red: 0.78, green: 0.66, blue: 1.00,
                              meaning: "Follow up"),
    ])
}

public func highlightProfileURL() -> URL? {
    if let overridden = ProcessInfo.processInfo.environment["PAPERSHELF_HIGHLIGHT_PROFILE_PATH"],
       !overridden.isEmpty {
        return URL(fileURLWithPath: overridden)
    }
    return supportDirectory()?.appendingPathComponent("highlight-profile.json")
}

public func readHighlightProfile() -> HighlightProfile? {
    guard let url = highlightProfileURL(),
          let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(HighlightProfile.self, from: data)
}

public func writeHighlightProfile(_ profile: HighlightProfile) throws {
    guard let url = highlightProfileURL() else {
        throw CocoaError(.fileNoSuchFile)
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(profile)
    try data.write(to: url, options: .atomic)
}
