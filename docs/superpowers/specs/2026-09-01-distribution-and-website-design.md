# Distribution: a public repository, a landing page, and a Homebrew cask

PaperShelf works and is used daily, but nobody outside this machine can install it. The
repository is private, there is no 1.7.0 release, the README is 577 lines of reference
material that buries the getting-started path, and there is no way to install the app that
does not begin with cloning a Swift package.

This design covers what has to happen for a stranger to find PaperShelf, understand what it
is in thirty seconds, and install it in two commands.

## What is being decided

Seven pieces of work, in dependency order. They share one release event, so they are one
spec rather than seven.

1. Making the repository publishable, and public.
2. Centring the app icon, which is visibly off.
3. A real screenshot of the catalogue.
4. A README cut to what a newcomer needs, plus `HACKING.md` and `CONTRIBUTORS.md`.
5. A v1.7.0 release.
6. A Homebrew cask in its own tap, kept current by CI.
7. A landing page on GitHub Pages, and the repository settings around it.

## 1. Making the repository publishable

`jonaprieto/papershelf` is private today. GitHub Pages on a private repository requires a
paid plan, and a Homebrew cask needs a download URL that resolves without authentication.
Both are blocked until the repository is public, so this happens, and it happens first.

Going public is not reversible in any meaningful sense: anything in the history is
mirrored, forked and indexed within minutes. Three gates run before the switch is flipped.

**A history scan for secrets.** `git log -p` across all 259 tracked files, filtered for
`sk-`, `ghp_`, `github_pat_`, `AKIA`, `-----BEGIN`, `password =`, `api_key`, `token =`,
plus a direct read of every tracked `.plist`, `.json`, `.sh` and `.yml`. The API key this
app uses lives in the Keychain and the `OPENAI_API_KEY` environment variable by design, so
the expectation is a clean scan; the scan runs anyway, because the cost of being wrong is
unbounded and the cost of checking is a minute.

`jonaprieto` appears in seventeen tracked files. It is the bundle identifier
`com.jonaprieto.pdfhammer`, the plugin identifier, and the author's name in prose. It stays.

**Untracking vendored third-party skills.** `.agents/skills/` holds 44 files of
Anthropic-authored SwiftUI and iOS reference documentation, roughly ten thousand lines,
committed into this repository. Making the repository public republishes someone else's
documentation under this project's name and licence. They are removed from tracking and
added to `.gitignore`; `skills-lock.json` stays, so the set remains reproducible for anyone
who wants it.

**Confirming nothing points at the real library.** Every fixture and test must resolve
through `PAPERSHELF_LIBRARY_PATH` or the plans-directory override, never
`~/Library/Application Support/PaperShelf`. `Tools/real-library-check.swift` is read
specifically, since its name suggests otherwise.

Only after all three does visibility change.

**Actions stays enabled.** The original request included disabling it, but
`.github/workflows/release.yml` is the only workflow, it triggers on `v*` tags and manual
dispatch rather than on pushes, and it is what builds and publishes the disk image that the
Homebrew cask installs. Disabling it would mean building and uploading every release by
hand. There is no CI noise to remove: pushes do not trigger it.

## 2. Centring the icon

In `Tools/make-icon.swift`, the rounded plate spans y 90 to 914 on a 1024 canvas. The
content, from the shelf's underside at y 174 to the tallest spine's top at y 717, leaves 197
units of empty plate above and 84 below. The books sit visibly low, which is what the
annotated screenshot pointed at.

Horizontally the shelf already spans 225 to 799, centred on 512, matching the plate. Only
the vertical is wrong.

The fix is one transform: `ctx.translateBy(x: 0, y: 56)` applied after the plate is filled
and before the spines are drawn, with a comment recording that 56 is half the difference
between the two gaps rather than a number that looked right. Content then spans 230 to 773,
centred on 501.5 against the plate's 502.

`Tools/make-icon.sh` regenerates `Resources/AppIcon.icns`. `docs/icon.png` is replaced with
the run's own `icon_256x256@2x.png` slice, so the README and the landing page show the
corrected mark rather than a separately drawn copy of it.

Verification is arithmetic, not eyeballing. A test asserts the drawn content's bounding box
centre equals the plate's centre within one unit. Reverting the translate must turn it red.

## 3. The screenshot

One real capture, of the catalogue view, used in both the README and the landing page hero.
The five smaller panels on the landing page stay as drawn HTML, for reasons in section 7.

The app is launched on Desktop 1, so it does not take focus on whichever Space is in use,
and pointed via `PAPERSHELF_LIBRARY_PATH` at a scratch directory holding 40 to 60
open-access arXiv PDFs. Nothing from the real library appears, the shelf looks genuinely
full rather than sparse, and every visible title is a real paper anyone can look up.

