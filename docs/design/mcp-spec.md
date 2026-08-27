# mcp-spec

## Summary

The current MCP spec revision is 2026-07-28, which removed the initialize handshake entirely in favor of a stateless per-request _meta model with a new server/discover RPC; both Claude Code (installed here at 2.1.241) and OpenAI Codex CLI (0.149.1) still default to the legacy initialize-based handshake for local stdio servers in practice, so a real server needs to speak both eras. No official Swift SDK supports 2026-07-28 yet (latest tag 0.12.1 targets 2025-11-25 and pulls in swift-nio/swift-log/swift-system/eventsource, breaking the zero-dependency rule), so the recommended path is a small hand-rolled JSON-RPC-over-stdio server in a new PDFHammerMCP executable target that calls straight into PDFHammerCore's existing pure functions. PDFHammerCore already has everything needed for search, Markdown conversion, and bibliography export; only a small new ReadingProject type (mirroring the existing RunCache pattern in Cache.swift) is needed for "reading projects."

## Design

ARCHITECTURE

New SwiftPM target, added to Package.swift alongside the existing two:
```swift
.executableTarget(
    name: "PDFHammerMCP",
    dependencies: ["PDFHammerCore"],
    swiftSettings: [.swiftLanguageMode(.v5)]
),
```
Foundation only, no new products, no external packages. `swift build -c release --show-bin-path` then emits `PDFHammerMCP` next to `PDFHammer`. Extend build.sh with one line, `cp "$(dirname "$BIN")/PDFHammerMCP" "$APP/Contents/MacOS/PDFHammerMCP"`, so the server binary ships embedded inside "PDF Hammer.app" and stays version-locked to the same PDFHammerCore build. Both Claude Code's and Codex's config point `command` at the absolute path `/Applications/PDF Hammer.app/Contents/MacOS/PDFHammerMCP` (or the dist/ path during development) -- no separate install step, no PATH entry.

Relation to the GUI: PDFHammerMCP is a second, independent process; it never talks to a running PDFHammer.app instance directly (no XPC, no socket). It reads the same three on-disk stores the app already uses:
1. Library roots -- `UserDefaults(suiteName: "com.jonaprieto.pdfhammer")?.string(forKey: "sources")`, split on "\n", filtered to existing paths -- exact same encoding as ContentView.swift:945/952. Works cross-process because the app is unsandboxed (confirmed: no entitlements), so this is a plain CFPreferences plist at ~/Library/Preferences/com.jonaprieto.pdfhammer.plist, not an App-Group-gated container.
2. Passwords -- `UserDefaults(suiteName: "com.jonaprieto.pdfhammer")?.string(forKey: "passwords")`, then `PasswordList.active(_:)` (already public in Hammer.swift) to get `[String]`. Never echoed back in any tool result.
3. Fresh scan results -- computed on demand via `collectJobs(roots:recursive:backup:)` + `process(jobs:options:)` (dryRun: true), the exact functions the GUI's Preview button calls. The MCP server deliberately does NOT try to reuse `RunCache`/`loadRunCache(matching:)`, because the "fingerprint" it is keyed on is a private hash computed in ContentView.swift that the server has no way to reconstruct; re-deriving Items live is simple, correct, and never stale.

PROTOCOL IMPLEMENTATION (hand-rolled, Foundation only)

Dual-era stdio server per the 2026-07-28 spec's own backward-compatibility design:
- A request whose `params._meta["io.modelcontextprotocol/protocolVersion"]` is present is served statelessly under 2026-07-28 semantics (wrap results in `{"resultType":"complete", ...}`, implement `server/discover` returning `{"supportedVersions":["2026-07-28","2025-11-25"], "capabilities": {...}}`).
- A request named `initialize` is served under legacy 2025-11-25 semantics (echo `protocolVersion`, return `capabilities`/`serverInfo`/`instructions`, accept the following `notifications/initialized` and thereafter answer plain `tools/list`/`tools/call`/etc. without requiring `_meta` on every call).
This is what the spec itself calls a "dual-era server," and it is the only design that works against both installed clients today: Claude Code 2.1.241 defaults to the legacy path for stdio unless `MCP_PROTOCOL_NEGOTIATION=auto` is set, and Codex CLI 0.149.1's protocol version is unverified so legacy-by-default must be assumed.

