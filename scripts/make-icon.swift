// Renders the app icon into an .iconset folder: a monitor with a speaker centred
// on its screen, on a macOS-style rounded square.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(red: r, green: g, blue: b, alpha: a)
}

func withShadow(blur: CGFloat, offsetY: CGFloat, alpha: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(alpha)
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: offsetY)
    shadow.set()
    draw()
    NSGraphicsContext.current?.restoreGraphicsState()
}

/// Draws in a 1024×1024 coordinate space (origin bottom-left); `scale` maps it to pixels.
func drawIcon(scale: CGFloat) {
    // Background: icon-grid body (824pt) with a deep blue gradient and a glass sheen.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    withShadow(blur: 20, offsetY: -8, alpha: 0.3) {
        NSGradient(colors: [color(0.16, 0.42, 0.98), color(0.30, 0.20, 0.78)])!.draw(in: shape, angle: -90)
    }
    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [.white.withAlphaComponent(0.28), .white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.3).setStroke()
    shape.lineWidth = 6
    shape.stroke()

    // Monitor: stand, bezel and screen. Spans y 241...783, centred on the body's midline (512).
    let silver = NSGradient(colors: [color(0.97, 0.97, 0.99), color(0.80, 0.82, 0.88)])!
    withShadow(blur: 18, offsetY: -10, alpha: 0.35) {
        silver.draw(in: NSBezierPath(roundedRect: NSRect(x: 472, y: 273, width: 80, height: 90), xRadius: 8, yRadius: 8), angle: -90)
        silver.draw(in: NSBezierPath(roundedRect: NSRect(x: 372, y: 241, width: 280, height: 42), xRadius: 21, yRadius: 21), angle: -90)
        silver.draw(in: NSBezierPath(roundedRect: NSRect(x: 176, y: 353, width: 672, height: 430), xRadius: 44, yRadius: 44), angle: -90)
    }
    let screen = NSBezierPath(roundedRect: NSRect(x: 204, y: 381, width: 616, height: 374), xRadius: 22, yRadius: 22)
    NSGradient(colors: [color(0.10, 0.18, 0.42), color(0.05, 0.08, 0.22)])!.draw(in: screen, angle: -90)

    // Speaker centred on the screen (screen rect centre: 512, 568). Symbols rasterize at their point size, so draw it at pixel scale
    // rather than letting the 1024-space transform blow up a small bitmap.
    NSGraphicsContext.current?.saveGraphicsState()
    let unscale = NSAffineTransform()
    unscale.scale(by: 1 / scale)
    unscale.concat()
    let config = NSImage.SymbolConfiguration(pointSize: 190 * scale, weight: .bold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = symbol.size
        symbol.draw(in: NSRect(x: 512 * scale - s.width / 2, y: 568 * scale - s.height / 2, width: s.width, height: s.height))
    }
    NSGraphicsContext.current?.restoreGraphicsState()
}

func render(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let transform = NSAffineTransform()
    transform.scale(by: size / 1024)
    transform.concat()
    drawIcon(scale: size / 1024)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(size: CGFloat(base * factor)).write(to: output.appendingPathComponent(name))
    }
}
