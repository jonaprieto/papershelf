import AppKit
import SwiftUI
import PaperShelfCore

// A mechanical check on the reading-projects views this agent cannot otherwise see: each
// one, at several widths a real sidebar or window could plausibly be, must lay out to real,
// finite, sanely-sized rows — not zero, not NaN, not a runaway height (this app has had
// that exact bug before: see the "panes that stay in their own column" commit).
//
// Not part of `swift test`: SwiftUI layout wants a live NSApplication, which the test
// bundle does not run under, so this starts one just long enough to host each view.
//
// `List`'s own `NSHostingView.fittingSize` reports 0 no matter what it holds, confirmed by
// walking and printing its AppKit subview tree: on macOS a List is backed by an
// NSTableView/NSScrollView that sizes to fill whatever frame it is given rather than
// hugging its content, the same as a bare ScrollView. The rows inside are real once the
// window is actually ordered on screen, so this measures those directly instead.
//
// Building against a stub `ProjectsEnvironment` rather than the live one, the same way
// Tests/PaperShelfAppTests/ProjectsViewTests.swift does: no database, no network, and it
// only needs this file plus PaperShelfCore and Sources/PaperShelf/Projects.swift, so it stays
// inside what this agent actually changed.

// Projects.swift's own `.tip(_:key:)` lives in Tooltips.swift, which drags in `Decision`
// (Shell.swift) and the rest of that dependency chain. It is a plain `.help(...)` wrapper
// with no effect on layout, so a same-signature shim here is enough for a size check and
// keeps this compilation to exactly the files this agent changed plus PaperShelfCore.
extension View {
    func tip(_ what: String, key: String? = nil) -> some View {
        help(key.map { "\(what)  (\($0))" } ?? what)
    }
}

func heading(_ text: String) { print("\n=== \(text)") }
var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "ok   " : "FAIL ") + label + (detail.isEmpty ? "" : "  [\(detail)]"))
    if !ok { failures += 1 }
}

/// Hosts `view` at a fixed `width` in a real, on-screen (if far off the visible desktop)
/// window and forces a layout pass, so AppKit-backed content — `List` chief among them —
/// actually computes row geometry instead of deferring it indefinitely.
@MainActor
func hostAndLayout(_ view: some View, width: CGFloat) -> NSHostingView<some View> {
    let hosting = NSHostingView(rootView: view.frame(width: width))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = hosting
    // Far off the visible desktop, never actually seen, but still "on screen" as far as
    // AppKit's own layout and table-view virtualization are concerned.
    window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    window.orderFrontRegardless()
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    hosting.layoutSubtreeIfNeeded()
    return hosting
}

func collect(_ view: NSView, matchingPrefix prefix: String, into out: inout [NSView]) {
    if "\(type(of: view))".hasPrefix(prefix) { out.append(view) }
    for sub in view.subviews { collect(sub, matchingPrefix: prefix, into: &out) }
}

func subtreeContains(_ view: NSView, typeNameContains fragment: String) -> Bool {
    if "\(type(of: view))".contains(fragment) { return true }
    return view.subviews.contains { subtreeContains($0, typeNameContains: fragment) }
}

struct ListMetrics {
    let rowCount: Int
    let headerCount: Int
    let rowHeights: [CGFloat]
    var documentRowCount: Int { rowCount - headerCount }
}

/// Measures a `List`-based view by walking its real AppKit row views, since `fittingSize`
/// on the view itself cannot be trusted for `List` (see the file-level comment).
@MainActor
func listMetrics(_ view: some View, width: CGFloat) -> ListMetrics {
    let hosting = hostAndLayout(view, width: width)
    var rows: [NSView] = []
    collect(hosting, matchingPrefix: "ListTableRowView", into: &rows)
    let headers = rows.filter { subtreeContains($0, typeNameContains: "HeaderForSectionModifier") }
    return ListMetrics(rowCount: rows.count, headerCount: headers.count, rowHeights: rows.map(\.frame.height))
}

/// For the non-`List` views (the conversation screen is a plain `ScrollView`/`LazyVStack`),
/// where `fittingSize` behaves the way it does for ordinary stacks.
@MainActor
func fittedHeight(_ view: some View, width: CGFloat) -> CGFloat {
    hostAndLayout(view, width: width).fittingSize.height
}

@MainActor
func checkListMetrics(_ label: String, _ view: some View, width: CGFloat,
                      expectedRows: Int, expectedHeaders: Int) {
    let metrics = listMetrics(view, width: width)
    check("\(label) at width \(Int(width)): \(expectedRows) row(s)",
         metrics.rowCount == expectedRows, "got \(metrics.rowCount)")
    check("\(label) at width \(Int(width)): \(expectedHeaders) header(s)",
         metrics.headerCount == expectedHeaders, "got \(metrics.headerCount)")
    let sane = metrics.rowHeights.allSatisfy { $0.isFinite && $0 > 0 && $0 < 400 }
    check("\(label) at width \(Int(width)): every row height is finite and sane (0, 400)",
         sane, "\(metrics.rowHeights)")
}

