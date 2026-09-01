import Foundation
import PaperShelfCore

private struct HighlightScope {
    let key: String
    let label: String
}

private func profileScope(_ arguments: [String: Any]) throws -> HighlightScope {
    let kind = try requireString(arguments, "scope")
    switch kind {
    case "library":
        return HighlightScope(key: "library", label: "Whole library")
    case "document":
        let resolved = try resolveDocument(arguments)
        guard let path = resolved.path else {
            throw ToolFailure("a document scope needs 'path' or a document_id with a known path")
        }
        let key = "document:" + (resolved.id ?? URL(fileURLWithPath: path)
            .resolvingSymlinksInPath().path)
        return HighlightScope(key: key, label: URL(fileURLWithPath: path).lastPathComponent)
    case "folder":
        let folder = try requireString(arguments, "folder")
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder),
              isFolder.boolValue else { throw ToolFailure("no such folder: \(folder)") }
        let url = URL(fileURLWithPath: folder).resolvingSymlinksInPath()
        return HighlightScope(key: "folder:" + url.path, label: url.lastPathComponent)
    case "project":
        let reader = try openLibraryOrFail()
        let project = try resolveProject(try requireString(arguments, "project"), in: reader)
        return HighlightScope(key: "project:\(project.id)", label: project.name)
    default:
        throw ToolFailure("'scope' must be library, document, folder, or project")
    }
}

private func profileRow(_ profile: HighlightProfile, styleID: String,
                        scope: HighlightScope?) throws -> [String: Any] {
    guard let base = profile.styles.first(where: { $0.id == styleID }) else {
        throw ToolFailure("unknown style_id '\(styleID)'; call get_highlight_profile first")
    }
    var red = base.red
    var green = base.green
    var blue = base.blue
    var meaning = base.meaning
    if let scope,
       let override = profile.overrides[scope.key]?[styleID] {
        red = override.red ?? red
        green = override.green ?? green
        blue = override.blue ?? blue
        meaning = override.meaning ?? meaning
    }
    return ["id": base.id, "color": profileHex(red: red, green: green, blue: blue),
            "meaning": meaning]
}

private func profileHex(red: Double, green: Double, blue: Double) -> String {
    let channels = [red, green, blue].map { min(max(Int(($0 * 255).rounded()), 0), 255) }
    return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
}

private func profileRGB(_ value: Any?) throws -> (red: Double, green: Double, blue: Double)? {
    guard let raw = value as? String else {
        if value != nil { throw ToolFailure("'color' must be a six-digit hex value like #FFCC00") }
        return nil
    }
    let hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
    guard hex.count == 6, let number = Int(hex, radix: 16) else {
        throw ToolFailure("'color' must be a six-digit hex value like #FFCC00")
    }
    return (Double((number >> 16) & 0xFF) / 255,
            Double((number >> 8) & 0xFF) / 255,
            Double(number & 0xFF) / 255)
}

private func profileRows(_ profile: HighlightProfile, scope: HighlightScope?) throws -> [[String: Any]] {
    try profile.styles.map { try profileRow(profile, styleID: $0.id, scope: scope) }
}