The library is indexed before capture, so the status bar reads honestly. `screencapture -o`
takes the window without its drop shadow, at native Retina scale. The result is downsampled
with `sips -Z 2400` to 2400px on its long edge, which is two-times the width the page draws
it at, and compressed to under 400 KB. It is written to `docs/screenshot-catalogue.png`.

The mock catalogue window currently in the landing page draft is replaced by this file. The
drawn version was built from the real `Metric` and `Ink` values, so the layout should
survive the swap, but the section is checked at a phone width afterwards regardless.

## 4. README, HACKING, CONTRIBUTORS

The README goes from 577 lines to roughly 60. In order: the icon, one sentence on what
PaperShelf is, the line about being the reader the author wished he had years ago, a banner
saying the project is under heavy development and functional but unstable between versions,
the screenshot, getting started, what it does in six bullets, a roadmap checklist, and links.

Getting started is the two Homebrew lines, the note that the first launch needs a right-click
and Open because builds are not notarised, and `./build.sh --install` for people who would
rather build it.

The roadmap is drawn from `PLAN.md` workstreams 6, 7 and 8, which are the unfinished ones,
plus notarised builds and a stable 2.0.

Nothing removed is lost. The reference material lives in git history, and the parts a
newcomer actually wants are on the landing page.

**`HACKING.md`** is the build-and-test contract, lifted from `AGENTS.md`: the three SwiftPM
targets and what each is for, `swift build` with its zero-warnings requirement, `swift test`,
`Tools/mcp-check.sh`, `./build.sh`, the fact that `swift test --filter` still builds every
target, the no-third-party-dependencies rule and why it is worth keeping, the commit
conventions, and the invariants section on stdout, `isError`, limit clamping and
`extracted_text.format`.

`AGENTS.md` stays as the agent-facing file and points at `HACKING.md` for the human half,
rather than the two drifting apart. That is the same rule `CLAUDE.md` already states about
guidance living in one file.

**`CONTRIBUTORS.md`** lists Jonathan Cubides, with a sentence on how someone else gets added.

## 5. The v1.7.0 release

`CHANGELOG.md` already describes 1.7.0 and `Info.plist` already carries the version, held
there by a test. What is missing is the tag.

Tagging `v1.7.0` on `main` fires `release.yml`, which runs `swift test`, builds the disk
image via `Tools/make-dmg.sh`, and publishes `PaperShelf-1.7.0.dmg` with its `.sha256`
alongside generated notes.

No signing secrets are configured, so the build is ad-hoc signed rather than notarised, and
Gatekeeper will say the app is from an unidentified developer on first launch. This is
stated plainly in the README, the cask caveat and the landing page rather than left as a
surprise. Notarisation is on the roadmap; it needs a paid Apple Developer account.

The `v1.3.0` tag exists with no release behind it. It is deleted, since a tag nobody can
download from is a dead link in the tag list.

## 6. The Homebrew cask

The app ships as a `.app` inside a disk image, so this is a cask, not a formula.

Homebrew requires a tap repository be named `homebrew-*`, so it cannot live inside
`papershelf`. A new public repository `jonaprieto/homebrew-papershelf` holds
`Casks/papershelf.rb`: the version, the sha256, a url pointing at the release asset,
`app "PaperShelf.app"`, a `zap` stanza covering
`~/Library/Application Support/PaperShelf` and the `com.jonaprieto.pdfhammer` preferences
domain, and a `caveats` block explaining the unsigned first launch.

Installing becomes two lines:

```
brew tap jonaprieto/papershelf
brew install --cask papershelf
```

Submitting to `homebrew/homebrew-cask` upstream would drop the tap line, but upstream has
notability requirements a project that has been private until today will not meet, and it
expects notarised signing. That is a later move, not this one.

A `Publish the cask` step is added to `release.yml`, after the existing publish step. It
rewrites the version and sha256 in the cask and pushes to the tap, so the cask can never lag
a release. It is gated on a `TAP_TOKEN` secret being present, following the same pattern the
signing steps already use, so a fork without the secret skips the step rather than failing
the build.

Creating that token is the one manual step in this whole plan. The exact command is written
out for the user to run; it is not run on their behalf, because it writes a secret to a
deployment surface.

## 7. The landing page

