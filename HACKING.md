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
python3 Tools/build-check.py
./build.sh
```

`swift build` must finish without errors. `swift test` builds the complete package even
when a filter is supplied. The MCP check must report zero failures. The app build creates
an ad-hoc signed `dist/PaperShelf.app`; inspect its version and bundled changelog before
installing it with `./build.sh --install`.

Builds stage and verify a complete bundle before replacing the existing app, including
installation. A failed build leaves the previous bundle available. Each bundle carries
its channel, unique build ID, UTC build time and source revision. Local builds use the
development channel and publish the latest completed bundle path in
`~/Library/Caches/PaperShelf/development-build.json`. A cache-write failure is reported
without rejecting the usable app bundle. The app captures its own identity at startup.
The bundle replacement check uses only scratch applications and a scratch record.

Release builds check GitHub at most once per day on activation; development builds default
to manual remote checks. General settings exposes the preference. The app menu, About,
Settings and command palette share **Check for updates**. Local checks run on activation
and compare completed bundle IDs. Notices offer release links or Reveal in Finder, with
no automatic download, installation or relaunch.

## Releases

Release directly from `main`. Keep `paperShelfVersion`, `Resources/Info.plist`, the plugin
manifest, and the top changelog entry aligned. Every commit is signed and uses a
Conventional Commit message. A release tag is signed and pushed with its commit:

```sh
git tag -s v1.0.0 -m "Release v1.0.0"
git push origin main v1.0.0
```

Before committing a release, update `docs/index.html`'s reported release version and release
link, then run the website tests. After publishing, verify the website and its release link
report the new version.

The tag starts the GitHub workflow that tests the package, builds the disk image, and
publishes the DMG and checksum. Signing and notarization use repository secrets when they
are configured; otherwise the release is ad-hoc signed and requires right-click, Open on
first launch, and the Homebrew cask says so. Once notarized, the cask drops that advice.

Notarizing needs an Apple Developer Program membership and six repository secrets, which
only the account holder can create. From a Mac holding the "Developer ID Application"
certificate, export it with its private key from Keychain Access as a `.p12`, create an
app-specific password at account.apple.com, then set them yourself:

```
base64 -i DeveloperID.p12 | gh secret set MACOS_CERTIFICATE --repo jonaprieto/papershelf
gh secret set MACOS_CERTIFICATE_PASSWORD --repo jonaprieto/papershelf   # the .p12 password
gh secret set MACOS_DEVELOPER_ID --repo jonaprieto/papershelf          # "Developer ID Application: Name (TEAMID)"
gh secret set NOTARY_APPLE_ID --repo jonaprieto/papershelf             # the Apple ID email
gh secret set NOTARY_TEAM_ID --repo jonaprieto/papershelf              # the ten-character team ID
gh secret set NOTARY_PASSWORD --repo jonaprieto/papershelf             # the app-specific password
```

`security find-identity -v -p codesigning` prints the exact `MACOS_DEVELOPER_ID` string.
Signing uses a hardened runtime, which refuses any protected resource the app has not
declared in `Resources/PaperShelf.entitlements`. Note dictation needs the microphone, so that
file declares audio input; a new feature reaching for the camera, contacts or Apple Events
to another app needs its entitlement added there, or it will fail silently in notarized
builds while working in every local one. `make-dmg.sh` refuses to build a signed release
whose entitlements did not make it into the signature.

The workflow invokes `Tools/make-dmg.sh --release`, which passes `--release` to `build.sh`.
Release builds require a clean checkout at the exact `v<version>` tag and matching Core,
Info.plist and plugin versions. Local `Tools/make-dmg.sh` builds remain development builds.
DMG signing uses a staged copy, leaving the completed app in `dist/` intact.

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

## Reader checks

The UI smoke test deliberately changes appearance and reading mode, so it never drives the
app it is given. It copies the app under its own bundle identifier, points the copy's library
and support folder at a scratch directory through LSEnvironment, and deletes the copy, its
folders and its preferences domain afterwards. Use the PDFKit regression tests to verify zoom
and scroll preservation.

Tests and scratch runs keep off the real library through three variables:
`PAPERSHELF_LIBRARY_PATH`, `PAPERSHELF_SUPPORT_PATH` (the diagnostics log, run cache and saved
web articles) and `PAPERSHELF_HIGHLIGHT_PROFILE_PATH`. A test process needs none of them: when
XCTest is loaded, the support folder is a temporary directory of that process's own.
