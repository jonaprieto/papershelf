// Generates Resources/AppIcon.icns. Run via Tools/make-icon.sh.
// Everything is drawn on a 1024 canvas and scaled down per slice, so the shapes stay
// crisp at 16pt instead of being a blurry downsample of one big render.
import AppKit
import CoreGraphics

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])

func color(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

let plateTop = color(38, 41, 48)
let plateBottom = color(11, 12, 15)
let paper = color(250, 250, 251)
let shelf = color(197, 201, 209)
let bookmark = color(255, 197, 61)

func draw(into ctx: CGContext, side: CGFloat) {
    ctx.scaleBy(x: side / 1024, y: side / 1024)
    ctx.setShouldAntialias(true)

    // Rounded plate, inset to the macOS grid.
    let plate = CGPath(roundedRect: CGRect(x: 100, y: 90, width: 824, height: 824),
                       cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [plateTop, plateBottom] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 914),
                           end: CGPoint(x: 0, y: 90), options: [])
    ctx.restoreGState()

    // The plate leaves 197 units above the books and 84 below them. Move the content
    // by half that 113-unit difference so its centre matches the plate's centre.
    ctx.translateBy(x: 0, y: 56)

    // Three spines of unequal height standing on a shelf rule, seen edge-on. They sit
    // on the shelf rather than floating above it, and the short one leans, which is what
    // keeps the row from reading as a bar chart at 16pt.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30))
    for (rect, fill) in [(CGRect(x: 287, y: 246, width: 123, height: 369), paper),
                         (CGRect(x: 430, y: 246, width: 123, height: 471), paper)] {
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 31, cornerHeight: 31, transform: nil))
        ctx.setFillColor(fill)
        ctx.fillPath()
    }

    // The leaning one, pivoted where it meets the shelf.
    let pivot = CGPoint(x: 635, y: 246)
    var tilt = CGAffineTransform(translationX: pivot.x, y: pivot.y)
        .rotated(by: -10 * .pi / 180)
        .translatedBy(x: -pivot.x, y: -pivot.y)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 573, y: 246, width: 123, height: 430),
                       cornerWidth: 31, cornerHeight: 31, transform: &tilt))
    ctx.setFillColor(bookmark)
    ctx.fillPath()
    ctx.restoreGState()

    // The shelf itself, held slightly cooler than the spines so the row reads as objects
    // sitting on a surface rather than one comb-shaped blob.
    ctx.addPath(CGPath(roundedRect: CGRect(x: 225, y: 174, width: 574, height: 72),
                       cornerWidth: 36, cornerHeight: 36, transform: nil))
    ctx.setFillColor(shelf)
    ctx.fillPath()
}

func render(side: Int) -> Data {
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(into: ctx, side: CGFloat(side))
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: side, height: side)
    return rep.representation(using: .png, properties: [:])!
}

let slices: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for (name, side) in slices {
    try render(side: side).write(to: outputDirectory.appendingPathComponent(name))
}
print("wrote \(slices.count) slices to \(outputDirectory.path)")