A single page, served from `main` at `/docs`, so there is no `gh-pages` branch and no build
step. `docs/index.html` is self-contained apart from a Google Fonts stylesheet.
A `.nojekyll` file is added so GitHub does not try to run Jekyll over the Markdown already
in `docs/`, which would fail the build. A consequence worth naming: `docs/design/` and
`docs/superpowers/` become reachable as raw files under the site's URL. In a public
repository they are readable on GitHub anyway, so this is untidy rather than a leak, and it
is the price of not maintaining a separate branch.

The design is approved and lives in the canvas at
`https://claude.ai/code/artifact/d1589d60-0849-409b-8cac-7e31d3e02e37`. Its shape:

Dark, near-black, using the icon's own palette. Source Serif 4 throughout, set large: a 92px
hero, 58px section headings, 20 to 21px body prose. Small interface labels stay in the system
sans so they read as chrome rather than as text. Amber `#FFC53D` appears only on the one
primary action and as section marks.

A hero with the development banner, the two install lines and the download link. The
screenshot. Then six numbered sections, each showing a feature rather than describing it:

- **Read**: the five highlighters with their real default meanings and the scope selector,
  beside a notes rail carrying two marks.
- **Find**: the real query language, and a `⌘K` palette with its six prefixes. This section
  makes the point explicitly that the palette is how a feature nobody knew about gets found.
- **Keep in order**: name-rule chips producing a real filename with the text form beside it,
  the reviewer's keys including batch confirm and undo, and the three duplicate passes with
  the arrival watcher.
- **Cite**: a syntax-highlighted `.bib`, the `surname:year:firstword` key rule, the
  bibtex-tidy settings, and the missing-field chips.
- **Connect**: both install commands, and all sixteen MCP tools with the two write tools
  marked as off by default.
- **Underneath**: the four Markdown converters by name, indexing behaviour, the cost ledger,
  password lists, the activity log, and the Keychain.

Then the roadmap, a closing block, and a footer.

**The five drawn panels are a liability, and get a test.** They quote the app: highlighter
meanings, palette prefixes, MCP tool names, the citation-key format. A drawn panel that
falls out of step with the app is worse than no panel, because it reads as documentation.
So one focused test in `Tests/PaperShelfAppTests` asserts that the tool names appearing in
`docs/index.html` are exactly the tool names the MCP server registers, and that the five
default highlighter meanings in the page match `Palette.shared`'s defaults. Both lists are
already single sources of truth in code. It reaches the page by walking up from `#filePath`,
which is the pattern `AboutTests` and `PluginInstallTests` already use to read repository
files. Changing either list without changing the page must turn the test red.

This is the same rule the keyboard settings pane already follows: the list is the table the
key monitor reads, so it cannot drift.

## 8. Repository settings

Applied last, after everything above is on `main`.

- Visibility: public.
- Description: "The macOS PDF reader and library manager I wished I had. Search, highlight,
  cite and file papers, with an MCP server so an assistant can read them without the files
  leaving your Mac."
- Homepage: `https://jonaprieto.github.io/papershelf/`.
- Pages: enabled, source `main` branch, `/docs` folder.
- Wiki: off. Projects: off.
- Issues: on. A public project with no issue tracker is a dead end.
- Actions: on, per section 1.

**Agents.** The request included disabling the Agents tab. There is no documented repository
API field for it. The REST API is checked for one; if none exists, the exact path through
the web Settings UI is written out rather than the item being reported as done.

## Order of work

Each step leaves the tree green, and each is independently committable.

1. Untrack `.agents/skills/`, add to `.gitignore`.
2. Secret scan and fixture audit. No commit; a report.
3. Icon centring, regenerated assets, centring test.
4. Scratch arXiv library, launch on Desktop 1, capture `docs/screenshot-catalogue.png`.
5. `docs/index.html`, `.nojekyll`, and the drift test.
6. README rewrite, `HACKING.md`, `CONTRIBUTORS.md`, `AGENTS.md` pointer.
7. Repository public. Description, homepage, wiki, projects, Pages. Verify the site serves.
8. Tag `v1.7.0`, watch the workflow, verify the release assets. Delete the `v1.3.0` tag.
9. Create `jonaprieto/homebrew-papershelf` with the cask pinned to 1.7.0's sha256. Verify
   `brew install --cask` end to end on this machine.
10. Add the cask-publishing step to `release.yml`, gated on `TAP_TOKEN`. Hand over the
    command that creates the secret.

Steps 8 through 10 depend on 7. Steps 3 through 6 do not, and can land before it.

## What is deliberately not here

Notarised signing, which needs a paid Apple Developer account. Submission to
`homebrew/homebrew-cask` upstream, which needs notability this project does not have yet.
Migrating the README's reference material onto the site as separate documentation pages,
which was considered and set aside: one page is the right size for a project this young, and
git history holds what was cut.
