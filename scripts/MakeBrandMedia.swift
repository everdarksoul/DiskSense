import AppKit
import Foundation

// Original, code-drawn artwork. No screenshots or user data are used here.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let out = root.appendingPathComponent("docs/media")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let width = 1200, height = 630
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let background = NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height))
NSGradient(starting: NSColor(calibratedRed: 0.035, green: 0.065, blue: 0.10, alpha: 1), ending: NSColor(calibratedRed: 0.05, green: 0.21, blue: 0.23, alpha: 1))!.draw(in: background, angle: 25)
let mint = NSColor(calibratedRed: 0.38, green: 0.86, blue: 0.76, alpha: 1)
for radius in [220.0, 270.0, 320.0] {
    mint.withAlphaComponent(0.075).setStroke()
    let orbit = NSBezierPath(ovalIn: NSRect(x: 960-radius, y: 315-radius, width: radius*2, height: radius*2))
    orbit.lineWidth = 2; orbit.stroke()
}
func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
    (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
}
text("A LITTLE GOBLIN. A LOT LESS CLUTTER.", x: 68, y: 515, size: 14, color: mint, weight: .semibold)
text("LintGoblin", x: 64, y: 403, size: 80, color: .white, weight: .bold)
text("Your apps moved out.", x: 68, y: 328, size: 31, color: .white, weight: .medium)
text("Their crumbs didn’t.", x: 68, y: 283, size: 31, color: mint, weight: .medium)
text("Mac app cleaner + disk space analyzer", x: 68, y: 207, size: 22, color: .white.withAlphaComponent(0.72))
text("OPEN SOURCE  /  LOCAL ANALYSIS  /  YOUR CALL", x: 68, y: 93, size: 14, color: .white.withAlphaComponent(0.55), weight: .medium)
let iconURL = root.appendingPathComponent(".build/Distribution/DiskSense.iconset/icon_512x512@2x.png")
guard let icon = NSImage(contentsOf: iconURL) else { fatalError("Run scripts/build-app.sh first") }
icon.draw(in: NSRect(x: 760, y: 120, width: 400, height: 400))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("banner.png"))
try Data(contentsOf: iconURL).write(to: out.appendingPathComponent("icon.png"))
print("Created docs/media/banner.png and icon.png")
