import PDFKit
import AppKit

/// One native annotation per page, shared by PDF selections and captured web selections.
@discardableResult
public func addPDFHighlights(for selection: PDFSelection, colour: NSColor, note: String = "") -> [PDFAnnotation] {
    selection.pages.compactMap { page in
        let lines = selection.selectionsByLine().filter { $0.pages.contains(page) }
            .map { $0.bounds(for: page) }.filter { $0.width > 0 && $0.height > 0 }
        guard let first = lines.first else { return nil }
        let union = lines.dropFirst().reduce(first) { $0.union($1) }
        let mark = PDFAnnotation(bounds: union, forType: .highlight, withProperties: nil)
        mark.color = colour
        mark.modificationDate = Date()
        if !note.isEmpty { mark.contents = note }
        mark.quadrilateralPoints = lines.flatMap { line -> [NSValue] in
            let box = line.offsetBy(dx: -union.minX, dy: -union.minY)
            return [NSValue(point: NSPoint(x: box.minX, y: box.maxY)),
                    NSValue(point: NSPoint(x: box.maxX, y: box.maxY)),
                    NSValue(point: NSPoint(x: box.minX, y: box.minY)),
                    NSValue(point: NSPoint(x: box.maxX, y: box.minY))]
        }
        page.addAnnotation(mark)
        return mark
    }
}