func stubEnvironment(members: [Int64: [ProjectMember]] = [:],
                     projects: [ProjectSummary] = []) -> ProjectsEnvironment {
    ProjectsEnvironment(
        listProjects: { projects },
        createProject: { name in ProjectSummary(id: 1, name: name, documentCount: 0) },
        deleteProject: { _ in },
        members: { id in members[id] ?? [] },
        availableDocuments: { _ in [] },
        sections: { id in
            Array(Set((members[id] ?? []).compactMap(\.section))).sorted()
        },
        setSection: { _, _, _ in },
        removeMember: { _, _ in },
        tags: { _ in [] },
        addTag: { _, _ in },
        removeTag: { _, _ in },
        rankedDocuments: { _, hashes in hashes },
        ask: { _, _ in "An answer, cited (Some Paper, p. 3)." },
        endpoint: { "https://api.openai.com/v1" },
        openAtPage: { _, _ in }
    )
}

func member(_ hash: String, title: String, author: String? = nil, pageCount: Int? = nil,
           section: String? = nil) -> ProjectMember {
    ProjectMember(document: ProjectDocument(contentHash: hash, title: title, markdown: ""),
                 author: author, pageCount: pageCount, section: section)
}

let widths: [CGFloat] = [280, 420, 720, 1100]

// Top-level code in a plain command-line tool is not implicitly @MainActor-isolated, but
// it does run on the main thread; `assumeIsolated` asserts exactly that so the rest of this
// script can call the MainActor-isolated layout code synchronously.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    heading("ProjectsListView, empty")
    for width in widths {
        checkListMetrics("empty list", ProjectsListView(env: stubEnvironment()), width: width,
                         expectedRows: 1, expectedHeaders: 0)
    }

    heading("ProjectsListView, several projects")
    do {
        let env = stubEnvironment(projects: (1...8).map {
            ProjectSummary(id: Int64($0), name: "Project \($0)", documentCount: $0 * 3)
        })
        for width in widths {
            checkListMetrics("8 projects", ProjectsListView(env: env), width: width,
                             expectedRows: 8, expectedHeaders: 0)
        }
    }

    heading("ProjectDetailView, grouped members with long titles and tags")
    do {
        let project = ProjectSummary(id: 1, name: "Thesis Reading", documentCount: 5)
        // Four groups (three named, one unfiled), five documents: nine rows expected,
        // four of them section headers.
        let members: [ProjectMember] = [
            member("a", title: "A Very Long Title That Should Wrap Or Truncate Reasonably On A Narrow Sidebar",
                  author: "Jane Q. Researcher", pageCount: 214, section: "background"),
            member("b", title: "Second Background Paper", author: "A. Author", pageCount: 12, section: "background"),
            member("c", title: "To Read Later", pageCount: 40, section: "to read"),
            member("d", title: "Cited By Chapter 3", author: "Someone Else", section: "cited by chapter 3"),
            member("e", title: "Not Filed Anywhere Yet"),
        ]
        let env = stubEnvironment(members: [1: members])
        for width in widths {
            checkListMetrics("grouped members", ProjectDetailView(project: project, env: env), width: width,
                             expectedRows: 9, expectedHeaders: 4)
        }
    }

    heading("ProjectDetailView, empty project")
    do {
        let project = ProjectSummary(id: 2, name: "Empty Project", documentCount: 0)
        let env = stubEnvironment(members: [2: []])
        for width in widths {
            checkListMetrics("empty project", ProjectDetailView(project: project, env: env), width: width,
                             expectedRows: 2, expectedHeaders: 1)
        }
    }

    heading("ProjectConversationView, with a turn and citations")
    do {
        let project = ProjectSummary(id: 3, name: "Conversation Project", documentCount: 1)
        let docs = [ProjectDocument(contentHash: "a", title: "Some Paper",
                                    markdown: "<!-- page:3 -->\nSome text about the question.")]
        let env = stubEnvironment()
        for width in widths {
            let height = fittedHeight(ProjectConversationView(project: project, documents: docs, env: env), width: width)
            check("conversation at width \(Int(width)) settles to a finite, positive height",
                 height.isFinite && height > 0, "\(height)")
        }
    }
}

print("\n\(failures == 0 ? "all good" : "\(failures) FAILURES")")
exit(failures == 0 ? 0 : 1)