Pieces to write (rough sizing, Foundation-only):
- `RPCID` (Codable wrapper for JSON-RPC id, string|int): ~20 lines.
- stdio framing: a read loop on a background thread over `FileHandle.standardInput` accumulating bytes and splitting on `\n` (spec: newline-delimited, no embedded newlines), a serialized (NSLock-guarded) writer to `FileHandle.standardOutput` appending `\n` after each JSON-RPC message: ~60-80 lines.
- JSON-RPC envelope Codable types (Request/Notification/ResultResponse/ErrorResponse) plus encode/decode glue: ~60-80 lines.
- Method dispatch table `[String: (JSONObject) -> JSONObject]`: ~30 lines.
- Legacy `initialize`/`notifications/initialized` handler: ~20-30 lines.
- Modern `_meta` detection + `server/discover` + `UnsupportedProtocolVersionError` (-32022) construction: ~40 lines.
- Six protocol-message adapters (tools/list, tools/call, resources/list, resources/read, prompts/list, prompts/get) translating between the JSON-RPC shapes above and the 8 tool implementations below: ~120-150 lines.
- The 8 tool implementations themselves (thin wrappers over PDFHammerCore, described below): ~200-250 lines.
- Inline JSON Schema literals for the 8 tools' `inputSchema`: ~150-200 lines (schemas are verbose, not logic).
- New Core type `ReadingProject` (below): ~50-60 lines.
Total: roughly 700-900 lines of Swift for a working dual-era stdio server exposing all 8 tools. What must be implemented, concretely: JSON-RPC 2.0 message framing over stdio; the legacy initialize/initialized handshake; the modern per-request `_meta` path and `server/discover`; `tools/list` + `tools/call`; `resources/list` + `resources/read` (used only if a "read raw PDF bytes" resource is wanted -- optional, see Tool Surface); `prompts/list` + `prompts/get` (optional, only if prompt templates are wanted); and the 8 tool bodies.

NEW CORE CODE: Sources/PDFHammerCore/Project.swift (new file)
```swift
import Foundation

/// A named group of files kept for one line of reading, independent of where the files
/// live on disk. Membership is by `Item.key` (the resolved source path), the same
/// identity `Item` already uses, so a project survives a rename.
public struct ReadingProject: Identifiable, Sendable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var itemKeys: [String]
    public var note: String

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(),
                itemKeys: [String] = [], note: String = "") {
        self.id = id; self.name = name; self.createdAt = createdAt
        self.itemKeys = itemKeys; self.note = note
    }
}

/// Same convention as `runCacheURL` in Cache.swift: Application Support, not a preference.
public func projectsStoreURL(named name: String = "projects.json") -> URL? {
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask).first else { return nil }
    let folder = base.appendingPathComponent("PDF Hammer", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent(name)
}

public func loadProjects() -> [ReadingProject] {
    guard let url = projectsStoreURL(), let data = try? Data(contentsOf: url) else { return [] }
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([ReadingProject].self, from: data)) ?? []
}

public func saveProjects(_ projects: [ReadingProject]) {
    guard let url = projectsStoreURL() else { return }
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(projects) else { return }
    try? data.write(to: url, options: .atomic)
}
```
This is the only Core change required; every other tool below is a direct reuse of existing public functions.

