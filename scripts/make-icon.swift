// Generates Liland's app icon: a black island with artwork and equalizer on a gradient.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Squircle background on the standard macOS icon grid (100px margin).
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(tilePath)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: [
        NSColor(srgbRed: 1.00, green: 0.42, blue: 0.47, alpha: 1).cgColor,
        NSColor(srgbRed: 0.55, green: 0.27, blue: 0.93, alpha: 1).cgColor,
        NSColor(srgbRed: 0.16, green: 0.12, blue: 0.42, alpha: 1).cgColor,
    ] as CFArray,
    locations: [0, 0.55, 1]
)!
ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
ctx.restoreGState()

// The island.
let pill = CGRect(x: 222, y: 452, width: 580, height: 160)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: NSColor.black.withAlphaComponent(0.45).cgColor)
ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 80, cornerHeight: 80, transform: nil))
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

// Album artwork.
let art = CGRect(x: 268, y: 482, width: 100, height: 100)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: art, cornerWidth: 26, cornerHeight: 26, transform: nil))
ctx.clip()
let artGradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: [
        NSColor(srgbRed: 1.0, green: 0.78, blue: 0.30, alpha: 1).cgColor,
        NSColor(srgbRed: 1.0, green: 0.38, blue: 0.40, alpha: 1).cgColor,
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(artGradient, start: CGPoint(x: art.minX, y: art.maxY), end: CGPoint(x: art.maxX, y: art.minY), options: [])
ctx.restoreGState()

// Equalizer bars.
let green = NSColor(srgbRed: 0.12, green: 0.84, blue: 0.38, alpha: 1).cgColor
let heights: [CGFloat] = [52, 96, 70, 108]
for (index, height) in heights.enumerated() {
    let bar = CGRect(x: 630 + CGFloat(index) * 34, y: pill.midY - height / 2, width: 20, height: height)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 10, cornerHeight: 10, transform: nil))
    ctx.setFillColor(green)
    ctx.fillPath()
}

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
