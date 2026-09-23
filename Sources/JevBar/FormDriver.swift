import Foundation

/// One thing a form asks, however the page happens to draw it.
///
/// A form is a list of questions, not a list of controls. "Are you currently
/// eligible to work in the UK?" is one question drawn as two radio buttons named
/// "Yes" and "No"; "Start Date" is one question drawn as three segments. The old
/// filler worked on controls, so it never saw a dropdown whose accessible name
/// was "- Select-", a radio button whose name was "Yes", or a date at all.
struct FormQuestion {
  enum Kind: String {
    case text, longText, select, radio, checkbox, date
  }

  let kind: Kind
  /// What the page calls it — the visible label or question.
  let label: String
  /// Which occurrence of this kind and label, so it can be found again after
  /// a re-read renumbers every id.
  let ordinal: Int
  /// The control to act on: the field, the dropdown, or the date area.
  let controlID: String
  /// Its name as the engine reports it, for the policy.
  let controlName: String
  /// For radios and checkboxes, each option's name, id and whether it is on.
  let options: [(name: String, id: String, on: Bool)]
  /// What it holds now, when that is known.
  let current: String?
  /// For a date, the id of each segment.
  let segments: [String: String]
  /// Where it sits in the page, to know which way to scroll.
  let index: Int

  var locator: String { "\(kind.rawValue)|\(normalisedLabel(label))|\(ordinal)" }
}

/// Read a page into the questions it asks, in the order it asks them.
func readQuestions(from screen: Screen) -> [FormQuestion] {
  let all = screen.controls
  // Only the page. Safari's own tab bar is exposed as radio buttons named after
  // each tab, and treating those as a question would click between tabs.
  guard let web = all.firstIndex(where: { $0.role == "WebArea" }) else { return [] }
  let webDepth = all[web].depth
  var end = web + 1
  while end < all.count, all[end].depth > webDepth { end += 1 }
  let page = Array(all[(web + 1)..<end])

  var questions: [FormQuestion] = []
  var seen: [String: Int] = [:]
  func ordinal(_ kind: FormQuestion.Kind, _ label: String) -> Int {
    let key = "\(kind.rawValue)|\(normalisedLabel(label))"
    let n = seen[key, default: 0]
    seen[key] = n + 1
    return n
  }

  var consumed = Set<String>()
  for (i, control) in page.enumerated() where !consumed.contains(control.id) {
    if control.disabled { continue }

    switch control.role {
    case "TextField", "TextArea", "SearchField", "ComboBox":
      let label = control.name.isEmpty ? precedingLabel(page, before: i) : control.name
      guard let label, !label.isEmpty else { continue }
      let probe = Control(id: control.id, role: control.role, name: label, value: nil, depth: 0)
      if isPageChrome(probe) { continue }
      let kind: FormQuestion.Kind =
        control.role == "TextArea" || label.count > 60 ? .longText : .text
      questions.append(
        FormQuestion(
          kind: kind, label: label, ordinal: ordinal(kind, label), controlID: control.id,
          controlName: control.name, options: [],
          current: control.value.flatMap { $0.isEmpty ? nil : $0 },
          segments: [:], index: i))

    case "PopUpButton":
      let placeholder = isPlaceholder(control.name)
      guard
        let label = placeholder ? precedingLabel(page, before: i) : control.name,
        !label.isEmpty
      else { continue }
      let shown = control.value ?? control.name
      questions.append(
        FormQuestion(
          kind: .select, label: label, ordinal: ordinal(.select, label), controlID: control.id,
          controlName: label, options: [],
          current: isPlaceholder(shown) ? nil : shown, segments: [:], index: i))

    case "RadioButton", "CheckBox":
      // A run of options under one question. Collected from here to where the
      // question changes, so "Yes" and "No" become one question with two
      // answers rather than two questions with no label.
      guard let question = groupQuestion(page, at: i) else { continue }
      var options: [(name: String, id: String, on: Bool)] = []
      var j = i
      while j < page.count {
        let candidate = page[j]
        if candidate.role == control.role {
          guard groupQuestion(page, at: j) == question else { break }
          options.append((candidate.name, candidate.id, candidate.value == "1"))
          consumed.insert(candidate.id)
        } else if ["TextField", "TextArea", "PopUpButton", "DateTimeArea"].contains(candidate.role) {
          break
        }
        j += 1
      }
      let kind: FormQuestion.Kind = control.role == "RadioButton" ? .radio : .checkbox
      let on = options.filter(\.on).map(\.name)
      questions.append(
        FormQuestion(
          kind: kind, label: question, ordinal: ordinal(kind, question), controlID: control.id,
          controlName: question, options: options,
          current: on.isEmpty ? nil : on.joined(separator: ", "), segments: [:], index: i))

    case "DateTimeArea":
      guard let label = precedingLabel(page, before: i), !label.isEmpty else { continue }
      var segments: [String: String] = [:]
      var filled = false
      for candidate in page[(i + 1)..<min(i + 12, page.count)] where candidate.role == "Incrementor" {
        segments[candidate.name.lowercased()] = candidate.id
        if let v = candidate.value, v != "0", !v.isEmpty { filled = true }
      }
      guard segments["day"] != nil, segments["month"] != nil, segments["year"] != nil else { continue }
      questions.append(
        FormQuestion(
          kind: .date, label: label, ordinal: ordinal(.date, label), controlID: control.id,
          controlName: label, options: [], current: filled ? "set" : nil,
          segments: segments, index: i))

    default:
      continue
    }
  }
  return questions
}

