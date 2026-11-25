import AppKit

/// The Show Applications tile's icon, drawn at build time: GNOME's app grid, nine rounded squares in white on a
/// dark squircle, with the margin every Dock icon has.
enum AppGridIcon {
    static func write(to iconset: URL) {
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] { for scale in [1, 2] {
            let pixels = points * scale, name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            draw(CGFloat(pixels))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: iconset.appendingPathComponent(name))
        } }
    }
    private static func draw(_ size: CGFloat) {
        let body = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: size * 0.1, dy: size * 0.1)
        NSColor(srgbRed: 0.22, green: 0.22, blue: 0.24, alpha: 1).setFill()
        NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225).fill()
        let cell = body.width * 0.16, gap = body.width * 0.09, start = body.midX - (cell * 3 + gap * 2) / 2
        NSColor.white.setFill()
        for row in 0..<3 { for column in 0..<3 {
            let r = CGRect(x: start + CGFloat(column) * (cell + gap), y: body.midY - (cell * 3 + gap * 2) / 2 + CGFloat(row) * (cell + gap), width: cell, height: cell)
            NSBezierPath(roundedRect: r, xRadius: cell * 0.3, yRadius: cell * 0.3).fill()
        } }
    }
}
