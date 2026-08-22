import AppKit

enum VoiceLauncherGlyphImage {
  static func make(size: CGFloat, color: NSColor) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    color.setStroke()
    color.setFill()

    let scale = size / 24
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
      NSPoint(x: x * scale, y: (24 - y) * scale)
    }

    let strokeWidth = 2.45 * scale
    let key = NSBezierPath()
    key.lineWidth = strokeWidth
    key.lineCapStyle = .round
    key.lineJoinStyle = .round
    key.move(to: point(15.8, 2.2))
    key.line(to: point(7.0, 2.2))
    key.curve(to: point(2.2, 7.0), controlPoint1: point(4.4, 2.2), controlPoint2: point(2.2, 4.4))
    key.line(to: point(2.2, 17.0))
    key.curve(to: point(7.0, 21.8), controlPoint1: point(2.2, 19.6), controlPoint2: point(4.4, 21.8))
    key.line(to: point(17.0, 21.8))
    key.curve(to: point(21.8, 17.0), controlPoint1: point(19.6, 21.8), controlPoint2: point(21.8, 19.6))
    key.line(to: point(21.8, 9.3))
    key.stroke()

    for (x, height) in [(9.2, 7.0), (12.0, 12.0), (14.8, 7.0)] {
      let barWidth = 2.2 * scale
      let rect = NSRect(
        x: x * scale - barWidth / 2,
        y: (24 - 12.2) * scale - height * scale / 2,
        width: barWidth,
        height: height * scale
      )
      NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }

    image.isTemplate = true
    return image
  }
}
