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
    private var printCompletion: CheckedContinuation<Bool, Never>?

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
            try await prepareCapture()
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
                modified: facts["modified"] as? String,
                previousVersion: previous?.version)
            let width = (facts["width"] as? Double) ?? Double(webView.bounds.width)
            let height = (facts["height"] as? Double) ?? Double(webView.bounds.height)
            guard width > 0, height > 0, width < 20_000, height < 200_000 else {
                error = "This page is too large to save. Open the article's own page and try again."
                return nil
            }
            let pdf = try await paginatedPDF()
            let archive: Data = try await withCheckedThrowingContinuation { continuation in
                webView.createWebArchiveData { continuation.resume(with: $0) }
            }
            guard let document = PDFDocument(data: pdf), document.pageCount > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if let highlightColour {
                let hits = document.findString(quoted, withOptions: [])
                guard hits.count == 1, let selection = hits.first else {
                    error = "This selection cannot be located uniquely in the saved page. Use Save copy, then select it in the reading copy."
                    return nil
                }
                _ = addPDFHighlights(for: selection, colour: highlightColour)
            }
            try article.embed(in: document)
            // Through `supportDirectory()` like everything else beside the library, so a run
            // pointed at a scratch folder, and every test, saves its articles there. Building
            // the path from the user's Application Support directory here went around both.
            guard let folder = destination
                    ?? supportDirectory()?.appendingPathComponent("Web Articles", isDirectory: true)
            else { throw CocoaError(.fileNoSuchFile) }
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

    /// WebKit's print layout reflows paragraphs onto pages instead of shrinking a long strip.
    func paginatedPDF() async throws -> Data {
        _ = try await webView.evaluateJavaScript(Self.printStyleScript)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("papershelf-print-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("article.pdf")
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = file
        info.dictionary()[NSPrintInfo.AttributeKey.allPages] = true
        info.paperSize = NSSize(width: 595.28, height: 841.89)
        info.topMargin = 36
        info.bottomMargin = 36
        info.leftMargin = 36
        info.rightMargin = 36
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.canSpawnSeparateThread = true
        // WebKit calculates page ranges on its worker while the main run loop stays free.
        let window = webView.window ?? NSWindow(contentRect: webView.bounds,
                                               styleMask: .borderless, backing: .buffered, defer: false)
        let completed = await withCheckedContinuation { continuation in
            printCompletion = continuation
            operation.runModal(for: window, delegate: self,
                               didRun: #selector(printFinished(_:success:context:)), contextInfo: nil)
        }
        guard completed else { throw CocoaError(.fileWriteUnknown) }
        return try Data(contentsOf: file)
    }

    static let printStyleScript = #"""
    (() => {
      if (document.getElementById('papershelf-print-style')) return true;
      const style = document.createElement('style');
      style.id = 'papershelf-print-style';
      style.textContent = `@media print {
        nav, [role="navigation"], .navigation, [role="search"] { display: none !important; }
        h1 { font-size: 24pt !important; }
        h2, h3, h4 { break-after: avoid; }
        p { orphans: 3; widows: 3; }
        figure, math, mjx-container[display="true"], .katex-display { break-inside: avoid; }
        img { max-width: 100%; height: auto; }
      }`;
      if (location.hostname === 'ncatlab.org') {
        style.textContent += '@media print { #pageName > span { display: none !important; } }';
      }
      document.head.appendChild(style);
      return true;
    })()
    """#

    @objc private func printFinished(_ operation: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) {
        printCompletion?.resume(returning: success)
        printCompletion = nil
    }

    /// Loading the HTML is not enough: math engines and their fonts can still be working.
    func prepareCapture(timeoutMilliseconds: Int = 15_000) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webView.callAsyncJavaScript(Self.captureReadyScript,
                arguments: ["timeoutMilliseconds": timeoutMilliseconds], in: nil, in: .page) { result in
                    continuation.resume(with: result.map { _ in () }.mapError { error in
                        let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                        return NSError(domain: "PaperShelf.WebCapture", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: message ?? error.localizedDescription])
                    })
                }
        }
    }

    static let captureReadyScript = #"""
    let timer;
    try {
      await Promise.race([
        (async () => {
          const math = window.MathJax;
          if (math?.startup?.promise) await math.startup.promise;
          if (typeof math?.whenReady === 'function') await math.whenReady(() => {});
          else if (math?.Hub?.Queue) await new Promise(resolve => math.Hub.Queue(resolve));
          if (document.fonts) await document.fonts.ready;
          await new Promise(resolve => {
            requestAnimationFrame(resolve);
            setTimeout(resolve, 50);
          });
        })(),
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error('Equations or fonts are still loading. Wait for the page to finish rendering, then save again.')), timeoutMilliseconds);
        })
      ]);
      return true;
    } finally { clearTimeout(timer); }
    """#

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
        modified: first(['dcterms.modified', 'dc.modified', 'article:modified_time']) || article.dateModified || null,
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
    @State private var showingCaptureHelp = false
    @FocusState private var findFocused: Bool
    let saved: (URL) -> Void

    init(previous: WebArticle? = nil, initialURL: URL? = nil, saved: @escaping (URL) -> Void) {
        _model = State(initialValue: WebReaderModel(previous: previous, initialURL: initialURL))
        self.saved = saved
    }

    init(model: WebReaderModel, saved: @escaping (URL) -> Void) {
        _model = State(initialValue: model)
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
                    .tip("Enter a website address, then press Return")
                Button("Go") { model.navigate() }.disabled(model.saving)
                    .tip("Open the website at this address")
                Button(model.saving ? "Saving…" : model.previous == nil ? "Save copy" : "Save new version") {
                    Task { if let url = await model.freeze() { saved(url) } }
                }
                .disabled(!model.loaded || model.loading || model.saving)
                .fixedSize()
                .help("Save the rendered page, web archive and fresh BibTeX citation. Older versions and their notes stay unchanged.")
                .accessibilityIdentifier("webReader.freeze")
            }
            .padding(Space.snug)
            if model.loaded {
                HStack(spacing: Space.snug) {
                    Label("Highlight", systemImage: "highlighter")
                        .font(.callout).foregroundStyle(.secondary).fixedSize()
                    HStack(spacing: 2) {
                        ForEach(Palette.shared.styles(for: [.library])) { style in
                            Button {
                                Task { if let url = await model.freeze(highlightColour: style.nsColor) { saved(url) } }
                            } label: {
                                Circle().fill(style.swatch).frame(width: 18, height: 18)
                                    .overlay { Circle().strokeBorder(.primary.opacity(0.15)) }
                                    .frame(width: 28, height: 28).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Save this version and highlight the selection: \(style.meaning)")
                            .accessibilityLabel("Highlight selection: \(style.meaning)")
                            .disabled(model.saving || model.loading)
                        }
                    }
                    Spacer(minLength: 0)
                    Button("About saved websites", systemImage: "info.circle") { showingCaptureHelp = true }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .frame(width: 28, height: 28)
                        .help("How highlighting, equations and saved versions work")
                        .popover(isPresented: $showingCaptureHelp) {
                            VStack(alignment: .leading, spacing: Space.step) {
                                Text("Highlight a saved version").font(.headline)
                                Text("Select text, then choose a colour. A local copy opens with your highlight, ready for notes and PDF tools.")
                                Text("Equations keep their rendered appearance. Saving waits for MathJax and fonts; image-based equations may not have selectable text.")
                                Text("Save new version captures the loaded website and refreshes its citation. Older copies keep their highlights and citations.")
                            }
                            .font(.callout).padding(Space.roomy).frame(width: 320)
                        }
                }
                .padding(.horizontal, Space.step)
                .padding(.vertical, Space.tight)
                .background(.bar)
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
                        .tip("Find the previous occurrence on this website")
                    Button("Next") { find(backwards: false) }
                        .tip("Find the next occurrence on this website")
                    if noMatch { Text("No match").foregroundStyle(.secondary) }
                    Button("Done") { showsFind = false }
                        .tip("Close website search")
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
        .task { if !model.loaded, !model.loading, !model.address.isEmpty { model.navigate() } }
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
