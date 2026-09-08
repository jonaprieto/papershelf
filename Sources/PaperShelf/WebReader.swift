import SwiftUI
import WebKit
import PDFKit
import PaperShelfCore

extension Notification.Name {
    static let webArticleSaved = Notification.Name("PaperShelf.webArticleSaved")
}

@MainActor @Observable
final class WebReaderModel: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var address = ""
    var loading = false
    var saving = false
    var error: String?
    var canGoBack = false
    var canGoForward = false
    var loaded = false
    let previous: WebArticle?

    init(previous: WebArticle? = nil, initialURL: URL? = nil) {
        self.previous = previous
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        address = initialURL?.absoluteString ?? previous?.url.absoluteString ?? ""
    }

    func navigate() {
        guard let url = WebArticle.navigationURL(address) else {
            error = "Enter an http or https website address."
            return
        }
        error = nil
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !saving else { decisionHandler(.cancel); return }
        guard let url = action.request.url,
              WebArticle.navigationURL(url.absoluteString) != nil else {
            decisionHandler(.cancel)
            return
        }
        if action.targetFrame == nil {
            decisionHandler(.cancel)
            webView.load(action.request)
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        loaded = false
        error = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        loaded = true
        address = webView.url?.absoluteString ?? address
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        self.error = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false
        self.error = error.localizedDescription
    }

    /// Each refresh is a new PDF and archive. Old reading copies and their notes stay put.
    func freeze(highlightColour: NSColor? = nil, destination: URL? = nil,
                library: Library? = .shared) async -> URL? {
        guard loaded, !loading, !saving else { return nil }
        saving = true
        error = nil
        defer { saving = false }
        do {
            let quoted = try await webView.evaluateJavaScript("String(window.getSelection())") as? String ?? ""
            if highlightColour != nil, quoted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                error = "Select a passage on the website, then choose its highlight colour."
                return nil
            }
            guard let url = webView.url,
                  let facts = try await webView.evaluateJavaScript(Self.metadataScript) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let article = WebArticle(
                url: url, title: facts["title"] as? String ?? webView.title ?? url.absoluteString,
                authors: facts["authors"] as? [String] ?? [], published: facts["published"] as? String,
                site: facts["site"] as? String, doi: facts["doi"] as? String,
                previousVersion: previous?.version)
            let width = (facts["width"] as? Double) ?? Double(webView.bounds.width)
            let height = (facts["height"] as? Double) ?? Double(webView.bounds.height)
            guard width > 0, height > 0, width < 20_000, height < 200_000 else {
                error = "This page is too large to save. Open the article's own page and try again."
                return nil
            }
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
            let pdf = try await webView.pdf(configuration: configuration)
            let archive: Data = try await withCheckedThrowingContinuation { continuation in
                webView.createWebArchiveData { continuation.resume(with: $0) }
            }
            guard let document = PDFDocument(data: pdf), document.pageCount > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if let highlightColour {
                let hits = document.findString(quoted, withOptions: [])
                guard hits.count == 1, let selection = hits.first else {
                    error = "This selection cannot be located uniquely in the saved page. Use Freeze and annotate, then select it in the reading copy."
                    return nil
                }
                _ = addPDFHighlights(for: selection, colour: highlightColour)
            }
            try article.embed(in: document)
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let folder = destination ?? supportDirectory(in: base).appendingPathComponent("Web Articles", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stem = article.title.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }
                .joined().prefix(90)
            let file = folder.appendingPathComponent("\(stem)-\(article.version.uuidString).pdf")
            guard let data = document.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
            try archive.write(to: file.deletingPathExtension().appendingPathExtension("webarchive"), options: .atomic)
            try data.write(to: file, options: .atomic)
            try Data(article.bibtex.utf8).write(to: file.deletingPathExtension().appendingPathExtension("bib"), options: .atomic)
            if let library {
                let input = Library.IndexInput(path: file.path, byteCount: data.count, pageCount: document.pageCount,
                                               title: article.title, author: article.authors.joined(separator: "; "))
                if let record = try await library.indexDocuments([input]).first {
                    try await library.storeBibtex(article.bibtex, forDocument: record.id, origin: "web-metadata")
                    KeptBibtex.shared.remember(article.bibtex, at: [file.path])
                }
            }
            NotificationCenter.default.post(name: .webArticleSaved, object: file)
            return file
        } catch {
            self.error = "Could not save this page: \(error.localizedDescription)"
            return nil
        }
    }

    // Highwire, Dublin Core and schema.org describe facts. Missing authors/dates stay missing.
    static let metadataScript = #"""
    (() => {
      const all = names => [...document.querySelectorAll('meta')]
        .filter(m => names.includes((m.name || m.getAttribute('property') || '').toLowerCase()))
        .map(m => m.content.trim()).filter(Boolean);
      const first = names => names.map(n => all([n])[0]).find(Boolean) || null;
      const objects = [];
      const walk = x => {
        if (Array.isArray(x)) { x.forEach(walk); return; }
        if (!x || typeof x !== 'object') return;
        objects.push(x); if (x['@graph']) walk(x['@graph']);
      };
      document.querySelectorAll('script[type="application/ld+json"]').forEach(s => {
        try { walk(JSON.parse(s.textContent)); } catch (_) {}
      });
      const article = objects.find(x => /Article|Posting|WebPage/.test(String(x['@type']))) || {};
      const author = [].concat(article.author || []).map(a => typeof a === 'string' ? a : a.name).filter(Boolean);
      const authors = ['citation_author', 'dc.creator', 'dcterms.creator']
        .map(n => all([n])).find(a => a.length) || [];
      const plainAuthors = all(['author']);
      return {
        title: first(['citation_title', 'dc.title', 'og:title']) || article.headline || article.name || document.title,
        authors: [...new Set(authors.length ? authors : author.length ? author : plainAuthors)],
        published: first(['citation_publication_date', 'citation_date', 'dcterms.issued', 'dc.date', 'article:published_time']) || article.datePublished || null,
        site: first(['og:site_name', 'citation_journal_title']) || null,
        doi: first(['citation_doi', 'dc.identifier.doi']),
        width: document.documentElement.clientWidth,
        height: Math.max(document.documentElement.scrollHeight, document.body.scrollHeight)
      };
    })()
    """#
}

private struct WebPageView: NSViewRepresentable {
    let model: WebReaderModel
    func makeNSView(context: Context) -> WKWebView { model.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

struct WebReader: View {
    @State private var model: WebReaderModel
    @State private var showsFind = false
    @State private var query = ""
    @State private var noMatch = false
    @FocusState private var findFocused: Bool
    let saved: (URL) -> Void

    init(previous: WebArticle? = nil, initialURL: URL? = nil, saved: @escaping (URL) -> Void) {
        _model = State(initialValue: WebReaderModel(previous: previous, initialURL: initialURL))
        self.saved = saved
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.snug) {
                Button { model.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack).help("Back").accessibilityLabel("Back")
                Button { model.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward).help("Forward").accessibilityLabel("Forward")
                TextField("Website address", text: $model.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.navigate() }
                    .accessibilityIdentifier("webReader.address")
                Button("Go") { model.navigate() }.disabled(model.saving)
                Button(model.saving ? "Saving…" : "Freeze and annotate") {
                    Task { if let url = await model.freeze() { saved(url) } }
                }
                .disabled(!model.loaded || model.loading || model.saving)
                .help("Save a local reading copy, web archive and citation. Existing versions keep their notes.")
                .accessibilityIdentifier("webReader.freeze")
            }
            .padding(Space.snug)
            if model.loaded {
                FlowRow(spacing: Space.step) {
                    Text("Highlight selection:").font(Face.caption)
                    ForEach(Palette.shared.styles(for: [.library])) { style in
                        Button {
                            Task { if let url = await model.freeze(highlightColour: style.nsColor) { saved(url) } }
                        } label: {
                            Circle().fill(style.swatch).frame(width: 18, height: 18)
                                .frame(width: 28, height: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Save this version and highlight the selection: \(style.meaning)")
                        .accessibilityLabel("Highlight selection: \(style.meaning)")
                        .disabled(model.saving || model.loading)
                    }
                    Text("Saves a reading copy with the same notes and highlights as a PDF.")
                        .font(Face.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, Space.snug)
            }
            if model.loading { ProgressView().progressViewStyle(.linear) }
            if let error = model.error {
                Text(error).font(Face.caption).foregroundStyle(Ink.red).padding(Space.snug)
            }
            Divider()
            if showsFind {
                HStack {
                    TextField("Find in website", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .focused($findFocused)
                        .onSubmit { find(backwards: false) }
                    Button("Previous") { find(backwards: true) }
                    Button("Next") { find(backwards: false) }
                    if noMatch { Text("No match").foregroundStyle(.secondary) }
                    Button("Done") { showsFind = false }
                }
                .padding(Space.snug)
            }
            WebPageView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .focusedValue(\.findInPDF, FindInPDFAction(perform: openFind))
        .onReceive(NotificationCenter.default.publisher(for: .openPDFSearch)) { note in
            guard let window = note.object as? NSWindow, window === model.webView.window else { return }
            openFind()
        }
        .task { if !model.address.isEmpty { model.navigate() } }
    }

    private func openFind() { showsFind = true; findFocused = true }

    private func find(backwards: Bool) {
        guard !query.isEmpty else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        model.webView.find(query, configuration: configuration) { noMatch = !$0.matchFound }
    }
}