/// Whether a dropdown's name is its placeholder rather than a label or value.
func isPlaceholder(_ name: String) -> Bool {
  let n = normalisedLabel(name)
  return n.isEmpty || n == "select" || n.hasPrefix("select ") || n.hasSuffix(" select")
    || n == "please select" || n == "choose"
}

/// The text a page puts just before a control as its label.
///
/// Walks back a few lines to the nearest piece of text, stopping at another
/// field so one question never borrows the label of the one before it.
private func precedingLabel(_ page: [Control], before index: Int) -> String? {
  var i = index - 1
  let floor = max(0, index - 12)
  while i >= floor {
    let c = page[i]
    if ["TextField", "TextArea", "PopUpButton", "RadioButton", "CheckBox", "DateTimeArea"]
      .contains(c.role)
    {
      return nil
    }
    if c.role == "StaticText", !c.name.trimmingCharacters(in: .whitespaces).isEmpty,
      !isPlaceholder(c.name)
    {
      return c.name.trimmingCharacters(in: .whitespaces)
    }
    i -= 1
  }
  return nil
}

/// The question a radio button or checkbox belongs to.
///
/// Pages wrap a group of options in a group named after the question; failing
/// that, the question is the nearest text before the options that is not
/// itself one of them.
private func groupQuestion(_ page: [Control], at index: Int) -> String? {
  let depth = page[index].depth
  var i = index - 1
  let floor = max(0, index - 16)
  while i >= floor {
    let c = page[i]
    if c.role == "Group", c.depth < depth, !c.name.isEmpty { return c.name }
    if c.role == "StaticText", c.depth < depth - 2, c.name.count > 3 { return c.name }
    i -= 1
  }
  return nil
}

/// Fills a form question by question, from what the page actually is.
///
/// Every mechanic here was tried against a real application before it was
/// written down — a text field takes a click and typing; a search box needs its
/// suggestion clicked; a custom dropdown needs the dropdown then the option
/// clicked; a date takes digits pressed into each segment in turn; anything off
/// screen is scrolled towards and retried, because element ids survive a scroll
/// but not a re-read.
struct FormDriver {
  let engine: Engine
  let profile: Profile
  let think: Think?
  let documents: Documents
  let log: RunLog?

  /// How long a whole fill may take before it stops and says so.
  var budget: Duration = .seconds(300)

