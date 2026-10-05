import AppKit

enum ArtworkColor {
    /// A vivid color from the album cover that stays readable on black.
    static func accent(for image: NSImage) -> NSColor? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let side = 16
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        var samples: [(score: CGFloat, color: NSColor)] = []
        samples.reserveCapacity(side * side)
        for offset in stride(from: 0, to: side * side * 4, by: 4) {
            let color = NSColor(
                srgbRed: CGFloat(pixels[offset]) / 255,
                green: CGFloat(pixels[offset + 1]) / 255,
                blue: CGFloat(pixels[offset + 2]) / 255,
                alpha: 1
            )
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            guard brightness > 0.2 else { continue }
            samples.append((saturation * 0.7 + brightness * 0.3, color))
        }
        guard !samples.isEmpty else { return nil }

        // Average the most vivid quarter of the cover.
        let vivid = samples.sorted { $0.score > $1.score }.prefix(max(1, samples.count / 4))
        let count = CGFloat(vivid.count)
        let red = vivid.reduce(0) { $0 + $1.color.redComponent } / count
        let green = vivid.reduce(0) { $0 + $1.color.greenComponent } / count
        let blue = vivid.reduce(0) { $0 + $1.color.blueComponent } / count

        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        // Grayscale covers get a soft white instead of a muddy gray.
        guard saturation > 0.12 else { return NSColor(white: 0.88, alpha: 1) }
        return NSColor(
            hue: hue,
            saturation: min(max(saturation, 0.4), 0.9),
            brightness: max(brightness, 0.8),
            alpha: 1
        )
    }
}
