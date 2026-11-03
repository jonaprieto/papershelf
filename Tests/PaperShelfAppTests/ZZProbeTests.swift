import XCTest
import PDFKit
@testable import PaperShelf

@MainActor
final class ZZProbeTests: XCTestCase {
    func testProbe() throws {
        if ProcessInfo.processInfo.environment["LEGACY"] != nil {
            UserDefaults.standard.setVolatileDomain(["AppleShowScrollBars": "Always"], forName: UserDefaults.argumentDomain)
            NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        }
        print("PROBE style=\(NSScroller.preferredScrollerStyle == .legacy ? "legacy" : "overlay")")
        let document = PDFDocument()
        for index in 0..<3 {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 364, height: 273), for: .mediaBox)
            document.insert(page, at: index)
        }
        let view = FitWidthPDFView(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        view.autoScales = false
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 8
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageBreakMargins = view.pageInsets
        if ProcessInfo.processInfo.environment["LEGACY"] != nil {
            (view.subviews.first { $0 is NSScrollView } as? NSScrollView)?.scrollerStyle = .legacy
        }
        view.document = document
        view.requestFit(.width)
        view.layout()
        view.layoutDocumentView()
        let sv = view.documentView!.enclosingScrollView!
        let page = document.page(at: 0)!
        print("PROBE scale=\(view.scaleFactor) content=\(sv.contentSize) clip=\(sv.contentView.bounds) doc=\(view.documentView!.frame) vScroller=\(sv.hasVerticalScroller) style=\(sv.scrollerStyle == .legacy ? "legacy" : "overlay") margins=\(view.pageBreakMargins.left) minX=\(view.convert(page.bounds(for: .mediaBox), from: page).minX)")

        let d2 = PDFDocument()
        for index in 0..<3 { d2.insert(PDFPage(), at: index) }
        print("PROBE emptyPageBounds=\(d2.page(at: 0)!.bounds(for: .mediaBox))")
        let v2 = FitWidthPDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        v2.document = d2
        print("PROBE vim before doc=\(String(describing: v2.documentView?.frame)) sv=\(String(describing: v2.documentView?.enclosingScrollView)) page=\(v2.currentPage.map { d2.index(for: $0) } ?? -1)")
        v2.go(to: d2.page(at: 0)!)
        for i in 0..<200 {
            v2.scroll(by: .down)
            if i < 3 || i == 199 { print("PROBE vim step\(i) clip=\(v2.documentView!.enclosingScrollView!.contentView.bounds) page=\(v2.currentPage.map { d2.index(for: $0) } ?? -1)") }
        }
        print("PROBE vim page=\(v2.currentPage.map { d2.index(for: $0) } ?? -1) scale=\(v2.scaleFactor) doc=\(v2.documentView!.frame) clip=\(v2.documentView!.enclosingScrollView!.contentView.bounds)")
    }
}
