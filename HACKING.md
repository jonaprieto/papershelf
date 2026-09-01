# Hacking on PaperShelf

PaperShelf is a macOS Swift package with three targets and no third-party dependencies:

- `PaperShelfCore` holds PDF reading, naming, BibTeX, search, duplicates, and SQLite.
- `PaperShelf` is the SwiftUI application.
- `PaperShelfMCP` is the JSON-RPC-over-stdio server bundled into the app.

## The contract

Run these from the repository root:

```sh
swift build
swift test
Tools/mcp-check.sh
./build.sh
```

`swift build` must finish without errors. `swift test` builds the complete package even
when a filter is supplied. The MCP check must report zero failures. The app build creates
an ad-hoc signed `dist/PaperShelf.app`; inspect its version and bundled changelog before
installing it with `./build.sh --install`.

## Releases

Release directly from `main`. Keep `paperShelfVersion`, `Resources/Info.plist`, the plugin
manifest, and the top changelog entry aligned. Every commit is signed and uses a
Conventional Commit message. A release tag is signed and pushed with its commit:

```sh
git tag -s v1.0.0 -m "Release v1.0.0"
git push origin main v1.0.0
```

The tag starts the GitHub workflow that tests the package, builds the disk image, and
publishes the DMG and checksum. Signing and notarization use repository secrets when they
are configured; otherwise the release is ad-hoc signed and requires right-click, Open on
first launch.

## Safety invariants

- Only JSON-RPC may reach MCP stdout. Diagnostics go to stderr.
- User-fixable tool failures are results with `isError`, not protocol errors.
- Tool limits clamp negative and excessively large values before reaching SQLite.
- Extracted text formats accurately describe page markers and clipping.
- Test libraries use scratch paths through `PAPERSHELF_LIBRARY_PATH`; they never open the
  real Application Support library.
- MCP file operations are off by default and require an explicit user preference.

Keep comments focused on consequences, preserve the no-dependency boundary, and never add
secrets, personal machine paths, or generated build output to the repository.
