import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let p = CGFloat(pixels)
        let background = NSBezierPath(roundedRect: NSRect(x: p * 0.06, y: p * 0.06, width: p * 0.88, height: p * 0.88), xRadius: p * 0.2, yRadius: p * 0.2)
        NSColor(calibratedRed: 0.12, green: 0.2, blue: 0.3, alpha: 1).setFill()
        background.fill()
        let screen = NSBezierPath(roundedRect: NSRect(x: p * 0.22, y: p * 0.32, width: p * 0.56, height: p * 0.4), xRadius: p * 0.05, yRadius: p * 0.05)
        NSColor.white.setStroke()
        screen.lineWidth = p * 0.045
        screen.stroke()
        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: p * 0.5, y: p * 0.32))
        stand.line(to: NSPoint(x: p * 0.5, y: p * 0.23))
        stand.move(to: NSPoint(x: p * 0.37, y: p * 0.23))
        stand.line(to: NSPoint(x: p * 0.63, y: p * 0.23))
        stand.lineWidth = p * 0.045
        stand.stroke()
        NSColor.systemGreen.setFill()
        NSBezierPath(ovalIn: NSRect(x: p * 0.42, y: p * 0.44, width: p * 0.16, height: p * 0.16)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
