import AppKit
import SwiftUI

@MainActor
final class ToastPresenter {
  private let defaultDisplayMilliseconds = 1_000
  private let height: CGFloat = 40
  private let horizontalPadding: CGFloat = 20
  private let minimumWidth: CGFloat = 200
  private let maximumWidth: CGFloat = 420
  private var panel: ToastPanel?
  private var hideWorkItem: DispatchWorkItem?

  func show(message: String, durationMilliseconds: Int? = nil) {
    let size = panelSize(for: message)
    let panel = panel ?? makePanel()
    self.panel = panel
    panel.contentView = NSHostingView(rootView: ToastView(message: message, size: size))
    panel.setFrame(frame(for: size), display: true)
    panel.alphaValue = 1
    panel.orderFrontRegardless()

    hideWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self, weak panel] in
      MainActor.assumeIsolated {
        guard let self, let panel else {
          return
        }
        panel.orderOut(nil)
        self.hideWorkItem = nil
      }
    }
    hideWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(durationMilliseconds ?? defaultDisplayMilliseconds),
      execute: workItem
    )
  }

  private func makePanel() -> ToastPanel {
    let panel = ToastPanel(
      contentRect: frame(for: CGSize(width: minimumWidth, height: height)),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    return panel
  }

  private func panelSize(for message: String) -> CGSize {
    let textWidth = (message as NSString).size(withAttributes: [
      .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
    ]).width
    let width = min(max(ceil(textWidth + horizontalPadding * 2), minimumWidth), maximumWidth)
    return CGSize(width: width, height: height)
  }

  private func frame(for size: CGSize) -> CGRect {
    let mouseLocation = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { screen in
      NSMouseInRect(mouseLocation, screen.frame, false)
    } ?? NSScreen.main
    let visibleFrame = screen?.visibleFrame ?? .zero
    let x = visibleFrame.midX - size.width / 2
    let y = visibleFrame.midY - size.height / 2
    return CGRect(origin: CGPoint(x: x, y: y), size: size)
  }
}

private final class ToastPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private struct ToastView: View {
  let message: String
  let size: CGSize

  var body: some View {
    Text(message)
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(.white)
      .lineLimit(1)
      .padding(.horizontal, 20)
      .frame(width: size.width, height: size.height)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color.black.opacity(0.68))
      )
  }
}
