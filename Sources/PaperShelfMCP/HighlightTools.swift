import AppKit
import Foundation
import PDFKit
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

/// The file a mark tool writes into, and the scope its style colours resolve in.
private func markTarget(_ arguments: [String: Any]) throws -> (url: URL, scope: HighlightScope) {
    let resolved = try resolveDocument(arguments)
    guard let path = resolved.path, resolved.exists else {
        throw ToolFailure("that document's file is not where the library last saw it; "
            + "call this again with its current 'path'")
    }
    let key = "document:" + (resolved.id ?? URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    return (URL(fileURLWithPath: path), HighlightScope(key: key, label: path))
}

/// `color` wins over `style_id`; neither gives nil, so an edit leaves the colour alone.
private func markColour(_ arguments: [String: Any], scope: HighlightScope) throws -> NSColor? {
    var rgb = try profileRGB(arguments["color"])
    if rgb == nil, let styleID = arguments["style_id"] as? String, !styleID.isEmpty {
        let row = try profileRow(readHighlightProfile() ?? .defaults, styleID: styleID, scope: scope)
        rgb = try profileRGB(row["color"])
    }
    return rgb.map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) }
}

/// What a mark's colour stands for in a document's scope, as the app's notes rail would say.
///
/// ponytail: the document and library scopes only; a folder or project override is not
/// consulted, so a mark coloured by one reads as the library names it.
func markMeaning(_ hex: String, scopeKey: String) -> String {
    guard let rgb = (try? profileRGB(hex)) ?? nil else { return unlabelledMarkMeaning }
    let profile = readHighlightProfile() ?? .defaults
    let limit = Prefs.labelForeignMarks ? 0.02 : 0.0002
    var best: (distance: Double, meaning: String)?
    for style in profile.styles {
        let override = profile.overrides[scopeKey]?[style.id]
        let distance = pow((override?.red ?? style.red) - rgb.red, 2)
            + pow((override?.green ?? style.green) - rgb.green, 2)
            + pow((override?.blue ?? style.blue) - rgb.blue, 2)
        if distance < (best?.distance ?? .infinity) {
            best = (distance, override?.meaning ?? style.meaning)
        }
    }
    guard let best, best.distance < limit else { return unlabelledMarkMeaning }
    return best.meaning.isEmpty ? "Highlight" : best.meaning
}

private func markOutput(_ verb: String, _ mark: PDFMark, scope: HighlightScope) -> ToolOutput {
    var text = "\(verb) \(mark.kind) \(mark.id) on page \(mark.page)"
    if !mark.quoted.isEmpty { text += ": \"\(mark.quoted)\"" }
    if !mark.note.isEmpty { text += "\n    note: \(mark.note)" }
    return ToolOutput(text: text, structured: ["mark": markRow(mark, scopeKey: scope.key)])
}

private let markDocumentProperties: [String: Any] = [
    "document_id": ["type": "string", "description": "A document id from a PaperShelf result."],
    "path": ["type": "string", "description": "Absolute path to a PDF."],
]

let highlightWriteTools: [Tool] = [
    Tool(
        name: "add_highlight",
        title: "Highlight a passage",
        description: "Highlight, underline or strike out a passage on one page, optionally "
            + "with a note, and write it into the PDF the way the reader's own marks are. "
            + "text is the passage as read_page or read_document gives it; case, spacing, "
            + "line breaks and hyphens do not need to match. Text that appears more than "
            + "once on the page is refused, so quote enough to name one place. Colour comes "
            + "from color (hex) or style_id (see get_highlight_profile); with neither, the "
            + "first style is used. The mark is signed with author, so the reader can tell "
            + "it from their own. Encrypted PDFs are refused. Returns the new mark's id.",
        inputSchema: [
            "type": "object",
            "properties": markDocumentProperties.merging([
                "page": ["type": "integer", "description": "One-based page number."],
                "text": ["type": "string", "description": "The passage to mark."],
                "kind": ["type": "string", "enum": ["highlight", "underline", "strikeout"]],
                "note": ["type": "string", "description": "Optional note attached to the mark."],
                "author": ["type": "string", "description": "Who the mark is from, e.g. Claude. Defaults to the connected client's name."],
                "style_id": ["type": "string"],
                "color": ["type": "string", "description": "Six-digit hex, for example #FFCC00"],
            ]) { first, _ in first },
            "required": ["page", "text"],
        ],
        run: { arguments in
            guard let page = arguments["page"] as? Int, page > 0 else {
                throw ToolFailure("'page' is required and starts at 1")
            }
            let text = try requireString(arguments, "text")
            let kind: PDFAnnotationSubtype
            switch arguments["kind"] as? String ?? "highlight" {
            case "highlight": kind = .highlight
            case "underline": kind = .underline
            case "strikeout": kind = .strikeOut
            default: throw ToolFailure("'kind' must be highlight, underline, or strikeout")
            }
            let target = try markTarget(arguments)
            var colour = try markColour(arguments, scope: target.scope)
            if colour == nil, let first = (readHighlightProfile() ?? .defaults).styles.first {
                colour = try markColour(["style_id": first.id], scope: target.scope)
            }
            let named = (arguments["author"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let author = !named.isEmpty ? named
                : connectedClient.isEmpty ? "Assistant" : connectedClient
            let mark = try addPDFMark(to: target.url, page: page, text: text, kind: kind,
                                      colour: colour ?? .systemYellow,
                                      note: arguments["note"] as? String ?? "", author: author)
            return markOutput("Added", mark, scope: target.scope)
        }
    ),

    Tool(
        name: "update_highlight",
        title: "Change a mark's note or colour",
        description: "Rewrite the note on a mark from list_highlights, recolour it, or "
            + "both, in the PDF itself. An empty note clears it. Colour comes from color "
            + "(hex) or style_id. The id stays the same.",
        inputSchema: [
            "type": "object",
            "properties": markDocumentProperties.merging([
                "id": ["type": "string", "description": "A mark id from list_highlights."],
                "note": ["type": "string"],
                "style_id": ["type": "string"],
                "color": ["type": "string", "description": "Six-digit hex, for example #FFCC00"],
            ]) { first, _ in first },
            "required": ["id"],
        ],
        run: { arguments in
            let id = try requireString(arguments, "id")
            let target = try markTarget(arguments)
            let colour = try markColour(arguments, scope: target.scope)
            let note = arguments["note"] as? String
            guard note != nil || colour != nil else {
                throw ToolFailure("give 'note', 'color', or 'style_id'")
            }
            return markOutput("Updated", try editPDFMark(in: target.url, id: id, note: note,
                                                         colour: colour), scope: target.scope)
        }
    ),

    Tool(
        name: "remove_highlight",
        title: "Remove a mark",
        description: "Remove one highlight, underline, strikeout or sticky note, with its "
            + "note, from the PDF. Takes an id from list_highlights. Returns what was removed, "
            + "so it can be put back with add_highlight.",
        inputSchema: [
            "type": "object",
            "properties": markDocumentProperties.merging([
                "id": ["type": "string", "description": "A mark id from list_highlights."],
            ]) { first, _ in first },
            "required": ["id"],
        ],
        run: { arguments in
            let id = try requireString(arguments, "id")
            let target = try markTarget(arguments)
            return markOutput("Removed", try removePDFMark(from: target.url, id: id),
                              scope: target.scope)
        }
    ),
]
