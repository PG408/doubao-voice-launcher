#!/usr/bin/env swift

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("Usage: generate_app_icon.swift <output.icns>\n", stderr)
    exit(64)
}

let outputURL = URL(fileURLWithPath: arguments[1])
let fileManager = FileManager.default
let iconsetURL = outputURL
    .deletingLastPathComponent()
    .appendingPathComponent("AppIcon.iconset")

try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

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

func roundedRectPath(in rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawGradientBackground(in rect: NSRect) {
    let colors = [
        NSColor(calibratedRed: 0.08, green: 0.29, blue: 0.72, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.56, blue: 0.92, alpha: 1)
    ]
    let gradient = NSGradient(colors: colors)
    let path = roundedRectPath(in: rect.insetBy(dx: rect.width * 0.05, dy: rect.height * 0.05), radius: rect.width * 0.22)
    path.addClip()
    gradient?.draw(in: rect, angle: 42)
}

func drawWaveform(in rect: NSRect) {
    let centerY = rect.midY
    let barWidth = rect.width * 0.055
    let gap = rect.width * 0.038
    let heights = [0.22, 0.42, 0.64, 0.82, 0.54, 0.34].map { rect.height * $0 }
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = rect.midX - totalWidth / 2

    NSColor.white.withAlphaComponent(0.94).setFill()
    for height in heights {
        let barRect = NSRect(
            x: x,
            y: centerY - height / 2,
            width: barWidth,
            height: height
        )
        roundedRectPath(in: barRect, radius: barWidth / 2).fill()
        x += barWidth + gap
    }
}

func drawSwitchMark(in rect: NSRect) {
    let markRect = NSRect(
        x: rect.minX + rect.width * 0.60,
        y: rect.minY + rect.height * 0.17,
        width: rect.width * 0.22,
        height: rect.height * 0.22
    )

    NSColor.white.withAlphaComponent(0.22).setFill()
    NSBezierPath(ovalIn: markRect.insetBy(dx: -rect.width * 0.045, dy: -rect.height * 0.045)).fill()

    NSColor.white.setStroke()
    let lineWidth = max(2, rect.width * 0.028)
    let arrow = NSBezierPath()
    arrow.lineWidth = lineWidth
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: markRect.minX, y: markRect.midY))
    arrow.line(to: NSPoint(x: markRect.maxX, y: markRect.midY))
    arrow.line(to: NSPoint(x: markRect.maxX - markRect.width * 0.26, y: markRect.maxY))
    arrow.move(to: NSPoint(x: markRect.maxX, y: markRect.midY))
    arrow.line(to: NSPoint(x: markRect.maxX - markRect.width * 0.26, y: markRect.minY))
    arrow.stroke()
}

func makeIcon(size: CGFloat, scale: CGFloat) throws -> Data {
    let pixelSize = Int(size * scale)
    let image = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
    NSGraphicsContext.current?.imageInterpolation = .high
    drawGradientBackground(in: rect)
    drawWaveform(in: rect.insetBy(dx: rect.width * 0.16, dy: rect.height * 0.18))
    drawSwitchMark(in: rect)

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
    try data.write(to: iconsetURL.appendingPathComponent(spec.name))
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
