import SwiftUI
import AppKit
import PaperShelfCore

/// What the app is, what it is licensed under, and what else it leans on.
///
/// The stock about panel says a name, a version and one line of copyright, which is what
/// an app says before anybody has to trust it with their files. Somebody deciding whether
/// to run this over fourteen thousand documents wants three more answers: who wrote it,
/// what they may do with it, and what other software is involved.
struct AboutWindow: View {
    static let windowID = "about"

    /// Which of the four the window is showing. A window, not four: they are one
    /// question -- what is this -- asked at four depths.
    private enum Page: String, CaseIterable, Identifiable {
        case about, licence, thirdParty, changelog
        var id: String { rawValue }

        var label: String {
            switch self {
            case .about: return "About"
            case .licence: return "Licence"
            case .thirdParty: return "Third-Party Software"
            case .changelog: return "Changelog"
            }
        }
    }

    @State private var page: Page = .about

    var body: some View {
        VStack(spacing: 0) {
            identity
            Divider()
            Picker("", selection: $page) {
                ForEach(Page.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.step)
            Divider()

            ScrollView {
                Group {
                    switch page {
                    case .about: summary
                    case .licence: text(AboutWindow.licence, mono: true, muted: false)
                    case .thirdParty: thirdPartyBody
                    case .changelog: text(AboutWindow.changelog, mono: true, muted: false)
                    }
                }
                .padding(Space.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Tall enough that the longest of the four -- the licence, or a changelog with a
        // few entries in it -- is read by scrolling a little rather than through a slot.
        .frame(width: 540, height: 620)
        .preferredColorScheme(Prefs.shared.appearance.colorScheme)
    }

    /// The part the stock panel already got right, and the two lines it was missing.
    private var identity: some View {
        VStack(spacing: Space.snug) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 64, height: 64)
            }
            Text(AboutWindow.name).font(Face.title)
            Text("Version \(AboutWindow.version) (\(AboutWindow.build))")
                .font(Face.body)
                .foregroundStyle(.secondary)
            // The copyright line already names the licence; saying it twice under the
            // version is two lines where the panel has room for one.
            Text(AboutWindow.copyright)
                .font(Face.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, Space.gutter)
        .padding(.bottom, Space.roomy)
        .frame(maxWidth: .infinity)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Space.roomy) {
            text("PaperShelf reads, renames, files and searches a library of PDFs, and "
                 + "answers questions across the ones you group into a reading project. "
                 + "Every answer cites the document and page it came from.")
            text("Your documents stay on this machine. Text is sent to a model only when "
                 + "you ask a question or ask for a name, to the endpoint set in Settings, "
                 + "and the window says how much is going and where before it goes.")
        }
    }

    /// Honest about the fact that there is nothing to acknowledge in the usual sense, and
    /// specific about the part that does involve other people's software.
    ///
    /// An acknowledgements screen listing libraries an app does not actually ship is worse
    /// than no screen: it is a licence notice that is not true.
    private var thirdPartyBody: some View {
        VStack(alignment: .leading, spacing: Space.roomy) {
            section("Bundled software", "PaperShelf bundles no third-party code. It is "
                    + "built entirely on frameworks that ship with macOS \u{2014} SwiftUI, "
                    + "AppKit, PDFKit, Vision, CryptoKit, UserNotifications and the "
                    + "system SQLite \u{2014} which are Apple's and are used under the "
                    + "terms you already accepted with the system.")

            section("Converters you install yourself",
                    "PaperShelf can hand a PDF to one of these to read it as Markdown, if "
                    + "you have installed it. None of them is distributed with PaperShelf, "
                    + "none is required, and each is separate software under its own "
                    + "licence and its own authors' terms:")

            VStack(alignment: .leading, spacing: Space.snug) {
                ForEach(markdownConverters, id: \.name) { converter in
                    HStack(alignment: .firstTextBaseline, spacing: Space.step) {
                        Text(converter.name)
                            .font(Face.body.weight(.medium))
                            .frame(width: 96, alignment: .leading)
                        Text(converter.executable)
                            .font(Face.mono)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, Space.tight)

            section("Models", "Answers and suggested names come from whichever model and "
                    + "endpoint you configure in Settings. That service is not part of "
                    + "PaperShelf, is billed by its provider, and is governed by that "
                    + "provider's own terms.")
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Text(title).font(Face.headline)
            text(body)
        }
    }

    /// Selectable on purpose: a licence, or a changelog entry, you cannot copy out of is
    /// one you have to retype to quote. `mono` is for verbatim documents read as they are
    /// written, the licence and the changelog; `muted` sets the two of those, the main
    /// content of the page they are on, apart from a paragraph that is only introducing
    /// something else.
    private func text(_ body: String, mono: Bool = false, muted: Bool = true) -> some View {
        Text(body)
            .font(mono ? Face.mono : Face.body)
            .foregroundStyle(muted ? .secondary : .primary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    // MARK: What the bundle says about itself

    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "PaperShelf"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    static var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }

    /// The same words as the `LICENSE` file at the root of the repository. A test holds
    /// the two together: a licence shown in the app that has drifted from the one shipped
    /// beside the source is a licence nobody can rely on.
    static let licence = """
    MIT License

    Copyright (c) 2026 Jonathan Prieto-Cubides

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """

    /// `CHANGELOG.md`, read from wherever `build.sh` copied it, the same way it copies
    /// `PluginLogo.png`. There is exactly one copy of the file, at the repository root; a
    /// built `.app` has no source checkout to read that from directly, so this reads the
    /// one `build.sh` placed inside the bundle instead of a second copy kept in the repo,
    /// which is what could have silently gone stale against the real one.
    ///
    /// A build that never went through `build.sh` -- `swift run`, or a `.app` built before
    /// this shipped -- has no such file. That is said plainly rather than showing an empty
    /// page, which would read as the window being broken rather than as a build that
    /// predates this feature.
    static var changelog: String {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The changelog is not available in this build."
        }
        return text
    }
}
