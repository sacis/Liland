// Generates Liland's app icon: the menu bar flower in peach on a sage tile.
// Usage: swift scripts/make-icon.swift <output.png>  (run from the repo root)
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon.png"
let svg = NSImage(contentsOfFile: "Liland/Resources/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.svg")!

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Squircle background on the standard macOS icon grid (100px margin).
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.25).cgColor)
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.setFillColor(NSColor(srgbRed: 0x81 / 255.0, green: 0x82 / 255.0, blue: 0x63 / 255.0, alpha: 1).cgColor) // Savory sage #818263
ctx.fillPath()
ctx.restoreGState()

// The flower, in peach. The SVG's flower is centred in its 18x18 viewBox.
let flowerSize: CGFloat = 760
let flower = NSImage(size: NSSize(width: flowerSize, height: flowerSize))
flower.lockFocus()
svg.draw(in: NSRect(x: 0, y: 0, width: flowerSize, height: flowerSize))
NSColor(srgbRed: 0xEF / 255.0, green: 0xD7 / 255.0, blue: 0xCF / 255.0, alpha: 1).set() // Peach protein #EFD7CF
NSRect(x: 0, y: 0, width: flowerSize, height: flowerSize).fill(using: .sourceIn)
flower.unlockFocus()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor(srgbRed: 0x57 / 255.0, green: 0x55 / 255.0, blue: 0x27 / 255.0, alpha: 0.3).cgColor) // darker sage
flower.draw(in: NSRect(x: (size - flowerSize) / 2, y: (size - flowerSize) / 2, width: flowerSize, height: flowerSize))
ctx.restoreGState()

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
