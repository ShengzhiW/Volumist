// Draws Volumist's app icon: the slider.vertical.3 symbol in a sky-blue-to-turquoise gradient
// on very dark gray dots over an even darker gray, in a macOS-style rounded square.
//
//   swift scripts/make-icon.swift [output-folder]
//
// Writes every size the asset catalog needs (icon_16x16.png ... icon_512x512@2x.png), by
// default into Volumist/Assets.xcassets/AppIcon.appiconset.
import AppKit

let canvas: CGFloat = 1024
// Apple's macOS icon grid: an 824 pt body centered on the 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185

let background = NSColor(srgbRed: 0.075, green: 0.075, blue: 0.082, alpha: 1)   // #131315
let dotColor = NSColor(srgbRed: 0.165, green: 0.165, blue: 0.180, alpha: 1)     // #2A2A2E
let dotSpacing: CGFloat = 64
let dotDiameter: CGFloat = 38
let glyphTop = NSColor(srgbRed: 0.33, green: 0.76, blue: 1.00, alpha: 1)       // sky blue
let glyphBottom = NSColor(srgbRed: 0.18, green: 0.86, blue: 0.78, alpha: 1)    // turquoise

func drawIcon() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    let shape = NSBezierPath(roundedRect: body, xRadius: cornerRadius, yRadius: cornerRadius)

    // Soft shadow under the body, like system icons.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
    background.setFill()
    shape.fill()
    context.restoreGState()

    // Dots: offset every other row, as in a polka-dot pattern.
    context.saveGState()
    shape.addClip()
    background.setFill()
    shape.fill()
    dotColor.setFill()
    var row = 0
    var y = body.minY - dotSpacing / 2
    while y < body.maxY + dotSpacing {
        var x = body.minX - dotSpacing + (row.isMultiple(of: 2) ? 0 : dotSpacing / 2)
        while x < body.maxX + dotSpacing {
            NSBezierPath(ovalIn: CGRect(x: x - dotDiameter / 2, y: y - dotDiameter / 2,
                                        width: dotDiameter, height: dotDiameter)).fill()
            x += dotSpacing
        }
        y += dotSpacing * 0.866  // rows packed like a hexagonal grid
        row += 1
    }
    context.restoreGState()

    // The glyph, filled with the gradient through its own shape.
    let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .semibold)
    guard let symbol = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { fatalError("missing symbol") }
    let size = symbol.size
    let glyphRect = CGRect(x: (canvas - size.width) / 2, y: (canvas - size.height) / 2,
                           width: size.width, height: size.height)
    var proposed = glyphRect
    guard let mask = symbol.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { fatalError("no mask") }
    context.saveGState()
    context.clip(to: glyphRect, mask: mask)
    let gradient = NSGradient(starting: glyphTop, ending: glyphBottom)!
    gradient.draw(in: glyphRect, angle: -90)
    context.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func resized(_ rep: NSBitmapImageRep, to pixels: Int) -> Data {
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSGraphicsContext.current!.imageInterpolation = .high
    rep.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return out.representation(using: .png, properties: [:])!
}

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1] : "Volumist/Assets.xcassets/AppIcon.appiconset")
let icon = drawIcon()
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try resized(icon, to: points * scale).write(to: folder.appendingPathComponent(name))
    }
}
print("Wrote icons to \(folder.path)")
