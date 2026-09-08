<img src="docs/icon.png" width="128" alt="PaperShelf">

# PaperShelf

The macOS PDF reader and library manager for people who search, highlight, cite, and file
research papers. It is the reader I wished I had years ago.

> PaperShelf is under heavy development. It is functional, but releases can change stored
> preferences and behavior.

![PaperShelf catalogue](docs/screenshot-catalogue.png)

## Install

### Homebrew

```sh
brew tap jonaprieto/papershelf
brew trust --cask jonaprieto/papershelf/papershelf
brew install --cask papershelf
```

The cask installs the latest release. Builds are ad-hoc signed while notarization is on the
roadmap, so the first launch may require right-click, Open in Finder.

### Update

```sh
brew update
brew upgrade --cask papershelf
```

### Build from source

Build the app bundle:

```sh
./build.sh
```

Install a fresh local build in `/Applications`:

```sh
./build.sh --install
```

PaperShelf has no third-party Swift package dependencies. It runs on macOS 14 or later.

## What it does

- Reads PDFs in a focused reader with full screen, page navigation, contrast modes, and
  notes that stay beside the passage they describe.
- Searches filenames, metadata, extracted text, folders, tags, pages, and projects.
- Highlights passages with customizable meanings per library, folder, project, or paper.
- Writes a generated Markdown companion beside a PDF, with PDF annotations as the source of
  truth.
- Reviews safe filename changes before applying them, keeps originals when requested, and
  finds duplicate documents without guessing that similar names are identical.
- Builds BibTeX and connects a local MCP server to ChatGPT without uploading the library.

## Web articles and reading questions

In a source build, use File > Open Website (Command-L), the globe toolbar button, or the
command palette. Navigate to an article, then choose **Freeze and annotate**. This saves
the full loaded page as a selectable PDF, the web archive, and a BibTeX companion under
PaperShelf's Application Support folder. The reading copy joins the catalogue and uses
the same notes, highlights, search, contrast and split controls as other documents.
Selecting text on the live page and choosing a highlight colour saves and marks that
passage in the reading copy. Ambiguous text matches ask you to select in the saved copy.

An article's **Open live / resync** button opens its website in the same pane, including
beside a PDF. Freeze again to keep a new version. Existing copies and their annotations
are retained. A snapshot includes content loaded at capture time; it does not crawl linked
pages or fetch material hidden behind a site's login or an unopened section.

Citation facts come from Highwire, Dublin Core, Open Graph and schema.org metadata supplied
by the page. Missing authors and publication dates stay missing. The citation includes
the source URL and capture date; review it in the Cite inspector before publication.

**Ask AI** on selections, marks and the notes export bar uses the API endpoint and model in
Settings. It shows the text and destination before Send question. The ChatGPT handoff is
an additional option; it is not required for these reading questions.

## Roadmap

- [ ] Notarized and signed releases
- [ ] Stable 2.0 storage and plugin interfaces
- [ ] Better OCR and reading-project workflows
- [ ] Upstream Homebrew Cask submission when the project meets its requirements

## Links

- [Landing page](https://jonaprieto.github.io/papershelf/)
- [Latest release](https://github.com/jonaprieto/papershelf/releases/latest)
- [Build and test contract](HACKING.md)
- [Contributing](CONTRIBUTORS.md)
- [Changelog](CHANGELOG.md)
