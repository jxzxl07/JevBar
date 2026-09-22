import AppKit
import SwiftUI

/// JevBar: a menu-bar item, a command field, and the loop behind them.
///
/// `MenuBarExtra` with `.window` rather than a normal app window: the whole
/// point is that it is summoned over whatever you are doing and does not take
/// the frontmost application away from you, because the frontmost application is
/// the one it is about to act on.
@main
struct JevBarApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var model = BarModel()

  var body: some Scene {
    MenuBarExtra("JevBar", systemImage: "wand.and.rays") {
      BarView(model: model)
        .frame(width: 420)
    }
    .menuBarExtraStyle(.window)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Accessory, not regular: no Dock icon and no menu bar of its own. JevBar
    // lives in the status bar and must never become the frontmost application
    // by accident, since that is the window it would then be reading.
    NSApp.setActivationPolicy(.accessory)
  }
}

@MainActor
final class BarModel: ObservableObject {
  @Published var command = ""
  @Published var status = ""
  @Published var busy = false
  @Published var steps: [String] = []

  private let log = RunLog()
  private lazy var engine = Engine(executable: enginePath())
  private var agent: Agent?

  /// Whether everything the bar needs is present, said plainly rather than
  /// discovered on the first command.
  var readiness: String? {
    if !FileManager.default.isExecutableFile(atPath: enginePath().path) {
      return "The computer-use engine is missing from this build."
    }
    if ThinkConfig.load() == nil {
      return "No model key. Put GEMINI_API_KEY in ~/Library/Application Support/JevBar/.env"
    }
    return nil
  }

  func run() {
    let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !busy else { return }
    guard let config = ThinkConfig.load() else {
      status = ThinkError.notConfigured.description
      return
    }

    busy = true
    status = "Working…"
    steps = []
    let runId = "run_\(UInt32.random(in: 0..<UInt32.max))"

    Task {
      let agent = self.agent ?? Agent(engine: engine, think: Think(config: config), log: log)
      self.agent = agent
      let result = await agent.run(command: text, runId: runId)
      self.busy = false
      self.steps = result.steps
      self.status = result.message
      if result.outcome == .done { self.command = "" }
    }
  }
}

/// The engine binary, inside the bundle.
///
/// Never resolved against the working directory. That is the filesystem root
/// inside a `.app`, and a path built from it works in a checkout and fails once
/// shipped — which happened four separate times in JevDesk, in four different
/// subsystems, each time looking like the feature above it was broken.
func enginePath() -> URL {
  if let bundled = Bundle.main.url(forResource: "munim-computer-use", withExtension: nil) {
    return bundled
  }
  // Development: beside the built product, put there by `make`.
  return URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .appendingPathComponent("munim-computer-use")
}

struct BarView: View {
  @ObservedObject var model: BarModel
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      TextField("Tell JevBar what to do…", text: $model.command)
        .textFieldStyle(.plain)
        .font(.system(size: 16))
        .focused($focused)
        .onSubmit { model.run() }
        .disabled(model.busy)

      if let readiness = model.readiness {
        Text(readiness)
          .font(.caption)
          .foregroundStyle(.orange)
      }

      if !model.status.isEmpty {
        Divider()
        Text(model.status)
          .font(.callout)
          .foregroundStyle(model.busy ? .secondary : .primary)
      }

      if !model.steps.isEmpty {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(model.steps, id: \.self) { step in
            Text("• \(step)").font(.caption).foregroundStyle(.secondary)
          }
        }
      }

      Divider()
      HStack {
        Text("return to run").font(.caption2).foregroundStyle(.tertiary)
        Spacer()
        Button("Quit") { NSApp.terminate(nil) }
          .buttonStyle(.plain)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(14)
    .onAppear { focused = true }
  }
}
