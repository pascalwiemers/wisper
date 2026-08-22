// Renders the Wisper app icon (the waveform mark on a dark rounded square)
// at all required sizes and packs them into Resources/AppIcon.icns.
// Run: swift scripts/make-icon.swift
import AppKit

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconsetURL = FileManager.default.temporaryDirectory.appendingPathComponent("Wisper.iconset")
try? FileManager.default.removeItem(at: iconsetURL)
try! FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func render(_ pixels: Int, name: String) {
    let size = CGFloat(pixels)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    // macOS icon grid: content inset ~10% on each side, continuous-corner feel.
    let inset = size * 0.09
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.225
    let square = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.21, alpha: 1),
        NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1),
    ])!
    gradient.draw(in: square, angle: -90)

    // The waveform mark, teal→violet across the bars.
    let heights: [CGFloat] = [0.32, 0.62, 0.95, 0.52, 0.78, 0.38]
    let barAreaWidth = rect.width * 0.62
    let barWidth = barAreaWidth / (CGFloat(heights.count) * 1.9 - 0.9)
    let gap = barWidth * 0.9
    let maxBarHeight = rect.height * 0.52
    var x = rect.midX - barAreaWidth / 2
    let start = NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.85, alpha: 1)
    let end = NSColor(calibratedRed: 0.62, green: 0.52, blue: 0.98, alpha: 1)
    for (i, h) in heights.enumerated() {
        let t = CGFloat(i) / CGFloat(heights.count - 1)
        (start.blended(withFraction: t, of: end) ?? start).setFill()
        let barHeight = maxBarHeight * h
        let bar = NSRect(x: x, y: rect.midY - barHeight / 2, width: barWidth, height: barHeight)
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { fatalError("render failed") }
    try! png.write(to: iconsetURL.appendingPathComponent("\(name).png"))
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points)" : "icon_\(points)x\(points)@2x"
    render(points * scale, name: name)
}

let out = repoRoot.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", out.path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