  func fill(app: String, task: TaskKind) async -> FillResult {
    guard var screen = try? await read(app) else {
      return FillResult(outcomes: [.init(label: "the page", state: .skipped("could not read it"))])
    }
    let questions = readQuestions(from: screen)
    guard !questions.isEmpty else { return FillResult(outcomes: []) }
    await log?.pass(number: 0, wrote: questions.count, done: 0)

    let facts = await profile.all()
    var answers = profileAnswers(for: questions, facts: facts)
    let open = questions.filter {
      answers[$0.locator] == nil && [.text, .radio, .checkbox].contains($0.kind)
    }
    let essays = questions.filter { answers[$0.locator] == nil && $0.kind == .longText }
    if let think {
      // Short answers in one request and each essay in its own, all at once: an
      // essay drafted inside a batch of yes/no questions came back null.
      async let short = open.isEmpty ? [:] : modelAnswers(for: open, facts: facts, using: think)
      let drafts = await withTaskGroup(of: (String, String?).self) { group in
        for q in essays {
          group.addTask { (q.locator, await draft(q, facts: facts, using: think)) }
        }
        var out: [String: String] = [:]
        for await (locator, text) in group { if let text { out[locator] = text } }
        return out
      }
      for (locator, answer) in await short { answers[locator] = answer }
      for (locator, text) in drafts { answers[locator] = .text(text) }
    }

    var outcomes: [FieldOutcome] = []
    var lastIndex = 0
    var chosen: [String] = []
    let deadline = ContinuousClock.now + budget

    for question in questions {
      if ContinuousClock.now >= deadline {
        outcomes.append(.init(label: question.label, state: .skipped("ran out of time")))
        continue
      }

      // The answer, whatever form it takes. A dropdown with none is still
      // opened: its options may answer it, and the model is asked with them in
      // front of it.
      let answer = answers[question.locator]
      if answer == nil && question.kind != .select {
        outcomes.append(.init(label: question.label, state: .skipped(Self.noAnswer)))
        continue
      }

      // Found again in the current reading, since any re-read renumbers ids.
      let live = readQuestions(from: screen).first { $0.locator == question.locator } ?? question
      let result = await perform(
        live, answer: answer, facts: facts, screen: &screen, app: app, task: task,
        towards: live.index >= lastIndex ? "down" : "up", chosen: chosen)
      if live.kind == .select, case .filled(let from) = result.state { chosen.append(from) }
      outcomes.append(result)
      lastIndex = live.index
    }

    // One reading at the end, so the report says what the page kept rather than
    // what was attempted.
    if let final = try? await read(app) {
      let after = readQuestions(from: final)
      outcomes = outcomes.map { outcome in
        guard case .filled(let from) = outcome.state,
          let q = questions.first(where: { $0.label == outcome.label }),
          let now = after.first(where: { $0.locator == q.locator })
        else { return outcome }
        return now.current == nil
          ? .init(label: outcome.label, state: .skipped("typed, but the page did not keep it"))
          : .init(label: outcome.label, state: .filled(from: from))
      }
    }
    return FillResult(outcomes: outcomes)
  }

  /// Grades are the applicant's to give, in the scale they choose.
  static func asksForGrades(_ label: String) -> Bool {
    let l = label.lowercased()
    return ["gpa", "grade", "score", "result", "mark"].contains { l.contains($0) }
  }

  /// Questions only the applicant answers, unless their profile does.
  static func personal(_ label: String) -> Bool {
    let l = label.lowercased()
    return ["family", "relative", "salary", "gender", "ethnic", "disab", "offer", "competing"]
      .contains { l.contains($0) }
  }

  static let noAnswer = "nothing I know answers this — left for you"

  // MARK: - Answers

  /// Answers straight from the profile, where a fact names the question.
  private func profileAnswers(
    for questions: [FormQuestion], facts: [String: String]
  ) -> [String: Answer] {
    var answers: [String: Answer] = [:]
    for q in questions {
      if credentialLabel(q.label) { continue }
      if q.kind == .date {
        if let date = dateFact(for: q.label, facts: facts) { answers[q.locator] = .date(date) }
        continue
      }
      guard q.kind != .longText, let key = factKey(forLabel: q.label),
        let value = facts[key], !Self.nothing(value)
      else { continue }

      // A question never takes someone's name, email or phone number.
      if isQuestion(q.label), FormFill.identityKeys.contains(key) { continue }
      if q.kind == .text, !valueSuits(key: key, value: value) { continue }

      switch q.kind {
      case .radio: answers[q.locator] = .one(value)
      case .checkbox: answers[q.locator] = .many([value])
      default: answers[q.locator] = .text(value)
      }
    }
    return answers
  }

