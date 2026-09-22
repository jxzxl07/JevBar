import AppKit
import Foundation

/// What happened, in words the user can act on.
struct RunResult: Sendable {
  enum Outcome: String, Sendable {
    case done
    case readyForReview
    case refused
    case failed
  }

  let outcome: Outcome
  let message: String
  let steps: [String]
}

/// One turn's decision, as the model is allowed to express it.
private struct Move: Sendable {
  let action: String
  let elementId: String?
  let text: String?
  let app: String?
  let reason: String
}

/// The loop: look, decide, authorize, act, look again.
///
/// ## Why the order is look-decide-*authorize*-act
///
/// The authorization sits between the decision and the effect, reading the
/// control's name out of JevBar's own copy of the screen. A model that wants to
/// press "Submit application" can describe it however it likes; what is checked
/// is what the accessibility tree called the id it chose.
///
/// ## Why it stops
///
/// Three turns with nothing observably changing ends the run. An agent that
/// cannot tell it is stuck presses controls into the void on someone's real
/// screen, and the honest ending is to say so.
actor Agent {
  private let engine: Engine
  private let think: Think
  private let log: RunLog
  private let profile: Profile

  /// Consecutive turns with no observable change before the run stops.
  private let maxQuietTurns = 3
  /// Turns per step, whatever happens.
  private let maxTurns = 12

  init(engine: Engine, think: Think, log: RunLog, profile: Profile) {
    self.engine = engine
    self.think = think
    self.log = log
    self.profile = profile
  }

  /// Questions the last run could not answer, for the bar to put to the user.
  private(set) var pendingQuestions: [String: String] = [:]

  /// Run a whole sentence: every clause, in order, stopping on the first failure.
  ///
  /// A clause that does not run is named in the result. JevDesk dropped the
  /// second half of a sentence silently, which is the one outcome forbidden
  /// here — a user who is not told cannot correct it.
  func run(command: String, runId: String) async -> RunResult {
    let steps = planSteps(from: command)
    guard !steps.isEmpty else {
      return RunResult(outcome: .failed, message: "There was nothing to do.", steps: [])
    }

    await log.started(runId: runId, command: command, stepCount: steps.count)
    var done: [String] = []

    for (index, step) in steps.enumerated() {
      let result = await runStep(step, runId: runId, number: index + 1)
      done.append(contentsOf: result.steps)

      guard result.outcome == .done || result.outcome == .readyForReview else {
        let remaining = steps.count - index - 1
        let unfinished =
          remaining == 0
          ? ""
          : " I did not go on to the other \(remaining) thing\(remaining == 1 ? "" : "s") you asked for."
        await log.finished(runId: runId, outcome: result.outcome.rawValue)
        return RunResult(
          outcome: result.outcome, message: result.message + unfinished, steps: done)
      }

      if result.outcome == .readyForReview {
        await log.finished(runId: runId, outcome: result.outcome.rawValue)
        return RunResult(outcome: .readyForReview, message: result.message, steps: done)
      }
    }

    await log.finished(runId: runId, outcome: RunResult.Outcome.done.rawValue)
    return RunResult(outcome: .done, message: "Done.", steps: done)
  }

  private func runStep(_ step: Step, runId: String, number: Int) async -> RunResult {
    var performed: [String] = []
    var quietTurns = 0
    var lastFingerprint = ""

    if step.closes {
      guard let app = step.app else {
        return await fail(
          "I could not tell what to close.", runId: runId, step: number, performed: performed)
      }
      // Requested rather than forced: an application asked to quit runs its own
      // save-and-quit path, which is what Cmd-Q gives. `forceTerminate` would
      // discard unsaved work and is deliberately not used.
      let running = NSWorkspace.shared.runningApplications.filter {
        $0.localizedName == app || $0.bundleIdentifier == app
      }
      guard !running.isEmpty else {
        return RunResult(outcome: .done, message: "\(app) was not open.", steps: performed)
      }
      running.forEach { $0.terminate() }
      await log.step(runId: runId, step: number, detail: "quit \(app)")
      return RunResult(outcome: .done, message: "Closed \(app).", steps: ["closed \(app)"])
    }

    if let folder = step.folder {
      NSWorkspace.shared.open(URL(fileURLWithPath: folder))
      await log.step(runId: runId, step: number, detail: "opened folder \(folder)")
      let name = URL(fileURLWithPath: folder).lastPathComponent
      performed.append("opened \(name)")
      // Opening a folder is the whole of the clause. Looking at the screen
      // afterwards would send Finder's window to a model with nothing to decide.
      return RunResult(outcome: .done, message: "Opened \(name).", steps: performed)
    }

    if let site = step.site {
      guard let url = URL(string: site) else {
        return await fail(
          "I could not make sense of \(site).", runId: runId, step: number, performed: performed)
      }
      NSWorkspace.shared.open(url)
      performed.append("opened \(url.host ?? site)")
      await log.step(runId: runId, step: number, detail: "opened \(url.host ?? site)")
      // A page asked to load is not a page that has loaded, and observing too
      // early reads whatever was on screen before.
      try? await Task.sleep(for: .milliseconds(1_800))
    } else if let app = step.app {
      do {
        try await open(app: app)
        performed.append("opened \(app)")
        await log.step(runId: runId, step: number, detail: "opened \(app)")
      } catch {
        return await fail(
          "I could not open \(app). \(error)", runId: runId, step: number, performed: performed)
      }
    }

    /*
     A form is filled by lookup, not by the loop.

     The loop is for work whose shape is not known in advance. A form is a list
     of labelled boxes, and matching a box to a fact is a table lookup — sending
     sixty of them through a model one at a time is how JevDesk spent
     thirty-one seconds before the first character appeared, and still filled
     five of sixty-one.
    */
    if step.kind == .jobApplication || asksToFill(step.goal) {
      let screen: Screen
      do {
        screen = try await observe(app: step.app)
      } catch {
        return await fail("\(error)", runId: runId, step: number, performed: performed)
      }

      let filler = FormFill(engine: engine, profile: profile, think: think)
      let result = await filler.fill(screen: screen, task: step.kind)

      guard !result.outcomes.isEmpty else {
        /*
         Say which of the two things went wrong.

         "I could not find any fields" is true of a screen with nothing on it
         and of a screen full of controls whose roles this code does not know,
         and those need opposite fixes. JevDesk spent a long time on messages
         that were true and useless; the counts turn one sentence into a
         diagnosis.
        */
        let roles = Set(screen.controls.map(\.role)).sorted().prefix(8).joined(separator: ", ")
        await log.step(
          runId: runId, step: number,
          detail: "no fillable fields: \(screen.controls.count) control(s), roles: \(roles)")

        let why =
          screen.controls.isEmpty
          ? "I could not read anything in \(screen.app). If it is a browser, click the page "
            + "itself once and try again."
          : "I read \(screen.controls.count) control(s) in \(screen.app) but none is a text "
            + "field I can fill."
        return await fail(why, runId: runId, step: number, performed: performed)
      }

      for outcome in result.outcomes {
        await log.step(runId: runId, step: number, detail: describe(outcome))
      }
      performed.append(contentsOf: result.filled.map { "filled \($0.label)" })

      pendingQuestions = Dictionary(
        result.questions.compactMap { outcome -> (String, String)? in
          guard case .asks(let key) = outcome.state else { return nil }
          return (key, outcome.label)
        }, uniquingKeysWith: { first, _ in first })

      let asked = pendingQuestions.count
      let message =
        "Filled \(result.filled.count) field\(result.filled.count == 1 ? "" : "s"). "
        + (asked == 0
          ? "Review it on the page — I will not submit an application for you."
          : "I need \(asked) answer\(asked == 1 ? "" : "s") before I can finish.")

      return RunResult(outcome: .readyForReview, message: message, steps: performed)
    }

    for _ in 0..<maxTurns {
      let screen: Screen
      do {
        screen = try await observe(app: step.app)
      } catch {
        return await fail("\(error)", runId: runId, step: number, performed: performed)
      }

      let fingerprint = screen.controls.map(\.id).joined(separator: ",")
      quietTurns = fingerprint == lastFingerprint ? quietTurns + 1 : 0
      lastFingerprint = fingerprint
      if quietTurns >= maxQuietTurns {
        return await fail(
          "I tried \(maxQuietTurns) times and nothing on screen changed, so I stopped rather "
            + "than claim it was done.", runId: runId, step: number, performed: performed)
      }

      let move: Move
      do {
        move = try await decide(goal: step.goal, screen: screen, doneSoFar: performed)
      } catch {
        return await fail("\(error)", runId: runId, step: number, performed: performed)
      }

      await log.step(
        runId: runId, step: number, detail: "\(move.action) \(move.elementId ?? "-") — \(move.reason)")

      switch move.action {
      case "done":
        return RunResult(outcome: .done, message: move.reason, steps: performed)
      case "ready_for_review":
        return RunResult(outcome: .readyForReview, message: move.reason, steps: performed)
      case "blocked":
        return await fail(move.reason, runId: runId, step: number, performed: performed)
      default:
        break
      }

      switch await perform(move, on: screen, task: step.kind) {
      case .success(let what):
        performed.append(what)
      case .refused(let why):
        // A refusal ends the run rather than being retried. The model would
        // otherwise reach for the next-best way to do the thing that was just
        // forbidden, which is the opposite of what a refusal means.
        await log.step(runId: runId, step: number, detail: "refused: \(why)")
        return RunResult(outcome: .refused, message: why, steps: performed)
      case .failure(let why):
        performed.append("could not \(move.action): \(why)")
      }
    }

    return await fail(
      "I ran out of turns on: \(step.goal)", runId: runId, step: number, performed: performed)
  }

  /// Remember an answer the user gave, so the same field never asks again.
  func answer(key: String, value: String) async -> Bool {
    let stored = await profile.learn(key: key, value: value)
    if stored { pendingQuestions.removeValue(forKey: key) }
    return stored
  }

  private func describe(_ outcome: FieldOutcome) -> String {
    // Labels and keys, never values: a log carrying what was typed into an
    // application form carries someone's address in plain text, forever.
    switch outcome.state {
    case .filled(let key): return "filled \(outcome.label) from \(key)"
    case .asks(let key): return "asks \(outcome.label) (\(key))"
    case .skipped(let why): return "skipped \(outcome.label): \(why)"
    case .refused(let why): return "refused \(outcome.label): \(why)"
    }
  }

  /// Every failure says why, in the log as well as on screen.
  ///
  /// The first version of this returned a message to the user and wrote nothing
  /// down, so "open Notes" failed instantly with a blank record — the exact
  /// thing the log exists to prevent, reintroduced by returning early.
  private func fail(
    _ why: String, runId: String, step: Int, performed: [String]
  ) async -> RunResult {
    await log.step(runId: runId, step: step, detail: "failed: \(why)")
    return RunResult(outcome: .failed, message: why, steps: performed)
  }

  /// Open an application, launching it when it is not already running.
  ///
  /// The engine's `activate_app` only brings an *already running* app to the
  /// front — it is documented as foregrounding windows, not as launching. So
  /// "open Safari" worked (it was running) and "open Notes" failed outright,
  /// which read as the agent being broken rather than as a missing verb.
  ///
  /// `NSWorkspace` launches it; the engine then foregrounds it, because a newly
  /// launched app is not reliably frontmost by the time the next observation
  /// happens.
  private func open(app: String) async throws {
    if let url = Apps.resolve(app)?.url
      ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)
    {
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
      // A launch returns as soon as macOS accepts it; the window arrives later,
      // and observing before it does reads the application that was in front.
      try? await Task.sleep(for: .milliseconds(900))
      return
    }
    _ = try await engine.call("activate_app", ["app": app])
  }



  /// Read the screen of the application this step is about.
  ///
  /// `get_app_state` requires an app, and a clause naming a *site* names no
  /// application at all — "open youtube" failed with `missing required argument
  /// 'app'` for exactly that reason. When nothing is named, the frontmost app is
  /// the subject, which is also what the user means by "this form".
  private func observe(app: String?) async throws -> Screen {
    let target: String
    if let app {
      target = app
    } else {
      target = try await frontmostApp()
    }
    /*
     A real application form is long.

     Three hundred was this code's own cap, not the engine's, and a Lever page
     spent all of it on the navigation and the job description before reaching
     a single input. The engine truncates and says so; what it cannot do is
     know that the interesting part comes last.
    */
    let outline = try await engine.call(
      "get_app_state", ["app": target, "max_elements": 2_000])
    return parseScreen(app: target, outline: outline)
  }

  private func frontmostApp() async throws -> String {
    if let running = NSWorkspace.shared.frontmostApplication?.localizedName,
      running != "JevBar"
    {
      return running
    }
    // JevBar itself is frontmost while its own panel is open, and observing our
    // own window would answer questions about the command field. The engine's
    // own listing knows which application is behind us.
    let listing = try await engine.call("list_apps", [:])
    for line in listing.split(separator: "\n") where line.lowercased().contains("frontmost") {
      if let name = line.split(separator: " ").first { return String(name) }
    }
    throw Engine.Failure.tool("I could not tell which application is in front.")
  }

  private enum Performed {
    case success(String)
    case refused(String)
    case failure(String)
  }

  private func perform(_ move: Move, on screen: Screen, task: TaskKind) async -> Performed {
    guard let id = move.elementId, let control = screen.control(id: id) else {
      // A hallucinated id is not in the list JevBar built, so it addresses
      // nothing. This is the whole reason the model chooses ids rather than
      // coordinates: the worst case is a wasted turn.
      return .failure("'\(move.elementId ?? "nothing")' is not a control I can see.")
    }

    let verb: Action.Verb
    switch move.action {
    case "click": verb = .click
    case "set_value": verb = .setValue
    case "type_text": verb = .typeText
    default: return .failure("I do not know how to '\(move.action)'.")
    }

    let decision = authorize(
      Action(verb: verb, controlName: control.name, value: move.text), in: task)
    if case .refuse(let why) = decision { return .refused(why) }

    do {
      switch verb {
      case .click:
        _ = try await engine.call("click", ["element_id": id])
        return .success("pressed \(control.name)")
      case .setValue:
        // `set_value` replaces the whole field rather than inserting at the
        // caret, so filling the same box twice cannot produce `MKBHDMKBHD`.
        _ = try await engine.call("set_value", ["element_id": id, "value": move.text ?? ""])
        return .success("filled \(control.name)")
      case .typeText:
        _ = try await engine.call("type_text", ["element_id": id, "text": move.text ?? ""])
        return .success("typed into \(control.name)")
      default:
        return .failure("unsupported")
      }
    } catch {
      return .failure("\(error)")
    }
  }

  private func decide(goal: String, screen: Screen, doneSoFar: [String]) async throws -> Move {
    let controls = screen.controls.prefix(120).map { control in
      let value = control.value.map { " (currently \"\($0)\")" } ?? ""
      return "\(control.id) \(control.role) \"\(control.name)\"\(value)"
    }.joined(separator: "\n")

    let system = """
      You operate a Mac by choosing one action at a time.

      Reply with JSON only:
      {"action":"click|set_value|type_text|done|ready_for_review|blocked",
       "element_id":"e12 or null","text":"text to write or null",
       "reason":"one short sentence"}

      Rules:
      - element_id must be one of the ids listed. Never invent one.
      - Never give coordinates. Never give a URL or a selector.
      - Use set_value to fill a text field; it replaces what is there.
      - "done" when the goal is achieved. "ready_for_review" when a form is
        filled in as far as it can be. "blocked" when nothing listed can help.
      - Never choose a control that submits a job application, sends a message,
        or asks for a password. Those are refused anyway.
      """

    let user = """
      Goal: \(goal)

      Already done: \(doneSoFar.isEmpty ? "nothing yet" : doneSoFar.joined(separator: "; "))

      Controls on screen:
      \(controls.isEmpty ? "(none)" : controls)
      """

    let answer = try await think.ask(system: system, user: user)
    return Move(
      action: (answer["action"] as? String ?? "blocked").lowercased(),
      elementId: answer["element_id"] as? String,
      text: answer["text"] as? String,
      app: answer["app"] as? String,
      reason: answer["reason"] as? String ?? "")
  }
}
