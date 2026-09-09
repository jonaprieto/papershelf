# Update notifications

Status: implementation in progress, 8 September 2026. Build identity and safe bundle
replacement, release checks and local detection are implemented. The notices and manual
command are next.

## What the user sees

Keep the version in the status bar, with a small **Update available** button beside it
when a newer stable release exists. Clicking it shows the running version, available
version, last successful check, and **View release**. The release page supplies the notes
and download. Add **Check for updates** to the application menu, About window and command
palette, with no default shortcut.

Use an in-app notice. It should not interrupt reading with a launch dialog or require
macOS notification permission. Keep a dismissed version available in About and manual
checks; a later version can show its own badge.

Development builds also show **Local build available** when a completed app bundle
differs from the running build. These notices answer separate questions:

| Situation | Result |
| --- | --- |
| Running 1.14.1; published release is 1.15.0 | Update available |
| Running 1.14.1; published release is 1.14.1 or older | No release-update badge |
| Running 1.14.1 with local changes; release is also 1.14.1 | Show the development identity; do not claim the builds are identical |
| Another local build finishes with the same version and commit | Local build available, identified by its new build ID |
| The checkout changes but no app has been built | No local-build notice |
| A check fails or the network is unavailable | Keep cached information; manual checks report that verification failed |

## Identify the running build reliably

The current footer combines the semantic version, bundle build number and
`PaperShelfGitCommit`, including `+dirty`. Both local and release builds use release
optimization, and the packaging script initially signs both ad hoc. Neither optimization
nor `PaperShelfAdHocBuild` identifies the distribution channel.

Add bundle metadata in `build.sh`:

- `PaperShelfBuildChannel`: development by default; release only through an explicit
  release-build option used by the release workflow.
- `PaperShelfBuildID`: a new UUID for each completed bundle, preserved when that bundle
  is copied or installed.
- `PaperShelfBuiltAt`: UTC build time, for display and local-build comparisons.
- Retain the existing version, build number and source revision.

Capture these values at application startup. The footer and About must keep describing
the running process after its bundle is replaced on disk. Read replacement metadata
separately, without relying on the cached `Bundle.main` dictionary.

A release build must require a clean checkout at the exact version tag, with the Core,
Info.plist and plugin versions aligned. Update `HACKING.md`, `AGENTS.md`,
`Tools/make-dmg.sh` and the release workflow with that contract when implementing it.
Do not change the current version merely to add the checker.

## Check published releases

Use Foundation `URLSession`, with no new dependency, to request
`https://api.github.com/repos/jonaprieto/papershelf/releases/latest`.
GitHub documents this endpoint as the latest published full release and allows public
requests without authentication. Use its `tag_name`, `html_url`, `draft`,
`prerelease` and asset metadata.
[GitHub release API](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)

Accept the project's stable `MAJOR.MINOR.PATCH` tags, with an optional leading `v`.
Reject malformed values, drafts, prereleases and releases without the expected uploaded
PaperShelf DMG. Compare integer components, so 1.10.0 is newer than 1.9.0. Revision hashes,
`+dirty`, timestamps and bundle build numbers do not determine release precedence.
Semantic Versioning excludes build metadata from precedence.
[Semantic Versioning](https://semver.org/)

For release builds, check after launch or activation at most once per day when automatic
checks are enabled. Development builds default to manual remote checks. Provide an
**Automatically check for releases** preference. Keep one request in flight, use a short
timeout, and respect server retry instructions and rate limits.

Persist the last attempt, last successful result and dismissed version separately.
A failure must not become “up to date.” Show the last successful check beside cached data.
Validate that the release link uses HTTPS and belongs to this repository before opening
it. This request needs no PDF paths, document content, library data or AI credentials.

## Detect completed development builds

Start with the bundle path used by the running process. On activation, compare its on-disk
build ID with the startup snapshot. A changed ID means a different executable is ready
at that path, even when the semantic version, revision and dirty marker are unchanged.
Ignore missing or incomplete bundles while a build is in progress.

Also cover the common case of running `/Applications/PaperShelf.app` while building
`dist/PaperShelf.app`. After a successful local build, publish an atomic JSON record at
`~/Library/Caches/PaperShelf/development-build.json` containing its absolute bundle path,
build ID, version and completion time. Development builds can read this record on
activation. Verify that its bundle still exists and that its metadata matches the record;
ignore stale records. Track one latest local build initially, rather than scanning
checkouts or watching source files.

Build into a temporary sibling directory, copy resources, sign and verify it, then replace
the destination and publish the record. Apply the same completed-bundle discipline to
installation. A build that fails must not replace the previous valid bundle or advertise
an update. Reinstalling the same build ID must not show a new notice.

For a local notice, show the running and available identities, the available bundle path,
and **Reveal build in Finder**. Explain that the user must relaunch that build to use it.
Do not automatically replace an installed application, start a second instance, or quit a
reader with pending notes. An integrated Relaunch action can follow after the termination
path waits for annotation saves and handles failures; the current termination callback
alone is not sufficient evidence for that guarantee.

## Implementation order and checks

1. Add and validate build identity, stage completed bundles, and publish the development
   record. Verify local build, install and release packaging independently.
2. Add the release checker with a stubbed network session and the numeric comparison.
   Cover newer, equal and older versions, malformed data, missing DMGs, timeouts, offline
   operation and rate limits. No test needs the live API.
3. Add local detection using scratch bundle plists and records. Cover identical builds,
   repeated dirty builds, a replaced running bundle, a separate dist build, a stale path
   and an interrupted build. Never touch an installed app in these tests.
4. Add the compact badge, details popover, preference and shared manual-check command.
   Verify keyboard access, hover help, VoiceOver labels, narrow windows and both themes.
   Exercise dismissal, cached results and retry behavior.
5. Run the repository's build, test, MCP, bundle and UI checks, then commit each working
   step. Before release, verify the published DMG is present and the release link opens
   the intended version.

The first implementation only notifies and points to a completed artifact. Automatic
download, installation, prerelease channels and an updater framework remain separate work.
