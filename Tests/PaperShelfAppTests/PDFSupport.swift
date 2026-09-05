import Foundation
import PDFKit
import CoreGraphics
import CoreText
import AppKit

/// Writes a one-page PDF, optionally encrypted with `password` as both the user and
/// owner password (PDFKit requires an owner password to encrypt at all).
///
/// Copied from `Tests/PaperShelfCoreTests/TestSupport.swift`, which the app test target
/// cannot depend on without pulling in the whole core test target.
func makePDF(at url: URL, password: String?) throws {
    let raw = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 200, height: 200)
    let consumer = CGDataConsumer(data: raw)!
    let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
    ctx.fill(CGRect(x: 20, y: 20, width: 160, height: 160))
    ctx.endPDFPage()
    ctx.closePDF()

    guard let doc = PDFDocument(data: raw as Data) else {
        throw NSError(domain: "PDFSupport", code: 1)
    }
    var options: [PDFDocumentWriteOption: Any] = [:]
    if let password {
        options[.ownerPasswordOption] = password
        options[.userPasswordOption] = password
    }
    guard doc.write(to: url, withOptions: options) else {
        throw NSError(domain: "PDFSupport", code: 2)
    }
}

/// Draws one page of real, extractable text into `ctx`, at the frame rect and font that
/// `makeTextPDF` uses. Assumes the caller has already called `beginPDFPage` and will call
/// `endPDFPage`.
private func drawTextPage(in ctx: CGContext, text: String) {
    let attributed = NSAttributedString(
        string: text,
        attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black]
    )
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let frame = CTFramesetterCreateFrame(
        framesetter, CFRange(location: 0, length: 0),
        CGPath(rect: CGRect(x: 40, y: 40, width: 520, height: 700), transform: nil), nil
    )
    CTFrameDraw(frame, ctx)
}

/// Writes a PDF whose page carries real, extractable text, so content comparison has
/// something to compare.
func makeTextPDF(at url: URL, text: String, password: String? = nil) throws {
    try makeTextPDF(at: url, pages: [text], password: password)
}

/// Writes a PDF with one extractable text page for each string.
func makeTextPDF(at url: URL, pages: [String], password: String? = nil) throws {
    let raw = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(consumer: CGDataConsumer(data: raw)!, mediaBox: &box, nil)!
    for text in pages {
        ctx.beginPDFPage(nil)
        drawTextPage(in: ctx, text: text)
        ctx.endPDFPage()
    }
    ctx.closePDF()

    guard let doc = PDFDocument(data: raw as Data) else {
        throw NSError(domain: "PDFSupport", code: 3)
    }
    var options: [PDFDocumentWriteOption: Any] = [:]
    if let password {
        options[.ownerPasswordOption] = password
        options[.userPasswordOption] = password
    }
    guard doc.write(to: url, withOptions: options) else {
        throw NSError(domain: "PDFSupport", code: 4)
    }
}

/// A unique name for a scratch directory, with no digits in it.
///
/// A UUID is written in blocks separated by dashes, so one containing a block like `1974`
/// reads as a year to date-finding logic elsewhere in the app -- and the folder a fixture
/// sits in is one of the places those naming rules look for a date. Naming temp folders
/// after a raw UUID therefore fails intermittently when a block happens to look like a year.
func scratchName(_ label: String) -> String {
    "\(label)-" + UUID().uuidString.filter { !$0.isNumber }
}
