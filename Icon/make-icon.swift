// Draws the app icon: a dark squircle with a frosted-glass pill holding three ring gauges and a pulse line.
// Usage: swift Icon/make-icon.swift Icon/AppIcon.icns   (needs iconutil, part of macOS)
import AppKit

func draw(size s: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = s / 1024

    // Squircle background (macOS grid: 824 pt body inside a 1024 canvas).
    let body = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * k, yRadius: 185 * k)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * k
    shadow.shadowOffset = NSSize(width: 0, height: -10 * k)
    shadow.set()
    NSColor.black.setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [NSColor(red: 0.07, green: 0.09, blue: 0.20, alpha: 1),
                        NSColor(red: 0.10, green: 0.22, blue: 0.42, alpha: 1),
                        NSColor(red: 0.05, green: 0.42, blue: 0.52, alpha: 1)])!
        .draw(in: body, angle: 60)
    // Soft colour glows behind the glass.
    for (color, x, y, r) in [(NSColor.systemPink, 300.0, 700.0, 300.0), (NSColor.systemTeal, 760.0, 300.0, 340.0)] {
        let glow = NSGradient(starting: color.withAlphaComponent(0.55), ending: color.withAlphaComponent(0))!
        glow.draw(fromCenter: NSPoint(x: x * k, y: y * k), radius: 0,
                  toCenter: NSPoint(x: x * k, y: y * k), radius: r * k, options: [])
    }

    // Pulse line across the lower part.
    let pulse = NSBezierPath()
    let points: [(Double, Double)] = [(100, 300), (330, 300), (380, 230), (440, 400), (500, 180), (560, 330),
                                      (610, 300), (924, 300)]
    pulse.move(to: NSPoint(x: points[0].0 * k, y: points[0].1 * k))
    for p in points.dropFirst() { pulse.line(to: NSPoint(x: p.0 * k, y: p.1 * k)) }
    pulse.lineWidth = 16 * k
    pulse.lineJoinStyle = .round
    pulse.lineCapStyle = .round
    NSColor(red: 0.45, green: 0.95, blue: 0.75, alpha: 0.55).setStroke()
    pulse.stroke()

    // Frosted glass pill.
    let pill = NSRect(x: 170 * k, y: 470 * k, width: 684 * k, height: 230 * k)
    let pillPath = NSBezierPath(roundedRect: pill, xRadius: 115 * k, yRadius: 115 * k)
    NSGradient(starting: NSColor.white.withAlphaComponent(0.30), ending: NSColor.white.withAlphaComponent(0.10))!
        .draw(in: pillPath, angle: -90)
    NSColor.white.withAlphaComponent(0.55).setStroke()
    pillPath.lineWidth = 5 * k
    pillPath.stroke()
    // Three ring gauges: CPU (green), RAM (orange), disk (blue).
    let rings: [(NSColor, CGFloat)] = [(.systemGreen, 0.72), (.systemOrange, 0.55), (.systemCyan, 0.85)]
    for (i, ring) in rings.enumerated() {
        let center = NSPoint(x: (300 + CGFloat(i) * 212) * k, y: pill.midY)
        let radius = 66 * k
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 26 * k
        NSColor.white.withAlphaComponent(0.18).setStroke()
        track.stroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * ring.1, clockwise: true)
        arc.lineWidth = 26 * k
        arc.lineCapStyle = .round
        ring.0.setStroke()
        arc.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()

    // Thin inner edge on the squircle.
    NSColor.white.withAlphaComponent(0.18).setStroke()
    let edge = NSBezierPath(roundedRect: body.insetBy(dx: 2 * k, dy: 2 * k), xRadius: 183 * k, yRadius: 183 * k)
    edge.lineWidth = 4 * k
    edge.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = draw(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! png.write(to: iconset.appendingPathComponent(name))
    }
}
try! draw(size: 1024).representation(using: .png, properties: [:])!
    .write(to: output.deletingPathExtension().appendingPathExtension("png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
