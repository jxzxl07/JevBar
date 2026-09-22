import AppKit
import SwiftUI

/// What you are saying, shown while you say it.
///
/// ## Why a window of its own
///
/// Hold-to-talk works from anywhere, which means the popover is usually shut:
/// the words were going into a text field nobody could see, and the only way to
/// find out whether JevBar had heard you was to let go and watch what happened.
///
/// This is a borderless panel near the top of the screen that appears when you
/// start speaking and goes when you stop. It never takes focus — it must not,
/// because the application it is floating over is the one about to be acted on,
/// and stealing focus would change the answer to "what is in front of you?".
@MainActor
final class Overlay {
  private var panel: NSPanel?
  private let text = OverlayText()

  func show(_ transcript: String) {
    text.value = transcript
    guard panel == nil else { return }

    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 92),
      // `.nonactivatingPanel` is the part that matters: without it, showing
      // this would make JevBar frontmost and the run would then be about
      // JevBar's own window.
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    // Visible over full-screen apps, and on whichever space is in use: a
    // listening indicator that only appears on one desktop is worse than none.
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.contentView = NSHostingView(rootView: OverlayView(text: text))

    if let screen = NSScreen.main {
      let frame = screen.visibleFrame
      panel.setFrameOrigin(
        NSPoint(
          x: frame.midX - panel.frame.width / 2,
          y: frame.maxY - panel.frame.height - 24))
    }

    panel.orderFrontRegardless()
    self.panel = panel
  }

  func hide() {
    panel?.orderOut(nil)
    panel = nil
  }
}

@MainActor
private final class OverlayText: ObservableObject {
  @Published var value = ""
}

private struct OverlayView: View {
  @ObservedObject var text: OverlayText

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "waveform")
        .font(.system(size: 20))
        .foregroundStyle(.red)
        .symbolEffect(.variableColor)

      Text(text.value.isEmpty ? "Listening…" : text.value)
        .font(.system(size: 19, weight: .medium))
        .foregroundStyle(text.value.isEmpty ? .secondary : .primary)
        .lineLimit(2)
        // Left-aligned and growing rightwards, so a sentence does not jump
        // around the screen as each word arrives.
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.12), value: text.value)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    .overlay(
      RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12), lineWidth: 1))
  }
}