  /// "N/A" and its kin are not answers; typing them is worse than leaving the
  /// box for the applicant.
  static func nothing(_ value: String) -> Bool {
    ["n/a", "na", "none", "-", ""].contains(value.trimmingCharacters(in: .whitespaces).lowercased())
  }

  private func isQuestion(_ label: String) -> Bool {
    label.contains("?") || label.split(separator: " ").count >= 6
  }

  /// The date a label asks for, from the profile.
  private func dateFact(for label: String, facts: [String: String]) -> DateComponents? {
    let l = label.lowercased()
    let key: String?
    if l.contains("birth") {
      key = "dateOfBirth"
    } else if l.contains("graduat") {
      key = facts["graduationDate"] != nil ? "graduationDate" : "educationEnd"
    } else if l.contains("end") || l.contains("finish") || l.contains("completion") {
      key = "educationEnd"
    } else if l.contains("start") || l.contains("begin") {
      key = "educationStart"
    } else {
      key = nil
    }
    guard let key, let text = facts[key] else { return nil }
    return parseDate(text)
  }

  /// Every question the profile could not answer, in one request.
  ///
  /// One request rather than one per question, because a form asks twenty and
  /// the model's slow tail is the slowest thing a fill does. Each answer is
  /// checked here: an option must be one the page offers, a credential is never
  /// answered, and a question never takes an identifying detail.
  private func modelAnswers(
    for questions: [FormQuestion], facts: [String: String], using think: Think
  ) async -> [String: Answer] {
    let listed = questions.enumerated().map { n, q -> String in
      var line = "q\(n) [\(q.kind.rawValue)] \(q.label)"
      if !q.options.isEmpty { line += "\n    options: " + q.options.map(\.name).joined(separator: " | ") }
      return line
    }.joined(separator: "\n")
    let profileText = facts.sorted { $0.key < $1.key }
      .filter { !Self.nothing($0.value) }
      .map { "\($0.key): \($0.value)" }.joined(separator: "\n")

    let system = """
      You fill in a job application for the applicant, from their facts and CV only.

      Reply with JSON only: {"answers": {"q0": <answer or null>, ...}}

      By kind:
      - text: a short value in the form the field wants.
      - longText: a written answer in the first person, in the applicant's own
        voice, respecting any word count the question states.
      - radio: exactly one of the listed options, copied exactly.
      - checkbox: a list of the listed options that apply, copied exactly.

      Rules:
      - Facts about the applicant must come from the facts and CV. Never invent
        experience, employers, grades or numbers.
      - Preferences (which roles, teams, locations or dates they would consider)
        may be chosen sensibly from the CV and the role being applied for.
      - Never answer about family or relatives, salary, demographics, disability,
        or offers and interview processes with other companies — null. Those are
        the applicant's to answer.
      - Never give a password, passcode or one-time code.
      """
    let user = """
      Facts:
      \(profileText)

      \(documents.grounding)

      Questions:
      \(listed)
      """

    let reply: [String: Any]
    do { reply = try await think.ask(system: system, user: user) } catch {
      await log?.step(runId: "form", step: 0, detail: "model answers failed: \(error)")
      return [:]
    }
    guard let raw = reply["answers"] as? [String: Any] else {
      await log?.step(runId: "form", step: 0, detail: "model answers unshaped: \(reply.keys.sorted())")
      return [:]
    }
    await log?.step(
      runId: "form", step: 0,
      detail: "model answered \(raw.filter { !($0.value is NSNull) }.count) of \(questions.count)")

    var answers: [String: Answer] = [:]
    for (n, q) in questions.enumerated() {
      guard let value = raw["q\(n)"], !(value is NSNull), !credentialLabel(q.label),
        !Self.asksForGrades(q.label)
      else { continue }
      switch q.kind {
      case .radio:
        guard let text = value as? String,
          let option = q.options.first(where: { normalisedLabel($0.name) == normalisedLabel(text) })
        else { continue }
        answers[q.locator] = .one(option.name)
      case .checkbox:
        let picked = (value as? [String]) ?? (value as? String).map { [$0] } ?? []
        let valid = picked.compactMap { p in
          q.options.first { normalisedLabel($0.name) == normalisedLabel(p) }?.name
        }
        if !valid.isEmpty { answers[q.locator] = .many(valid) }
      case .text, .longText:
        guard let text = value as? String,
          !text.trimmingCharacters(in: .whitespaces).isEmpty, !Self.nothing(text)
        else { continue }
        // A drafted answer is prose; a text field wants a value, not a paragraph.
        if q.kind == .text, text.count > 200 { continue }
        answers[q.locator] = .text(text)
      default:
        continue
      }
    }
    return answers
  }

