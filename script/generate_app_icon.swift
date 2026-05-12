#!/usr/bin/env swift

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("Usage: generate_app_icon.swift <base.icns> <output.icns>\n", stderr)
    exit(64)
}

let baseURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])
let fileManager = FileManager.default

guard let baseImage = NSImage(contentsOf: baseURL) else {
    fputs("Cannot read base icon: \(baseURL.path)\n", stderr)
    exit(66)
}

let iconsetURL = outputURL
    .deletingLastPathComponent()
    .appendingPathComponent("AppIcon.iconset")
try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(
    at: iconsetURL,
    withIntermediateDirectories: true
)

let iconSpecs: [(name: String, size: CGFloat, scale: CGFloat)] = [
    ("icon_16x16.png", 16, 1),
    ("icon_16x16@2x.png", 16, 2),
    ("icon_32x32.png", 32, 1),
    ("icon_32x32@2x.png", 32, 2),
    ("icon_128x128.png", 128, 1),
    ("icon_128x128@2x.png", 128, 2),
    ("icon_256x256.png", 256, 1),
    ("icon_256x256@2x.png", 256, 2),
    ("icon_512x512.png", 512, 1),
    ("icon_512x512@2x.png", 512, 2)
]

func drawSwitchBadge(in rect: NSRect) {
    let badgeSize = rect.width * 0.43
    let badgeRect = NSRect(
        x: rect.maxX - badgeSize - rect.width * 0.045,
        y: rect.minY + rect.height * 0.045,
        width: badgeSize,
        height: badgeSize
    )

    NSColor(calibratedWhite: 1, alpha: 0.95).setFill()
    NSBezierPath(ovalIn: badgeRect.insetBy(dx: -badgeSize * 0.05, dy: -badgeSize * 0.05)).fill()

    NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.95, alpha: 1).setFill()
    NSBezierPath(ovalIn: badgeRect).fill()

    NSColor.white.setStroke()
    let lineWidth = max(2, badgeSize * 0.075)

    let upper = NSBezierPath()
    upper.lineWidth = lineWidth
    upper.lineCapStyle = .round
    upper.lineJoinStyle = .round
    upper.move(to: NSPoint(x: badgeRect.minX + badgeSize * 0.26, y: badgeRect.midY + badgeSize * 0.13))
    upper.line(to: NSPoint(x: badgeRect.maxX - badgeSize * 0.24, y: badgeRect.midY + badgeSize * 0.13))
    upper.line(to: NSPoint(x: badgeRect.maxX - badgeSize * 0.38, y: badgeRect.midY + badgeSize * 0.27))
    upper.move(to: NSPoint(x: badgeRect.maxX - badgeSize * 0.24, y: badgeRect.midY + badgeSize * 0.13))
    upper.line(to: NSPoint(x: badgeRect.maxX - badgeSize * 0.38, y: badgeRect.midY - badgeSize * 0.01))
    upper.stroke()

    let lower = NSBezierPath()
    lower.lineWidth = lineWidth
    lower.lineCapStyle = .round
    lower.lineJoinStyle = .round
    lower.move(to: NSPoint(x: badgeRect.maxX - badgeSize * 0.26, y: badgeRect.midY - badgeSize * 0.16))
    lower.line(to: NSPoint(x: badgeRect.minX + badgeSize * 0.24, y: badgeRect.midY - badgeSize * 0.16))
    lower.line(to: NSPoint(x: badgeRect.minX + badgeSize * 0.38, y: badgeRect.midY - badgeSize * 0.30))
    lower.move(to: NSPoint(x: badgeRect.minX + badgeSize * 0.24, y: badgeRect.midY - badgeSize * 0.16))
    lower.line(to: NSPoint(x: badgeRect.minX + badgeSize * 0.38, y: badgeRect.midY - badgeSize * 0.02))
    lower.stroke()
}

func makeIcon(size: CGFloat, scale: CGFloat) throws -> Data {
    let pixelSize = Int(size * scale)
    let image = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    let rect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
    baseImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    drawSwitchBadge(in: rect)
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGeneration", code: 1)
    }
    return png
}

for spec in iconSpecs {
    let data = try makeIcon(size: spec.size, scale: spec.scale)
    let targetURL = iconsetURL.appendingPathComponent(spec.name)
    try data.write(to: targetURL)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
    "-c", "icns",
    iconsetURL.path,
    "-o", outputURL.path
]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    fputs("iconutil failed with status \(process.terminationStatus)\n", stderr)
    exit(process.terminationStatus)
}

try? fileManager.removeItem(at: iconsetURL)
