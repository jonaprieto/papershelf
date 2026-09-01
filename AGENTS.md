# Working in this repository

PaperShelf reads, renames, files and searches a library of PDFs on a Mac, and ships an MCP
server so an assistant can search and cite those PDFs without the files leaving the machine.

The human build and release contract lives in [HACKING.md](HACKING.md); keep both documents
aligned when the package or its distribution changes.

## Layout

Three SwiftPM targets, no third-party dependencies. That is a property worth keeping: the
README states it, and adding a package would make it false.

- `Sources/PaperShelfCore` is a pure library. PDF reading, renaming rules, BibTeX, search,
  duplicates, and the SQLite library. No UI.
- `Sources/PaperShelf` is the SwiftUI app.
- `Sources/PaperShelfMCP` is a hand-rolled JSON-RPC-over-stdio MCP server, built as its own
  executable and copied into the app bundle by `build.sh` as `papershelf-mcp`.

## Commands

```
swift build                  # must be clean, zero warnings
swift test                   # XCTest, covers Core and the app
Tools/mcp-check.sh           # drives the MCP server over stdio, must report zero FAIL
./build.sh                   # builds dist/PaperShelf.app, ad-hoc signed
./build.sh --install         # also copies it to /Applications
```

`swift test --filter X` still builds every target first. SwiftPM plans the whole graph
before a filter selects anything, so a broken app target means no test in the package runs,
including Core's.

## Release checklist

- Release directly from `main`, using the next semantic version. Keep
  `paperShelfVersion`, `Resources/Info.plist`'s short version and build number, and
  `Plugin/papershelf/.codex-plugin/plugin.json` aligned with the new `CHANGELOG.md` entry.
- Run `swift build`, `swift test`, `Tools/mcp-check.sh`, and `./build.sh` before committing.
  Inspect the built app's version and bundled changelog before installing it.
- Make a signed Conventional Commit, then create a signed annotated tag such as
  `git tag -s v1.8.0 -m "Release v1.8.0"` and push both with `git push origin main v1.8.0`.
  The tag starts the GitHub release workflow in `.github/workflows/release.yml`.
- Install the checked build with `./build.sh --install`. If the local ChatGPT plugin is in
  use, refresh it with `./Tools/install-chatgpt-plugin.sh` so its manifest points at the
  installed MCP binary and current release.

## Conventions

- No emoji and no em-dashes anywhere: source, comments, Markdown written into the repo, and
  commit messages. Use a comma, a colon, a semicolon, or two sentences instead.
- Commit messages are a Conventional Commits prefix and then a plain descriptive clause,
  written for a person: `feat: the marks on a paper show without opening it`. No
  AI-attribution trailers of any kind.
- Every commit is signed, and every commit builds and passes on its own. Check with
  `git log --format='%H %G?'`, which must show `G` or `Y`.
- Comments explain consequences, not mechanics. The existing files are the reference for
  voice; match them rather than introducing a new register.

## Invariants that are easy to break

**Nothing but JSON-RPC may reach stdout from the MCP server.** Diagnostics go through
`note(_:)`, which writes to stderr. A stray `print` corrupts the stream for every client.
The one exception is `--version`, which prints and exits before the server is constructed.

**A user-fixable problem is an `isError` result with a plain sentence, never a JSON-RPC
protocol error.** The distinction is whether the caller can fix it by calling again with
different arguments.

**Clamp every limit at the tool layer with `max(0, ...)`.** `LibraryReader`'s parameters are
deliberately unclamped, and SQLite reads a negative LIMIT as *unlimited* rather than zero, so
an unclamped value turns a bounded query into a full dump of a private library.

**`extracted_text.format` must tell the truth about its row.** `"markdown-v1"` means the text
carries `## Page N` markers written by `indexedMarkdown`; `"markdown-v1-clipped"` means the
same but truncated at the cap; a null format means text written before markers existed and
is re-read once. Page numbers, staleness detection, and the bulk indexer's skip logic all
depend on this. Tagging converter output as `markdown-v1` when it carries no markers has
already happened once.

**A page number comes from the marker's own digits, never from counting markers.** A page
with no text layer is skipped entirely, heading included, so the third marker is not page
three.

**File operations are off by default** behind the `mcpFileOperations` preference. Never
enable it in a script or a test: it gates real file moves on a user's disk. The check suite
runs with it off by design, so the real apply path is verified by hand.

## Gotchas found the hard way

- `indexText` bails immediately when the scan result is empty, so indexing needs a folder
  scan first. A researcher who connects the plugin before scanning gets "nothing to search"
  with no clue why.
- `Job`'s memberwise initialiser is internal to `PaperShelfCore`; use `collectJobs` from
  other targets.
- `try?` against a throwing function that already returns an optional flattens
  unconditionally in this language mode, so a second `let x = try? f(), let x` does not
  compile.
- Three versions must agree: `paperShelfVersion` in Core, `version` in
  `Plugin/papershelf/.codex-plugin/plugin.json`, and `CFBundleShortVersionString` in
  `Resources/Info.plist`. `PluginInstall.swift` also reproduces the manifest in Swift because
  a built `.app` has no source checkout. They have drifted before; tests now pin them.
- The MCP check script writes plan files, and must keep pointing them at a scratch directory
  rather than the real `~/Library/Application Support/PaperShelf/`.

## Tests

`Tools/mcp-check.sh` builds a scratch SQLite library by hand and drives the server over
stdio, keying assertions by request id in `Tools/mcp-check.py`. Two things to know:

- There is a reply-count assertion near the top of the Python file. Adding a request without
  updating it makes every later check read the wrong reply.
- A check that cannot fail is worse than no check. Before adding one, revert the thing it
  covers and confirm it goes red. Several assertions here were found to pass whether or not
  their feature worked.