  /// A written answer to an open question, in the applicant's voice, from their CV.
  private func draft(
    _ q: FormQuestion, facts: [String: String], using think: Think
  ) async -> String? {
    if credentialLabel(q.label) { return nil }
    let system = """
      You write one answer on a job application, as the applicant, in the first
      person. Draw only on their CV and facts: never invent experience,
      employers, awards or numbers. Plain, specific and sincere; no clichés.
      Respect any word count the question gives; otherwise 120–200 words.
      Reply with JSON only: {"answer": "<the answer>"}
      """
    let user = "Question: \(q.label)\n\n\(documents.grounding)\n\nFacts:\n"
      + facts.sorted { $0.key < $1.key }.filter { !Self.nothing($0.value) }
        .map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    do {
      let reply = try await think.ask(system: system, user: user)
      guard let text = reply["answer"] as? String, text.count > 40 else { return nil }
      return text
    } catch {
      await log?.step(runId: "form", step: 0, detail: "draft failed: \(error)")
      return nil
    }
  }

  // MARK: - Doing it

  private func perform(
    _ q: FormQuestion, answer: Answer?, facts: [String: String], screen: inout Screen,
    app: String, task: TaskKind, towards direction: String, chosen: [String] = []
  ) async -> FieldOutcome {
    let web = screen.controls.first { $0.role == "WebArea" }?.id
    do {
      switch q.kind {
      case .text, .longText:
        guard case .text(let value) = answer else { return .init(label: q.label, state: .skipped(Self.noAnswer)) }
        if q.current == value { return .init(label: q.label, state: .filled(from: "already there")) }
        // Authorised as the typing it is: a question that says "share a story"
        // is not a Share button.
        try await press(
          q.controlID, name: q.controlName, web: web, task: task, direction: direction,
          verb: .typeText, value: value)
        if q.current != nil {
          // Selected first, so typing replaces rather than appends.
          _ = try? await engine.call("press_key", ["key": "a", "modifiers": ["cmd"]])
        }
        _ = try await engine.call("type_text", ["element_id": q.controlID, "text": value])
        if Self.looksLikeSearch(q.label) {
          screen = try await read(app)
          await pickSuggestion(for: value, after: q, in: screen, web: web, task: task)
          screen = try await read(app)
        }
        return .init(label: q.label, state: .filled(from: "typed"))

      case .select:
        try await press(q.controlID, name: q.controlName, web: web, task: task, direction: direction)
        try? await Task.sleep(for: .milliseconds(400))
        screen = try await read(app)
        var options = dropdownOptions(in: screen, after: q)
        if options.isEmpty {
          try? await Task.sleep(for: .milliseconds(700))
          screen = try await read(app)
          options = dropdownOptions(in: screen, after: q)
        }
        guard !options.isEmpty else {
          _ = try? await engine.call("press_key", ["key": "escape"])
          return .init(label: q.label, state: .skipped("the list did not open"))
        }
        let already = Set(chosen)
        var chosen: Control?
        if case .text(let value) = answer { chosen = bestOption(value, in: options) }
        if chosen == nil, let think, !Self.asksForGrades(q.label), !Self.personal(q.label) {
          // Not an option already picked in another dropdown: "Preference 2"
          // the same as "Preference 1" is refused by the page.
          let fresh = options.filter { !already.contains($0.name) }
          chosen = await pickOption(for: q.label, from: fresh, facts: facts, using: think)
        }
        guard let option = chosen else {
          _ = try? await engine.call("press_key", ["key": "escape"])
          screen = try await read(app)
          return .init(label: q.label, state: .skipped(Self.noAnswer))
        }
        try await press(option.id, name: option.name, web: web, task: task, direction: "down")
        screen = try await read(app)
        return .init(label: q.label, state: .filled(from: option.name))

      case .radio:
        guard case .one(let value) = answer,
          let option = q.options.first(where: { normalisedLabel($0.name) == normalisedLabel(value) })
        else { return .init(label: q.label, state: .skipped(Self.noAnswer)) }
        if !option.on {
          try await press(option.id, name: option.name, web: web, task: task, direction: direction)
        }
        return .init(label: q.label, state: .filled(from: option.name))

      case .checkbox:
        guard case .many(let values) = answer else { return .init(label: q.label, state: .skipped(Self.noAnswer)) }
        for value in values {
          guard let option = q.options.first(where: { normalisedLabel($0.name) == normalisedLabel(value) }),
            !option.on
          else { continue }
          try await press(option.id, name: option.name, web: web, task: task, direction: direction)
        }
        return .init(label: q.label, state: .filled(from: values.joined(separator: ", ")))

      case .date:
        guard case .date(let date) = answer, let d = date.day, let m = date.month, let y = date.year
        else { return .init(label: q.label, state: .skipped(Self.noAnswer)) }
        // Each segment clicked and typed on its own: a date field does not move
        // on to the next segment by itself, so typing all eight digits at once
        // put them all in the day.
        let parts = [("day", String(format: "%02d", d)), ("month", String(format: "%02d", m)),
                     ("year", String(format: "%04d", y))]
        for (segment, digits) in parts {
          guard let id = q.segments[segment] else { continue }
          try await press(id, name: q.label, web: web, task: task, direction: direction)
          for digit in digits { _ = try? await engine.call("press_key", ["key": String(digit)]) }
        }
        return .init(label: q.label, state: .filled(from: "\(d)/\(m)/\(y)"))
      }
    } catch {
      return .init(label: q.label, state: .skipped("\(error)"))
    }
  }

