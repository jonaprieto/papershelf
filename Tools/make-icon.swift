// Generates Resources/AppIcon.icns. Run via Tools/make-icon.sh.
// Everything is drawn on a 1024 canvas and scaled down per slice, so the shapes stay
// crisp at 16pt instead of being a blurry downsample of one big render.
import AppKit
import CoreGraphics

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])

func color(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

let plateTop = color(88, 108, 232)
let plateBottom = color(38, 44, 122)
let paper = color(252, 252, 254)
let paperEdge = color(206, 212, 230)
let fold = color(196, 205, 232)
let ruleInk = color(176, 185, 208)
let brass = color(255, 197, 61)
let brassShade = color(226, 158, 22)

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

    // Page with a folded top-right corner.
    let pageLeft: CGFloat = 286, pageRight: CGFloat = 686
    let pageBottom: CGFloat = 268, pageTop: CGFloat = 762
    let cut: CGFloat = 132
    let radius: CGFloat = 26

    let page = CGMutablePath()
    page.move(to: CGPoint(x: pageLeft, y: pageBottom + radius))
    page.addArc(tangent1End: CGPoint(x: pageLeft, y: pageTop),
                tangent2End: CGPoint(x: pageRight, y: pageTop), radius: radius)
    page.addLine(to: CGPoint(x: pageRight - cut, y: pageTop))
    page.addLine(to: CGPoint(x: pageRight, y: pageTop - cut))
    page.addArc(tangent1End: CGPoint(x: pageRight, y: pageBottom),
                tangent2End: CGPoint(x: pageLeft, y: pageBottom), radius: radius)
    page.addArc(tangent1End: CGPoint(x: pageLeft, y: pageBottom),
                tangent2End: CGPoint(x: pageLeft, y: pageTop), radius: radius)
    page.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
    ctx.addPath(page)
    ctx.setFillColor(paper)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.addPath(page)
    ctx.setStrokeColor(paperEdge)
    ctx.setLineWidth(3)
    ctx.strokePath()

    // The turned-down corner.
    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: pageRight - cut, y: pageTop))
    flap.addLine(to: CGPoint(x: pageRight - cut, y: pageTop - cut))
    flap.addLine(to: CGPoint(x: pageRight, y: pageTop - cut))
    flap.closeSubpath()
    ctx.addPath(flap)
    ctx.setFillColor(fold)
    ctx.fillPath()

    // Ruled lines standing in for the statement's text.
    ctx.setFillColor(ruleInk)
    for (index, width) in [CGFloat(250), 300, 300, 190].enumerated() {
        let y = pageTop - 226 - CGFloat(index) * 78
        ctx.addPath(CGPath(roundedRect: CGRect(x: pageLeft + 56, y: y, width: width, height: 30),
                           cornerWidth: 15, cornerHeight: 15, transform: nil))
    }
    ctx.fillPath()

    // Open padlock, overlapping the lower right corner of the page.
    let bodyRect = CGRect(x: 546, y: 200, width: 254, height: 206)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.32))

    // Shackle first, so the body covers the one leg that enters it. Only the right leg
    // reaches down; the left one stops well clear of the body, which is what makes the
    // padlock read as open rather than shut.
    let shackle = CGMutablePath()
    shackle.move(to: CGPoint(x: 762, y: 300))
    shackle.addLine(to: CGPoint(x: 762, y: 496))
    shackle.addArc(center: CGPoint(x: 674, y: 496), radius: 88,
                   startAngle: 0, endAngle: .pi, clockwise: false)
    ctx.addPath(shackle)
    ctx.setStrokeColor(brassShade)
    ctx.setLineWidth(42)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    ctx.addPath(CGPath(roundedRect: bodyRect, cornerWidth: 40, cornerHeight: 40, transform: nil))
    ctx.setFillColor(brass)
    ctx.fillPath()
    ctx.restoreGState()

    // Keyhole.
    ctx.setFillColor(plateBottom)
    ctx.addEllipse(in: CGRect(x: bodyRect.midX - 27, y: bodyRect.midY - 8, width: 54, height: 54))
    ctx.addPath(CGPath(roundedRect: CGRect(x: bodyRect.midX - 15, y: bodyRect.midY - 54,
                                           width: 30, height: 62),
                       cornerWidth: 15, cornerHeight: 15, transform: nil))
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
