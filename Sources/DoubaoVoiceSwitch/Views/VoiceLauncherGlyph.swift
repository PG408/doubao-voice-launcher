import SwiftUI

struct VoiceLauncherGlyph: View {
  let size: CGFloat
  let color: Color

  var body: some View {
    Canvas { context, canvasSize in
      let scale = min(canvasSize.width, canvasSize.height) / 24
      let width = 24 * scale
      let height = 24 * scale
      let origin = CGPoint(
        x: (canvasSize.width - width) / 2,
        y: (canvasSize.height - height) / 2
      )

      func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
      }

      var key = Path()
      key.move(to: point(15.8, 2.2))
      key.addLine(to: point(7.0, 2.2))
      key.addQuadCurve(to: point(2.2, 7.0), control: point(2.2, 2.2))
      key.addLine(to: point(2.2, 17.0))
      key.addQuadCurve(to: point(7.0, 21.8), control: point(2.2, 21.8))
      key.addLine(to: point(17.0, 21.8))
      key.addQuadCurve(to: point(21.8, 17.0), control: point(21.8, 21.8))
      key.addLine(to: point(21.8, 9.3))

      context.stroke(
        key,
        with: .color(color),
        style: StrokeStyle(
          lineWidth: 2.45 * scale,
          lineCap: .round,
          lineJoin: .round
        )
      )

      let fill = GraphicsContext.Shading.color(color)
      for (x, barHeight) in [
        (9.2, 7.0),
        (12.0, 12.0),
        (14.8, 7.0),
      ] {
        let center = point(x, 12.2)
        let barWidth = 2.2 * scale
        let rect = CGRect(
          x: center.x - barWidth / 2,
          y: center.y - barHeight * scale / 2,
          width: barWidth,
          height: barHeight * scale
        )
        context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: fill)
      }
    }
    .frame(width: size, height: size)
    .accessibilityLabel("豆包语音切换器")
  }
}
