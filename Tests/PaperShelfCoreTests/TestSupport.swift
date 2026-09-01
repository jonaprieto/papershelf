import Foundation
import PDFKit
import CoreGraphics
import CoreText
import AppKit

/// Writes a one-page PDF, optionally encrypted with `password` as both the user and
/// owner password (PDFKit requires an owner password to encrypt at all).
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
        throw NSError(domain: "TestSupport", code: 1)
    }
    var options: [PDFDocumentWriteOption: Any] = [:]
    if let password {
        options[.ownerPasswordOption] = password
        options[.userPasswordOption] = password
    }
    guard doc.write(to: url, withOptions: options) else {
        throw NSError(domain: "TestSupport", code: 2)
    }
}

func loadPDF(_ url: URL) -> PDFDocument? {
    PDFDocument(url: url)
}

/// Draws one page of real, extractable text into `ctx`, at the frame rect and font that
/// `makeTextPDF` and the text pages of `makeMixedPDF` share. Assumes the caller has already
/// called `beginPDFPage` and will call `endPDFPage`.
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

/// Draws one blank, textless page into `ctx`: a filled rect at the size that `makeScratchPDF`
/// and the blank pages of `makeMixedPDF` share. Assumes the caller has already called
/// `beginPDFPage` and will call `endPDFPage`.
private func drawBlankPage(in ctx: CGContext) {
    ctx.setFillColor(CGColor(gray: 0.6, alpha: 1))
    ctx.fill(CGRect(x: 40, y: 40, width: 500, height: 700))
}

/// Writes a PDF whose pages carry real, extractable text, so content comparison has
/// something to compare.
func makeTextPDF(at url: URL, text: String, password: String? = nil) throws {
    let raw = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(consumer: CGDataConsumer(data: raw)!, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    drawTextPage(in: ctx, text: text)
    ctx.endPDFPage()
    ctx.closePDF()

    guard let doc = PDFDocument(data: raw as Data) else {
        throw NSError(domain: "TestSupport", code: 3)
    }
    var options: [PDFDocumentWriteOption: Any] = [:]
    if let password {
        options[.ownerPasswordOption] = password
        options[.userPasswordOption] = password
    }
    guard doc.write(to: url, withOptions: options) else {
        throw NSError(domain: "TestSupport", code: 4)
    }
}

/// A throwaway PDF on disk, for tests that need to build a document up before writing it.
func makeScratchPDF(pages: Int = 1) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("scratch-\(UUID().uuidString).pdf")
    let raw = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(consumer: CGDataConsumer(data: raw)!, mediaBox: &box, nil)!
    for _ in 0..<pages {
        ctx.beginPDFPage(nil)
        drawBlankPage(in: ctx)
        ctx.endPDFPage()
    }
    ctx.closePDF()
    try (raw as Data).write(to: url)
    return url
}

/// Writes a multi-page PDF where each page's text is chosen independently: `nil` draws a
/// filled rect with no text, using the same body as `makeScratchPDF`, and a string draws
/// real, extractable text, using the same body as `makeTextPDF`. This is what lets a test
/// put a blank page ahead of a page that has text, which neither of those on its own can
/// produce.
func makeMixedPDF(at url: URL, pageTexts: [String?], password: String? = nil) throws {
    let raw = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(consumer: CGDataConsumer(data: raw)!, mediaBox: &box, nil)!
    for text in pageTexts {
        ctx.beginPDFPage(nil)
        if let text {
            drawTextPage(in: ctx, text: text)
        } else {
            drawBlankPage(in: ctx)
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()

    guard let doc = PDFDocument(data: raw as Data) else {
        throw NSError(domain: "TestSupport", code: 5)
    }
    var options: [PDFDocumentWriteOption: Any] = [:]
    if let password {
        options[.ownerPasswordOption] = password
        options[.userPasswordOption] = password
    }
    guard doc.write(to: url, withOptions: options) else {
        throw NSError(domain: "TestSupport", code: 6)
    }
}

/// A unique name for a scratch directory, with no digits in it.
///
/// A UUID is written in blocks separated by dashes, so one containing a block like `1974`
/// reads as a year to `findDate` -- and the folder a fixture sits in is one of the places
/// the naming rules look for a date. Naming temp folders after a raw UUID therefore failed
/// about one run in a hundred, which is what took down a release build: a test asserting
/// `bus-oslo-airport.pdf` got `1974-bus-oslo-airport.pdf` because the folder it made the
/// file in happened to be called `pdfnorm-...-1974-...`.
func scratchName(_ label: String) -> String {
    "\(label)-" + UUID().uuidString.filter { !$0.isNumber }
}
