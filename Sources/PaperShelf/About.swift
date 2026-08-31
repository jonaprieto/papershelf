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

    /// Which of the three the window is showing. A window, not three: they are one
    /// question -- what is this -- asked at three depths.
    private enum Page: String, CaseIterable, Identifiable {
        case about, licence, thirdParty
        var id: String { rawValue }

        var label: String {
            switch self {
            case .about: return "About"
            case .licence: return "Licence"
            case .thirdParty: return "Third-Party Software"
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
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()

            ScrollView {
                Group {
                    switch page {
                    case .about: summary
                    case .licence: text(AboutWindow.licence)
                    case .thirdParty: thirdPartyBody
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Tall enough that the longest of the three -- the licence -- is read by
        // scrolling a little rather than through a slot.
        .frame(width: 540, height: 620)
    }

    /// The part the stock panel already got right, and the two lines it was missing.
    private var identity: some View {
        VStack(spacing: 6) {
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
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
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
        VStack(alignment: .leading, spacing: 14) {
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

            VStack(alignment: .leading, spacing: 6) {
                ForEach(markdownConverters, id: \.name) { converter in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(converter.name)
                            .font(Face.body.weight(.medium))
                            .frame(width: 96, alignment: .leading)
                        Text(converter.executable)
                            .font(Face.mono)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, 4)

            section("Models", "Answers and suggested names come from whichever model and "
                    + "endpoint you configure in Settings. That service is not part of "
                    + "PaperShelf, is billed by its provider, and is governed by that "
                    + "provider's own terms.")
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Face.headline)
            text(body)
        }
    }

    /// Selectable on purpose: a licence you cannot copy out of is a licence you have to
    /// retype to comply with.
    private func text(_ body: String) -> some View {
        Text(body)
            .font(body == AboutWindow.licence ? Face.mono : Face.body)
            .foregroundStyle(body == AboutWindow.licence ? .primary : .secondary)
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
}