let highlightTools: [Tool] = [
    Tool(
        name: "get_highlight_profile",
        title: "Read highlight colours and meanings",
        description: "Read the stable style ids, colours and semantic meanings used by "
            + "PaperShelf. Give a scope to see its effective values. Use the returned "
            + "style_id with set_highlight_profile when a paper, folder, project, or the "
            + "whole library needs a different vocabulary or colour.",
        inputSchema: [
            "type": "object",
            "properties": [
                "scope": ["type": "string", "enum": ["library", "document", "folder", "project"]],
                "document_id": ["type": "string"],
                "path": ["type": "string", "description": "Absolute path to a PDF"],
                "folder": ["type": "string", "description": "Absolute folder path"],
                "project": ["type": "string", "description": "A project name or id"],
            ],
        ],
        run: { arguments in
            let stored = readHighlightProfile() ?? .defaults
            let scope: HighlightScope?
            if arguments["scope"] == nil {
                scope = nil
            } else {
                scope = try profileScope(arguments)
            }
            let rows = try profileRows(stored, scope: scope)
            var structured: [String: Any] = ["styles": rows]
            if let scope { structured["scope"] = scope.key }
            let title = scope?.label ?? "Whole library"
            let text = rows.map { "\($0["id"] ?? "")  \($0["color"] ?? "")  \($0["meaning"] ?? "Highlight")" }
                .joined(separator: "\n")
            return ToolOutput(text: "\(title) highlight profile:\n" + text,
                              structured: structured)
        }
    ),

    Tool(
        name: "set_highlight_profile",
        title: "Change highlight colours and meanings",
        description: "Change one highlighter's colour, meaning, or both. scope is "
            + "library, document, folder, or project; document scopes use path or "
            + "document_id, folder scopes use folder, and project scopes use project. "
            + "A blank meaning inherits the library meaning for a non-library scope. "
            + "Set reset true to remove one scoped override. Call get_highlight_profile "
            + "first when you need the stable style_id. Changes are shared with the app "
            + "through its Application Support profile.",
        inputSchema: [
            "type": "object",
            "properties": [
                "scope": ["type": "string", "enum": ["library", "document", "folder", "project"]],
                "document_id": ["type": "string"],
                "path": ["type": "string", "description": "Absolute path to a PDF"],
                "folder": ["type": "string", "description": "Absolute folder path"],
                "project": ["type": "string", "description": "A project name or id"],
                "style_id": ["type": "string"],
                "color": ["type": "string", "description": "Six-digit hex, for example #FFCC00"],
                "meaning": ["type": "string", "description": "The semantic label; blank inherits for a scoped override"],
                "reset": ["type": "boolean", "description": "Remove this style's override at a non-library scope"],
            ],
            "required": ["scope", "style_id"],
        ],
        run: { arguments in
            let scope = try profileScope(arguments)
            let styleID = try requireString(arguments, "style_id")
            var stored = readHighlightProfile() ?? .defaults
            guard let index = stored.styles.firstIndex(where: { $0.id == styleID }) else {
                throw ToolFailure("unknown style_id '\(styleID)'; call get_highlight_profile first")
            }
            let reset = arguments["reset"] as? Bool ?? false
            guard !reset || scope.key != "library" else {
                throw ToolFailure("reset is only for a document, folder, or project scope")
            }
            guard reset || arguments["color"] != nil || arguments["meaning"] != nil else {
                throw ToolFailure("give 'color', 'meaning', or 'reset'")
            }

            if scope.key == "library" {
                if reset { throw ToolFailure("reset is only for a document, folder, or project scope") }
                if let rgb = try profileRGB(arguments["color"]) {
                    stored.styles[index].red = rgb.red
                    stored.styles[index].green = rgb.green
                    stored.styles[index].blue = rgb.blue
                }
                if let meaning = arguments["meaning"] as? String {
                    stored.styles[index].meaning = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else if reset {
                stored.overrides[scope.key]?[styleID] = nil
                if stored.overrides[scope.key]?.isEmpty == true { stored.overrides[scope.key] = nil }
            } else {
                var override = stored.overrides[scope.key]?[styleID] ?? HighlightProfileOverride()
                if let rgb = try profileRGB(arguments["color"]) {
                    override.red = rgb.red
                    override.green = rgb.green
                    override.blue = rgb.blue
                }
                if let meaning = arguments["meaning"] as? String {
                    let value = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
                    override.meaning = value.isEmpty ? nil : value
                }
                if override.isEmpty {
                    stored.overrides[scope.key]?[styleID] = nil
                    if stored.overrides[scope.key]?.isEmpty == true { stored.overrides[scope.key] = nil }
                } else {
                    stored.overrides[scope.key, default: [:]][styleID] = override
                }
            }
            try writeHighlightProfile(stored)
            let row = try profileRow(stored, styleID: styleID,
                                     scope: scope.key == "library" ? nil : scope)
            return ToolOutput(text: "Updated \(scope.label): \(row["color"] ?? "") "
                                + "means \(row["meaning"] ?? "Highlight").",
                              structured: ["scope": scope.key, "style": row, "reset": reset])
        }
    ),
]