  /// Click something, scrolling towards it until the engine can reach it.
  ///
  /// The engine refuses anything off screen, clicks included, and element ids
  /// survive a scroll — so this scrolls in the likely direction and tries the
  /// same id again, and turns round if that does not find it.
  private func press(
    _ id: String, name: String, web: String?, task: TaskKind, direction: String,
    verb: Action.Verb = .click, value: String? = nil
  ) async throws {
    guard case .allow = authorize(Action(verb: verb, controlName: name, value: value), in: task)
    else { throw Engine.Failure.tool("'\(name)' is not something JevBar will press") }

    let plan = Array(repeating: direction, count: 14)
      + Array(repeating: direction == "down" ? "up" : "down", count: 30)
    for (attempt, way) in ([nil] + plan.map { Optional($0) }).enumerated() {
      if let way, let web {
        _ = try? await engine.call("scroll", ["element_id": web, "direction": way, "amount": 5])
        try? await Task.sleep(for: .milliseconds(80))
      }
      do {
        _ = try await engine.call("click", ["element_id": id])
        return
      } catch Engine.Failure.tool(let message) where message.contains("not visible") {
        if attempt == plan.count { throw Engine.Failure.tool(message) }
        continue
      }
    }
  }

  private func read(_ app: String) async throws -> Screen {
    let outline = try await engine.call("get_app_state", ["app": app, "max_elements": 2_000])
    return parseScreen(app: app, outline: outline)
  }

  /// The options a custom dropdown shows once opened: the pieces of text in the
  /// group the page adds straight after it. Native menu items are accepted too.
  private func dropdownOptions(in screen: Screen, after q: FormQuestion) -> [Control] {
    let all = screen.controls
    guard let at = position(of: q, in: screen)
    else { return all.filter { $0.role == "MenuItem" && !$0.name.isEmpty } }

    let depth = all[at].depth
    var options: [Control] = []
    var i = at + 1
    // Past the dropdown's own trigger button.
    while i < all.count, all[i].depth == depth, all[i].role == "Button" { i += 1 }
    guard i < all.count, all[i].role == "Group", all[i].depth == depth else {
      return all.filter { $0.role == "MenuItem" && !$0.name.isEmpty }
    }
    i += 1
    while i < all.count, all[i].depth > depth {
      let c = all[i]
      if c.role == "StaticText", !c.name.isEmpty, !isPlaceholder(c.name) { options.append(c) }
      i += 1
    }
    return options
  }

