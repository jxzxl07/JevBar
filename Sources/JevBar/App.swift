import AppKit
import SwiftUI

/// JevBar: a menu-bar item, a command field, and the loop behind them.
///
/// ## Why the status item is built by hand
///
/// SwiftUI's `MenuBarExtra` is the obvious way to write this and it does not
/// work here: in an executable built by SwiftPM rather than Xcode it fails
/// silently, leaving a running process with `StatusBarItemCount = NULL` and
/// nothing on screen — an app that launches, stays up, and cannot be seen or
/// quit. `NSStatusItem` with a popover is a few more lines and actually appears.
///
/// The app is an accessory: no Dock icon, no menu bar of its own. That is not
/// only tidiness. JevBar reads whichever application is frontmost, so becoming
/// frontmost itself would mean reading its own window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem?
  private var popover: NSPopover?
  private let model = BarModel()

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.image = NSImage(
      systemSymbolName: "wand.and.rays", accessibilityDescription: "JevBar")
    item.button?.target = self
    item.button?.action = #selector(toggle)
    statusItem = item

    let popover = NSPopover()
    popover.contentSize = NSSize(width: 420, height: 260)
    popover.behavior = .transient
    popover.contentViewController = NSHostingController(rootView: BarView(model: model))
    self.popover = popover

    // Hold-to-talk works whether or not the panel is open: the whole point is
    // that you do not have to go and find JevBar first.
    model.startVoice()

    /*
     A line in the log saying the bar actually appeared.

     An accessory app with no window is invisible when it works and invisible
     when it does not, and the first attempt at this failed exactly that way:
     a running process, no status item, nothing to click and no way to quit it.
     Recording whether the button exists turns "I don't think it's opening"
     into a question with an answer.
    */
    let placement = item.button == nil ? "no status item button" : "status item ready"
    let note = "\(Date()) launch: \(placement), engine=\(enginePath().path)\n"
    if let data = note.data(using: .utf8) {
      let file = supportDirectory().appendingPathComponent("launch.log")
      if let handle = try? FileHandle(forWritingTo: file) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
      } else {
        try? data.write(to: file)
      }
    }
  }

  @objc private func toggle() {
    guard let popover, let button = statusItem?.button else { return }
    if popover.isShown {
      popover.performClose(nil)
      return
    }
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    // The popover's window has to be made key for the text field to accept
    // typing: an accessory app is not active, so nothing in it has focus by
    // default and the field would look ready while swallowing every keystroke.
    popover.contentViewController?.view.window?.makeKey()
  }
}

@main
enum Main {
  @MainActor
  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Held for the process's lifetime: `NSApplication.delegate` is a weak
    // reference, and a delegate that is deallocated takes the status item with
    // it, leaving the same invisible-but-running app this replaced.
    objc_setAssociatedObject(app, "jevbar.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
  }
}

@MainActor
final class BarModel: ObservableObject {
  @Published var command = ""
  @Published var status = ""
  @Published var busy = false
  @Published var steps: [String] = []
  @Published var listening = false
  /// Fields the last run could not answer: fact key to the label that asked.
  @Published var questions: [(key: String, label: String)] = []
  @Published var answer = ""

  let voice = Voice()
  private let hotkey = Hotkey()
  private let overlay = Overlay()

  private let log = RunLog()
  private let profile = Profile()
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

  /// Hold-to-talk, from anywhere on the desktop.
  func startVoice() {
    hotkey.onPress = { [weak self] in
      guard let self, !self.busy else { return }
      self.listening = true
      self.status = "Listening…"
      self.command = ""
      // Shown from the moment the key goes down, so there is never a silence
      // where it is unclear whether JevBar is hearing anything.
      self.overlay.show("")
      self.voice.startListening()
    }
    hotkey.onRelease = { [weak self] in
      guard let self, self.listening else { return }
      self.listening = false
      self.overlay.hide()
      self.voice.stopListening()
      // Running happens on the *final* transcript, which arrives after the key
      // is released. Running on the last partial would act on a sentence the
      // recogniser had not finished correcting.
    }
    voice.onPartial = { [weak self] text in
      self?.command = text
      self?.overlay.show(text)
    }
    voice.onFinal = { [weak self] text in
      guard let self else { return }
      self.overlay.hide()
      guard !text.isEmpty else { return }
      self.command = text
      self.run()
    }
    hotkey.start()

    Task {
      let state = await voice.prepare()
      if case .unavailable(let why) = state { self.status = why }
    }
  }

  /// Answer one of the questions the last run left open.
  func submitAnswer(for key: String) {
    let value = answer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    answer = ""

    Task {
      let stored = await agent?.answer(key: key, value: value) ?? false
      self.questions.removeAll { $0.key == key }
      self.status =
        stored
        ? (self.questions.isEmpty
          ? "Saved. Run it again and it will fill that in."
          : "Saved. \(self.questions.count) left.")
        : "JevBar does not store that kind of answer."
    }
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
      let agent = self.agent ?? Agent(engine: engine, think: Think(config: config), log: log, profile: profile)
      self.agent = agent
      let result = await agent.run(command: text, runId: runId)
      self.busy = false
      self.steps = result.steps
      self.status = result.message
      // Asked in the order the form asks them, so answering follows the page.
      self.questions = await agent.pendingQuestions.map { (key: $0.key, label: $0.value) }
        .sorted { $0.label < $1.label }
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
      HStack(spacing: 8) {
        if model.listening {
          Image(systemName: "waveform")
            .foregroundStyle(.red)
            .symbolEffect(.variableColor)
        }
        TextField("Tell JevBar what to do…", text: $model.command)
          .textFieldStyle(.plain)
          .font(.system(size: 16))
          .focused($focused)
          .onSubmit { model.run() }
          .disabled(model.busy)
      }

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

      if let question = model.questions.first {
        Divider()
        Text("What should I put for “\(question.label)”?")
          .font(.callout)
        TextField("Your answer — I will remember it", text: $model.answer)
          .textFieldStyle(.roundedBorder)
          .onSubmit { model.submitAnswer(for: question.key) }
        if model.questions.count > 1 {
          Text("\(model.questions.count - 1) more after this")
            .font(.caption2).foregroundStyle(.tertiary)
        }
      }

      Divider()
      HStack {
        Text(model.listening ? "listening — let go to run" : "⌘⇧Space to talk · return to run")
          .font(.caption2).foregroundStyle(.tertiary)
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