TOOL SURFACE (8 tools; names use dot-namespacing, which the spec's own example `admin.tools.list` shows is valid)

1. `library.list_sources`
   inputSchema: `{"type":"object","properties":{},"additionalProperties":false}`
   Calls: UserDefaults "sources" read (see above).
   structuredContent: `{"sources":[{"path":"/Users/.../Papers","exists":true}]}`

2. `library.search`
   inputSchema:
   ```json
   {"type":"object","properties":{
     "query":{"type":"string","description":"Query.swift syntax: bare words match the name; field:value narrows (name, was, folder, text, status, size, pages, year); > and < compare, e.g. \"folder:bank size>10mb\""},
     "roots":{"type":"array","items":{"type":"string"},"description":"Absolute folder paths. Defaults to library.list_sources."},
     "recursive":{"type":"boolean","default":true},
     "limit":{"type":"integer","minimum":1,"maximum":500,"default":100}
   },"required":["query"],"additionalProperties":false}
   ```
   Calls: `collectJobs(roots:recursive:)` -> `process(jobs:options: Options(passwords:, recursive:, dryRun:true))` -> build `Searchable(item:text:)` per item (only reading `.text` when `PreparedQuery(Query(query)).terms` needs it, per `Query.needsText`) -> `matches(_:_:)`.
   structuredContent: `{"results":[{"name":str,"folder":str,"status":str,"year":str,"size":int,"pages":int,"path":str}],"truncated":bool}`

3. `document.read_markdown`
   inputSchema:
   ```json
   {"type":"object","properties":{
     "path":{"type":"string","description":"Absolute path to a PDF."},
     "converter":{"type":"string","enum":["auto","marker","docling","markitdown","pdftotext","built-in"],"default":"auto"},
     "page_markers":{"type":"boolean","default":true,"description":"Built-in converter only."},
     "max_chars":{"type":"integer","minimum":1000,"description":"Truncate output to this many characters."}
   },"required":["path"],"additionalProperties":false}
   ```
   Calls: if converter=="auto"/named external tool, `availableConverters()` (Convert.swift) -> `Process` (Foundation) run with `converter.arguments(input,tmpOutput)`, read result file. Else `markdownFromPDF(url:passwords:title:pageMarkers:)` in-process. `passwords:` from the UserDefaults "passwords" store via `PasswordList.active(_:)`.
   content: `[{"type":"text","text":"<markdown, truncated to max_chars if set>"}]`

4. `bibliography.list`
   inputSchema: `{"type":"object","properties":{"roots":{"type":"array","items":{"type":"string"}},"order":{"type":"string","enum":["alphabetical","folder"],"default":"alphabetical"},"include_incomplete":{"type":"boolean","default":true}},"additionalProperties":false}`
   Calls: `collectJobs`+`process(dryRun:true)` -> `bibEntries(for:known:)` -> `bibtexOrdered(entries:includeIncomplete:order:)`.
   structuredContent: `{"entries":[{"key":str,"title":str,"author":str?,"year":str?,"file":str,"type":str,"missing":[str]}]}` (BibEntry.missing already computed by Core)

5. `bibliography.export_bibtex`
   inputSchema: same roots/order/include_incomplete as (4), plus a `style` object matching `BibStyle` 1:1: `{"line_width":int,"indent":str,"align":bool,"delimiter":{"enum":["braces","quotes"]},"trailing_comma":bool,"blank_lines":bool,"sort_fields":bool,"drop_all_caps":bool,"omit":{"type":"array","items":{"type":"string"}}}`
   Calls: `bibtexDocument(entries:includeIncomplete:order:style:)`.
   content: `[{"type":"text","text":"<.bib file contents>"}]`

6. `projects.list`
   inputSchema: `{}`
   Calls: `loadProjects()`.
   structuredContent: `{"projects":[{"id":str,"name":str,"createdAt":str,"itemCount":int,"note":str}]}`

7. `projects.create`
   inputSchema: `{"type":"object","properties":{"name":{"type":"string","minLength":1},"paths":{"type":"array","items":{"type":"string"},"description":"Absolute PDF paths to seed the project with."},"note":{"type":"string"}},"required":["name"],"additionalProperties":false}`
   Calls: build `ReadingProject`, `itemKeys` = `paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }` (matches `Item.key`), append to `loadProjects()`, `saveProjects(...)`.
   structuredContent: the created `{"id":str,"name":str,"itemCount":int}`

8. `renames.propose`
   inputSchema:
   ```json
   {"type":"object","properties":{
     "roots":{"type":"array","items":{"type":"string"}},
     "recursive":{"type":"boolean","default":true},
     "rules":{"type":"object","properties":{
       "casing":{"type":"string","enum":["lowercase","uppercase","unchanged"],"default":"lowercase"},
       "separator":{"type":"string","enum":["keep","dash","underscore"],"default":"keep"},
       "strip_symbols":{"type":"boolean","default":false},
       "strip_diacritics":{"type":"boolean","default":false},
       "ascii_only":{"type":"boolean","default":false},
       "drop_leading_articles":{"type":"boolean","default":false},
       "max_length":{"type":"integer","default":0},
       "date_position":{"type":"string","enum":["prefix","suffix"],"default":"prefix"},
       "date_format":{"type":"string","enum":["dashed","compact"],"default":"dashed"}
     }},
     "use_folder_names":{"type":"boolean","default":true},
     "use_metadata_date":{"type":"boolean","default":false},
     "use_file_date":{"type":"boolean","default":false}
   },"required":["roots"],"additionalProperties":false}
   ```
   Enum raw values above are exact `NameRules` cases (Hammer.swift:62-83).
   Calls: `collectJobs`->`process(jobs:options: Options(..., dryRun:true, rules: NameRules(...)))`. Result `Item.destination`/`.isRenamed` is the proposal; nothing is written to disk (dryRun branches in `process`/`moveFile`/`moveToTrash` never touch the filesystem).
   structuredContent: `{"proposals":[{"path":str,"proposed_name":str,"status":str,"message":str}]}`
   Deliberately no `renames.apply` tool in this design -- see Risks.

CLIENT REGISTRATION

Claude Code -- project-scoped, `.mcp.json` at the repo/project root:
```json
{
  "mcpServers": {
    "pdfhammer": {
      "type": "stdio",
      "command": "/Applications/PDF Hammer.app/Contents/MacOS/PDFHammerMCP",
      "args": []
    }
  }
}
```
or via CLI: `claude mcp add --transport stdio pdfhammer -- "/Applications/PDF Hammer.app/Contents/MacOS/PDFHammerMCP"`.

Codex CLI -- `~/.codex/config.toml` (or project `.codex/config.toml`):
```toml
[mcp_servers.pdfhammer]
command = "/Applications/PDF Hammer.app/Contents/MacOS/PDFHammerMCP"
args = []
startup_timeout_sec = 10
```
or via CLI: `codex mcp add pdfhammer -- "/Applications/PDF Hammer.app/Contents/MacOS/PDFHammerMCP"`.

## Verified facts

- Current MCP specification revision is 2026-07-28; prior dated revisions in order are 2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25.
  EVIDENCE: github.com/modelcontextprotocol/modelcontextprotocol tree/main/schema directory listing: "2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25, 2026-07-28, draft"; modelcontextprotocol.io/specification links to /specification/2026-07-28/* and cites schema/2026-07-28/schema.ts as source of truth.

- 2026-07-28 removed the initialize/notifications-initialized handshake and made the protocol stateless: every request now carries protocolVersion and clientCapabilities in _meta.
  EVIDENCE: modelcontextprotocol.io/specification/2026-07-28/changelog: "Make MCP stateless: remove the initialize/notifications/initialized handshake... Every request now carries its protocol version and client capabilities in _meta (io.modelcontextprotocol/protocolVersion, io.modelcontextprotocol/clientCapabilities)."

- server/discover is the new mandatory RPC servers must implement to advertise supportedVersions/capabilities/identity; it is optional for clients to call.
  EVIDENCE: modelcontextprotocol.io/specification/2026-07-28/server/discover: exact request/response JSON with "supportedVersions": ["2026-07-28"], "capabilities", "_meta['io.modelcontextprotocol/serverInfo']", "instructions".

- Exact per-request _meta fields and requiredness under 2026-07-28.
  EVIDENCE: modelcontextprotocol.io/specification/2026-07-28/basic (index): table listing io.modelcontextprotocol/protocolVersion (string, Required), clientInfo (Implementation, optional), clientCapabilities (ClientCapabilities, Required), logLevel (optional); missing required field -> JSON-RPC -32602.

- Exact JSON-RPC shapes for tools/list, tools/call, resources/list, resources/read, prompts/list, prompts/get under 2026-07-28, including the new required resultType field ("complete" | "input_required").
  EVIDENCE: Verbatim JSON code blocks fetched from modelcontextprotocol.io/specification/2026-07-28/server/tools, /server/resources, /server/prompts, cross-checked against raw schema.ts interfaces CallToolRequest/CallToolResult/ListToolsResult/ListResourcesResult/ReadResourceResult/ListPromptsResult at raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/schema/2026-07-28/schema.ts.

- stdio remains the standard local transport (newline-delimited JSON-RPC); the HTTP transport is named "Streamable HTTP"; the older HTTP+SSE transport is now fully Deprecated.
  EVIDENCE: modelcontextprotocol.io/specification/2026-07-28/basic/transports lists "1. stdio... 2. Streamable HTTP" as the two standard bindings; changelog: "Reclassify the HTTP+SSE transport (deprecated since protocol version 2025-03-26) as Deprecated under the feature lifecycle policy."

- The spec defines explicit backward compatibility: a dual-era client probes stdio servers with server/discover and falls back to the legacy initialize handshake on any non-modern error/timeout; a dual-era server answers per-request _meta requests statelessly under 2026-07-28 and answers an initialize request under the negotiated legacy revision.
  EVIDENCE: modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio#backward-compatibility and /basic/versioning "Compatibility Matrix" table, quoted in full during research.

- The legacy (pre-2026-07-28) initialize/initialized handshake JSON shape, including protocolVersion negotiation and capabilities.
  EVIDENCE: modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle: verbatim "initialize" request/response JSON and "notifications/initialized" JSON.

- Claude Code CLI installed locally is version 2.1.241; Codex CLI installed locally is codex-cli 0.149.1.
  EVIDENCE: `claude --version` -> "2.1.241 (Claude Code)"; `codex --version` -> "codex-cli 0.149.1" (run via Bash on this machine).

- Claude Code registers a local stdio MCP server via `claude mcp add [options] <name> -- <command> [args...]` (with `--transport stdio`, `-e KEY=value`, `--scope local|project|user`); config lives in project `.mcp.json` (key `mcpServers`, each entry `{"type":"stdio","command":...,"args":[...],"env":{...}}`) or in `~/.claude.json` for user/local scope.
  EVIDENCE: code.claude.com/docs/en/mcp (fetched); confirmed the redirect target (docs.claude.com/en/docs/claude-code/mcp -> 301 -> code.claude.com/docs/en/mcp) and quoted CLI/JSON shapes from that page.

- Claude Code's newer "v2 runtime" (reported to apply from v2.1.232+, below the locally installed 2.1.241) can speak MCP protocol revision 2026-07-28, but for stdio servers it only attempts that negotiation when `MCP_PROTOCOL_NEGOTIATION=auto` is set; by default it uses the legacy initialize handshake against a local stdio server.
  EVIDENCE: code.claude.com/docs/en/mcp fetch summary; partially corroborated by github.com/anthropics/claude-code issue #17169 (closed "not planned", filed against Claude Code v2.1.2, reporting the client only spoke protocol 2024-11-05 as of Jan 2026) -- the specific env-var names and version threshold come from a single fetch and were not cross-checked against a second source (see Unverified).

- Codex CLI stores MCP config in TOML: `~/.codex/config.toml` (global) or `.codex/config.toml` (project, trusted projects only); a stdio entry is `[mcp_servers.<name>]` with `command`, `args`, `startup_timeout_sec`, `tool_timeout_sec`, `enabled`, and env vars under a nested `[mcp_servers.<name>.env]` table; an HTTP entry uses `url` and `bearer_token_env_var`. CLI: `codex mcp add <name> --env VAR=VAL -- <command> [args...]`, `codex mcp list`.
  EVIDENCE: learn.chatgpt.com/docs/extend/mcp?surface=cli (fetched, following the redirect from developers.openai.com/codex/mcp).

- An official Swift SDK exists at github.com/modelcontextprotocol/swift-sdk (package URL `https://github.com/modelcontextprotocol/swift-sdk.git`), latest release 0.12.1 published 2026-05-07; minimum platforms macOS 13.0+/iOS+Mac Catalyst 16.0+/watchOS 9.0+/tvOS 16.0+/visionOS 1.0+, Swift 6.0+ toolchain; its README states it implements the 2025-11-25 (legacy, initialize-handshake) revision, not 2026-07-28.
  EVIDENCE: `gh api repos/modelcontextprotocol/swift-sdk/releases` (read-only) -> newest tag "0.12.1" published_at "2026-05-07T08:37:25Z"; raw.githubusercontent.com/modelcontextprotocol/swift-sdk/main/Package.swift for platforms; raw.githubusercontent.com/.../main/README.md: "This Swift SDK implements both client and server components according to the 2025-11-25 (latest) version of the MCP specification."

- swift-sdk's own Package.swift declares dependencies on swift-system, swift-log, eventsource, and swift-nio -- real third-party dependencies that would break PDF Hammer's stated zero-dependency property.
  EVIDENCE: raw.githubusercontent.com/modelcontextprotocol/swift-sdk/main/Package.swift fetch, "Dependencies" section listing all four packages.

- PDF Hammer's README explicitly states no third-party dependencies.
  EVIDENCE: README.md:6 "Built on PDFKit and SwiftUI. No third-party dependencies."

- PDFHammerCore already exposes pure, reusable building blocks for the proposed tools: search (Query/Searchable/matches/PreparedQuery), bibliography (bibEntries/BibEntry/bibtexDocument/BibStyle/markdownBibliography), Markdown conversion (markdownFromPDF, MarkdownConverter, availableConverters, locate), file discovery and rename proposal (collectJobs, process(jobs:options:), restyled, NameRules, Options, Item, PasswordList).
  EVIDENCE: Sources/PDFHammerCore/Search.swift:13-179 (Query, Searchable, matches); Sources/PDFHammerCore/Bibtex.swift:35-125,150-347 (BibType, BibEntry, bibEntries, bibtexDocument); Sources/PDFHammerCore/Markdown.swift:31-123 (markdownBibliography, markdownCatalogue, markdownNotes); Sources/PDFHammerCore/Convert.swift:1-117 (MarkdownConverter, availableConverters, markdownFromPDF); Sources/PDFHammerCore/Hammer.swift:61-231 (NameRules), 334-397 (restyled), 495-620 (Status/Item/Options/BackupSettings), 659-746 (collectJobs), 1093-1321 (process/moveFile/moveToTrash).

- No "reading project"/collection concept exists anywhere in the repo today.
  EVIDENCE: `grep -rn "project\|Project" Sources/PDFHammerCore/*.swift` returned no matches; Sources/PDFHammer/Reading.swift (349 lines) is about in-document highlights/notes/table-of-contents, not project grouping (read in full).

- The GUI app is unsandboxed (ad-hoc signed, no entitlements file), bundle id com.jonaprieto.pdfhammer.
  EVIDENCE: Resources/Info.plist:11 `<key>CFBundleIdentifier</key><string>com.jonaprieto.pdfhammer</string>`; `find ... -iname "*.entitlements"` returned nothing; build.sh:22 `codesign --force --sign -` (ad-hoc, no entitlements passed).

- The GUI persists selected library root folders in UserDefaults key "sources" as newline-joined absolute paths, and passwords in UserDefaults key "passwords" in cleartext.
  EVIDENCE: Sources/PDFHammer/ContentView.swift:9 `@AppStorage("passwords") private var passwordsText = ""`; line 34 `@AppStorage("sources") private var storedSources = ""`; line 945 `storedSources = selection.map(\.path).joined(separator: "\n")`; line 952 `let paths = storedSources.split(separator: "\n").map(String.init)`.

- The GUI's last-scan snapshot is cached on disk at ~/Library/Application Support/PDF Hammer/last-run.json, via public Core functions runCacheURL/saveRunCache/loadRunCache, keyed by an app-computed "fingerprint" string.
  EVIDENCE: Sources/PDFHammerCore/Cache.swift (full file): `runCacheURL(named:)` uses `.applicationSupportDirectory` + "PDF Hammer" + filename "last-run.json"; `RunCache` struct has fingerprint/savedAt/items; Sources/PDFHammer/ContentView.swift:143 `private var fingerprint: String { [selection.map(\.path).joined(separator: "|"), ...`.


## Risks

- 2026-07-28 is very new (published roughly a month before this research); building strictly to it without the legacy fallback would make the server unusable against both clients as installed today (Claude Code 2.1.241 defaults to legacy stdio initialize unless MCP_PROTOCOL_NEGOTIATION=auto; Codex 0.149.1's version is unverified). The dual-era design above is required, not optional.

- No Swift SDK covers the 2026-07-28 model yet, and the one that exists (0.12.1, targets 2025-11-25) would pull in swift-nio/swift-log/swift-system/eventsource, directly violating README.md:6's "No third-party dependencies." Hand-rolling is the only option that preserves that property.

- Passwords are stored in cleartext UserDefaults (key "passwords") by the existing GUI, not something introduced here. The MCP server must read that value to open encrypted PDFs but must never place it in any tool's content/structuredContent -- any MCP client with access to this server can cause encrypted PDFs to be opened using the user's stored passwords, which is worth surfacing to the user as an accepted tradeoff of the existing app design, not a new one.

- library.search, bibliography.list, and renames.propose all go through process(jobs:options:dryRun:true), which opens and reads every candidate PDF (same cost as the GUI's Preview) on every single tool call, with no cross-call cache -- an agent issuing several searches in one conversation re-scans the whole library each time. Acceptable as a first, always-correct version; a follow-up cache keyed by (roots, per-file mtime) rather than the GUI's private fingerprint would help large libraries.

- No renames.apply/projects.add_items/write-side tools were designed here. renames.propose never touches disk; an "apply" tool would need its own confirmation contract (which files, is a GUI instance possibly running against the same paths concurrently, does it honor BackupSettings) that is a distinct decision the user should make explicitly rather than getting bundled in silently.

- Cross-process UserDefaults(suiteName:) read from a plain, non-App-Group executable was reasoned from the absence of a sandbox entitlement, not empirically run on this machine; it should be smoke-tested (launch PDFHammerMCP standalone, confirm it sees the same "sources"/"passwords" values the GUI shows) before being relied on.

- Two incompatible client config formats (Claude Code JSON vs Codex TOML) must be hand-maintained; a small pdfhammer-mcp install helper that prints or writes both blocks (never touching secrets) would reduce setup error, but is a separate piece of work from the server itself.


## Unverified (do not build on this without checking)

- Which MCP protocol version Codex CLI 0.149.1's client actually negotiates -- the fetched Codex docs page explicitly did not state a protocol version, and no openai/codex changelog or source was checked.

- The precise "v2.1.232+", MCP_SDK_GENERATION, and MCP_PROTOCOL_NEGOTIATION=auto details for Claude Code's runtime selection came from a single WebFetch summarization of code.claude.com/docs/en/mcp; only the coarse claim (Claude Code v2.1.2 spoke 2024-11-05 as of Jan 2026, closed "not planned") was independently corroborated via the GitHub issue. The exact env var names/version threshold should be re-confirmed against Claude Code's own source or a second doc pass before being hardcoded into user-facing setup instructions.

- Whether Codex's TOML really supports both a top-level env_vars = [...] array (inherit-from-environment) and a separate [mcp_servers.<name>.env] table simultaneously, or whether the fetch conflated two different examples from the page -- not checked against raw page markup.

- Full exact composition of the GUI's private "fingerprint" string beyond its first component (selection.map(\.path).joined(separator:"|"), ContentView.swift:143-144) -- irrelevant to this design since the MCP server deliberately avoids depending on it, but noted as not fully read.

- Whether swift-sdk has any newer unreleased branch/PR already targeting 2026-07-28 -- only published tags (up to 0.12.1, predating the 2026-07-28 spec date) were checked via the GitHub Releases API; open PRs/branches were not searched.
