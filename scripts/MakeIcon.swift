import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func render(_ size: Int, name: String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let base = NSBezierPath(roundedRect: NSRect(x: 38, y: 38, width: 948, height: 948), xRadius: 222, yRadius: 222)
    NSGradient(starting: NSColor(calibratedRed: 0.05, green: 0.16, blue: 0.23, alpha: 1), ending: NSColor(calibratedRed: 0.04, green: 0.36, blue: 0.37, alpha: 1))!.draw(in: base, angle: 45)
    NSColor.white.withAlphaComponent(0.15).setStroke(); base.lineWidth = 4; base.stroke()
    let center = NSPoint(x: 512, y: 520)
    let colors: [NSColor] = [NSColor(calibratedRed: 0.38, green: 0.86, blue: 0.76, alpha: 1), NSColor(calibratedRed: 0.48, green: 0.54, blue: 0.96, alpha: 1), NSColor(calibratedRed: 0.94, green: 0.66, blue: 0.48, alpha: 1)]
    let ranges: [(CGFloat, CGFloat)] = [(94, 244), (252, 353), (1, 86)]
    for (i, range) in ranges.enumerated() {
        let wedge = NSBezierPath(); wedge.move(to: center)
        wedge.appendArc(withCenter: center, radius: 305, startAngle: range.0, endAngle: range.1)
        wedge.close(); colors[i].setFill(); wedge.fill()
    }
    colors[0].setFill()
    for points in [[NSPoint(x: 218, y: 650), NSPoint(x: 440, y: 570), NSPoint(x: 365, y: 440)],
                   [NSPoint(x: 806, y: 650), NSPoint(x: 584, y: 570), NSPoint(x: 659, y: 440)]] {
        let ear = NSBezierPath(); ear.move(to: points[0]); ear.line(to: points[1]); ear.line(to: points[2]); ear.close(); ear.fill()
    }
    NSColor(calibratedRed: 0.06, green: 0.24, blue: 0.28, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 340, y: 348, width: 344, height: 344)).fill()
    NSColor.white.withAlphaComponent(0.92).setFill()
    NSBezierPath(roundedRect: NSRect(x: 451, y: 489, width: 30, height: 66), xRadius: 15, yRadius: 15).fill()
    NSBezierPath(roundedRect: NSRect(x: 543, y: 489, width: 30, height: 66), xRadius: 15, yRadius: 15).fill()
    NSColor.white.withAlphaComponent(0.85).setStroke()
    let grin = NSBezierPath(); grin.move(to: NSPoint(x: 479, y: 440)); grin.line(to: NSPoint(x: 548, y: 454)); grin.lineWidth = 9; grin.lineCapStyle = .round; grin.stroke()
    NSColor.white.withAlphaComponent(0.28).setFill()
    NSBezierPath(roundedRect: NSRect(x: 342, y: 135, width: 340, height: 18), xRadius: 9, yRadius: 9).fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
for size in [16, 32, 128, 256, 512] {
    try render(size, name: "icon_\(size)x\(size).png")
    try render(size * 2, name: "icon_\(size)x\(size)@2x.png")
}