  /// Where a question's control sits in a fresh reading. By question, never by
  /// id: every reading renumbers ids, so an old id names some other control.
  private func position(of q: FormQuestion, in screen: Screen) -> Int? {
    guard let live = readQuestions(from: screen).first(where: { $0.locator == q.locator })
    else { return nil }
    return screen.controls.firstIndex { $0.id == live.controlID }
  }

  /// The option that means the same as an answer, most exact first.
  private func bestOption(_ value: String, in options: [Control]) -> Control? {
    let wanted = normalisedLabel(value)
    let squashed = wanted.replacingOccurrences(of: " ", with: "")
    let first = wanted.split(separator: " ").first.map(String.init) ?? wanted
    func n(_ c: Control) -> String { normalisedLabel(c.name) }
    return options.first { n($0) == wanted }
      // "Bachelor's Degree" against "Bachelors".
      ?? options.first { n($0).replacingOccurrences(of: " ", with: "") == squashed }
      ?? options.first { n($0).hasPrefix(wanted) || wanted.hasPrefix(n($0)) }
      ?? options.first { first.count > 3 && (n($0).hasPrefix(first) || first.hasPrefix(n($0))) && n($0).count > 3 }
      ?? options.first { n($0).contains(wanted) }
  }

  /// Ask the model which of a dropdown's own options answers it.
  private func pickOption(
    for question: String, from options: [Control], facts: [String: String], using think: Think
  ) async -> Control? {
    let listed = options.enumerated().map { "\($0.offset): \($0.element.name)" }.joined(separator: "\n")
    let profileText = facts.sorted { $0.key < $1.key }.filter { !Self.nothing($0.value) }
      .map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    let system = """
      You answer one multiple-choice question on a job application, for the applicant.
      Reply with JSON only: {"choice": <option number or null>}
      Facts about the applicant must be supported by the facts or CV; a
      preference (a role, team, office or date) may be chosen sensibly from the
      CV and the role. Never guess about family, salary, demographics, grades
      or grading scales — null.
      """
    let user = "Question: \(question)\n\nOptions:\n\(listed)\n\nFacts:\n\(profileText)\n\n\(String(documents.grounding.prefix(3_000)))"
    guard let reply = try? await think.ask(system: system, user: user),
      let index = reply["choice"] as? Int, options.indices.contains(index)
    else { return nil }
    return options[index]
  }

  /// Whether a text field is likely a search that wants a suggestion chosen.
  static func looksLikeSearch(_ label: String) -> Bool {
    let l = label.lowercased()
    return ["school", "university", "college", "institution", "employer", "company", "city",
            "location", "town"].contains { l.contains($0) }
  }

  /// Click the suggestion a search box offers for what was typed, if it offers one.
  private func pickSuggestion(
    for value: String, after q: FormQuestion, in screen: Screen, web: String?, task: TaskKind
  ) async {
    let all = screen.controls
    guard let at = position(of: q, in: screen) else { return }
    let wanted = normalisedLabel(value)
    let near = all[(at + 1)..<min(at + 16, all.count)]
    guard
      let suggestion = near.first(where: { c in
        ["Link", "StaticText", "MenuItem", "Cell", "Row"].contains(c.role)
          && normalisedLabel(c.name).hasPrefix(wanted)
      })
    else { return }
    try? await press(suggestion.id, name: suggestion.name, web: web, task: task, direction: "down")
  }
}

/// An answer, in the shape its question takes.
enum Answer {
  case text(String)
  case one(String)
  case many([String])
  case date(DateComponents)
}

/// A date written the ways a profile holds one: "1 October 2025", "2025-10-01",
/// "01/10/2025".
func parseDate(_ text: String) -> DateComponents? {
  let formats = ["d MMMM yyyy", "d MMM yyyy", "yyyy-MM-dd", "dd/MM/yyyy", "d/M/yyyy", "MMMM d, yyyy"]
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_GB")
  for format in formats {
    formatter.dateFormat = format
    if let date = formatter.date(from: text.trimmingCharacters(in: .whitespaces)) {
      return Calendar(identifier: .gregorian).dateComponents([.day, .month, .year], from: date)
    }
  }
  return nil
}
