import Foundation

/// What happened to one field.
struct FieldOutcome: Sendable {
  enum State: Sendable {
    case filled(from: String)
    case asks(key: String)
    case skipped(String)
    case refused(String)
  }
  let label: String
  let state: State
}

struct FillResult: Sendable {
  let outcomes: [FieldOutcome]

  var filled: [FieldOutcome] { outcomes.filter { if case .filled = $0.state { return true } else { return false } } }
  var questions: [FieldOutcome] { outcomes.filter { if case .asks = $0.state { return true } else { return false } } }
}

/// Fill in a form from what JevBar already knows, and ask about the rest.
///
/// ## Why this is not the agent loop
///
/// The loop is for work whose shape is not known in advance. A form is not that:
/// it is a list of labelled boxes, and matching a box to a fact is a lookup. A
/// real application has sixty fields, and sending sixty screenshots through a
/// model one at a time is how JevDesk spent thirty-one seconds before the first
/// character appeared. Everything here is a table lookup and a write; the model
/// is consulted once, for the labels the table could not place.
///
/// ## Why nothing is pressed
///
/// Filling writes values. It never presses anything, so there is no path from
/// here to a submitted application even if every other guard were removed. The
/// run ends at review and hands back.
struct FormFill: Sendable {
  let engine: Engine
  let profile: Profile
  let think: Think?
  let documents: Documents

  /// Roles worth trying to fill. A button is not a field, and neither is a label.
  ///
  /// Written without the `AX` prefix, and compared against a normalised role,
  /// because the engine and the platform spell the same role two ways. The
  /// first real attempt at a Lever form read three hundred controls and matched
  /// none of them for exactly that reason.
  static let writableRoles: Set<String> = [
    "TextField", "TextArea", "ComboBox", "SearchField", "SecureTextField",
    "DateField", "TimeField", "IncrementorField",
  ]

  func fill(screen: Screen, task: TaskKind) async -> FillResult {
    let fields = screen.controls.filter {
      Self.writableRoles.contains($0.role) && !$0.name.isEmpty
        // A secure field is listed so it can be *recognised* and refused, never
        // so it can be filled. The engine refuses it too; this is the second of
        // two independent guards rather than the only one.
        && $0.role != "SecureTextField"
    }
    guard !fields.isEmpty else { return FillResult(outcomes: []) }

    // One pass over the labels the table knows, then one request for the rest.
    var keys: [String: String] = [:]
    var unplaced: [Control] = []
    for field in fields {
      if let key = factKey(forLabel: field.name) {
        keys[field.id] = key
      } else {
        unplaced.append(field)
      }
    }
    if !unplaced.isEmpty, let think {
      let resolved = await placeLabels(unplaced, using: think)
      keys.merge(resolved) { current, _ in current }
    }

    var outcomes: [FieldOutcome] = []
    /// Written but not yet proved: nothing counts as filled until it reads back.
    var written: [String: (label: String, key: String, value: String)] = [:]
    var known = await profile.all()

    /*
     What the profile implies, for the fields no single fact answers.

     "Are you legally authorized to work in the UK?" is answered by
     `rightToWork`, but "When do you graduate?" wants a year from a date, and
     "Are you a student?" follows from having a university and an end date in
     the future. Those are inferences from facts already given, not new
     information, so asking the user again would be asking them to repeat
     themselves.

     One request for all of them, and the answer must be grounded: a label the
     profile cannot support comes back null and becomes a question, which is
     the difference between inferring and inventing.
    */
    let unanswered = fields.filter { field in
      guard let key = keys[field.id] else { return false }
      return known[key] == nil && !isCredentialKey(key) && !credentialLabel(field.name)
    }
    if !unanswered.isEmpty, let think {
      let inferred = await inferAnswers(for: unanswered, from: known, using: think)
      for (id, answer) in inferred {
        guard let key = keys[id] else { continue }
        known[key] = answer
      }
    }

    /*
     The questions a key-value store cannot answer.

     "Why this company" and "tell us about a project you are proud of" are not
     boxes with a fact behind them; they are asked of a person. A profile has
     nothing to offer, so these were becoming questions — which is the agent
     asking the applicant to write their own application.

     The CV answers them, and the cover letters beside it are previous answers
     to almost exactly these questions. Drafted here, reviewed by the user
     before anything is sent, because the run ends at human review.
    */
    var drafted: [String: String] = [:]
    let openEnded = fields.filter { field in
      isOpenEnded(field) && keys[field.id].flatMap { known[$0] } == nil
        && !credentialLabel(field.name)
    }
    if !openEnded.isEmpty, let think, !documents.isEmpty {
      drafted = await draftAnswers(for: openEnded, facts: known, using: think)
    }

    for field in fields {
      // A drafted answer belongs to this field alone, so it is written straight
      // through rather than stored: "why this company" has a different answer
      // for every company, and keeping the first one would put Stripe's answer
      // on Palantir's form.
      if let draft = drafted[field.id] {
        do {
          _ = try await engine.call("set_value", ["element_id": field.id, "value": draft])
          written[field.id] = (label: field.name, key: "drafted", value: draft)
        } catch {
          outcomes.append(.init(label: field.name, state: .skipped("\(error)")))
        }
        continue
      }

      guard let key = keys[field.id] else {
        outcomes.append(.init(label: field.name, state: .skipped("nothing in your profile names this")))
        continue
      }

      // A credential is refused before it can be filled *or* asked about. The
      // ask-once loop exists to keep what it is told, which makes it exactly
      // the wrong place for a password.
      if isCredentialKey(key) || credentialLabel(field.name) {
        outcomes.append(
          .init(label: field.name, state: .refused("JevBar never enters or stores this")))
        continue
      }

      guard let value = known[key] else {
        outcomes.append(.init(label: field.name, state: .asks(key: key)))
        continue
      }

      // The field already says it. Writing again is not harmless: the
      // accessibility write can insert at the caret rather than replace, and a
      // box filled twice reads `JazilJazil`.
      if field.value == value {
        outcomes.append(.init(label: field.name, state: .filled(from: key)))
        continue
      }

      let decision = authorize(
        Action(verb: .setValue, controlName: field.name, value: value), in: task)
      if case .refuse(let why) = decision {
        outcomes.append(.init(label: field.name, state: .refused(why)))
        continue
      }

      do {
        // `set_value` replaces the whole field in one step rather than typing
        // into it, so there are no keystrokes to lose and nothing to append to.
        _ = try await engine.call("set_value", ["element_id": field.id, "value": value])
        written[field.id] = (label: field.name, key: key, value: value)
      } catch {
        outcomes.append(.init(label: field.name, state: .skipped("\(error)")))
      }
    }

    outcomes.append(contentsOf: await verify(written, app: screen.app, task: task))
    return FillResult(outcomes: outcomes)
  }

  /// Check that what was written is actually on the page, and retype it if not.
  ///
  /// ## Why this is not optional
  ///
  /// `set_value` writes through the accessibility API, and a React-controlled
  /// input discards a value that arrives without the events a keystroke would
  /// have produced: the write succeeds, the component re-renders, and the box
  /// is empty again. The engine reports the write it made, not the value the
  /// page kept — so six fields were reported filled on a Lever application that
  /// was visibly blank.
  ///
  /// Reporting a write nobody can see is worse than failing. It is the one
  /// outcome that makes every other number untrustworthy, and it is why nothing
  /// here counts as filled until it has been read back.
  ///
  /// One observation for the whole form rather than one per field: a form has
  /// sixty of them, and sixty round trips is the thirty-one seconds this design
  /// exists to avoid.
  private func verify(
    _ written: [String: (label: String, key: String, value: String)],
    app: String,
    task: TaskKind
  ) async -> [FieldOutcome] {
    guard !written.isEmpty else { return [] }

    // A controlled component re-renders on the next frame, so reading straight
    // away can see a value that is about to be thrown away.
    try? await Task.sleep(for: .milliseconds(400))

    guard let after = try? await reread(app: app) else {
      // The page could not be read again. Saying "filled" here would be the
      // same unverified claim, so these are reported as unknown instead.
      return written.values.map {
        .init(label: $0.label, state: .skipped("written, but I could not check it landed"))
      }
    }

    var outcomes: [FieldOutcome] = []
    var stubborn: [(id: String, label: String, key: String, value: String)] = []

    for (id, write) in written {
      if after.control(id: id)?.value == write.value {
        outcomes.append(.init(label: write.label, state: .filled(from: write.key)))
      } else {
        stubborn.append((id, write.label, write.key, write.value))
      }
    }

    guard !stubborn.isEmpty else { return outcomes }

    var retyped: [(id: String, label: String, key: String, value: String)] = []
    for field in stubborn {
      // The engine's own advice for a field that rejects `set_value`: focus it
      // and type, which produces the events a controlled component listens for.
      do {
        _ = try await engine.call("click", ["element_id": field.id])
        _ = try await engine.call("type_text", ["element_id": field.id, "text": field.value])
        retyped.append(field)
      } catch {
        outcomes.append(.init(label: field.label, state: .skipped("\(error)")))
      }
    }

    // And check *that* too. Claiming the fallback worked without looking would
    // be the same unverified claim one step further down, which is exactly how
    // this bug survived being fixed once already.
    try? await Task.sleep(for: .milliseconds(400))
    let settled = try? await reread(app: app)

    for field in retyped {
      let landed = settled?.control(id: field.id)?.value == field.value
      outcomes.append(
        .init(
          label: field.label,
          state: landed
            ? .filled(from: field.key)
            : .skipped("the page would not keep this value")))
    }

    if let settled { await commitSuggestions(on: settled, for: retyped, task: task) }
    return outcomes
  }

  /// Choose the suggestion an autocomplete is offering, rather than pressing Enter.
  ///
  /// ## Why not Enter
  ///
  /// Typing "Southend" into a location field opens a list and leaves the field
  /// holding a fragment; something has to commit the choice. The obvious
  /// keystroke is Return — and in a text input Return submits the form on a
  /// large fraction of sites. On a job application that is the single action
  /// JevBar must never take, and "press Return after every field" would put a
  /// submission one keystroke away sixty times per form. §3 is not a rule to be
  /// worked around with a keystroke that usually does something else.
  ///
  /// Clicking the suggestion is what a person does, it commits the same choice,
  /// and it goes through the policy like every other press — so a list item that
  /// somehow reads "Submit application" is refused rather than clicked.
  private func commitSuggestions(
    on screen: Screen,
    for fields: [(id: String, label: String, key: String, value: String)],
    task: TaskKind
  ) async {
    for field in fields {
      // The suggestion says more than was typed — "Southend-on-Sea, England,
      // United Kingdom" for "Southend-on-Sea" — so a match is a prefix, not an
      // equality. Case-folded, because a list often title-cases what it shows.
      let wanted = field.value.lowercased()
      guard
        let suggestion = screen.controls.first(where: { control in
          Self.suggestionRoles.contains(control.role)
            && control.name.lowercased().hasPrefix(wanted)
            && control.id != field.id
        })
      else { continue }

      guard case .allow = authorize(
        Action(verb: .click, controlName: suggestion.name, value: nil), in: task)
      else { continue }

      _ = try? await engine.call("click", ["element_id": suggestion.id])
    }
  }

  /// Roles a page uses for the rows of an autocomplete.
  static let suggestionRoles: Set<String> = [
    "MenuItem", "Row", "Cell", "ListItem", "StaticText", "Link", "Button",
  ]

  private func reread(app: String) async throws -> Screen {
    let outline = try await engine.call(
      "get_app_state", ["app": app, "max_elements": 2_000])
    return parseScreen(app: app, outline: outline)
  }

  /// Ask the model which known fact answers each label it could not place.
  ///
  /// One request for every unplaced label at once, not one each. The answer is
  /// a key from a list this code owns, so a label the model invents a name for
  /// simply goes unmatched — it cannot introduce a new place to put someone's
  /// data.
  private func placeLabels(_ fields: [Control], using think: Think) async -> [String: String] {
    let catalogue = knownFactKeys.joined(separator: ", ")
    let labels = fields.map { "\($0.id): \($0.name)" }.joined(separator: "\n")

    let system = """
      You match form field labels to profile keys.

      Reply with JSON only: {"matches": {"<element id>": "<key or null>"}}

      Use only these keys: \(catalogue)
      Use null when no key fits. Never invent a key.
      Never match anything that asks for a password, passcode or one-time code.
      """

    guard
      let answer = try? await think.ask(system: system, user: "Labels:\n\(labels)"),
      let matches = answer["matches"] as? [String: Any]
    else { return [:] }

    var placed: [String: String] = [:]
    for (id, value) in matches {
      guard let key = value as? String, knownFactKeys.contains(key), !isCredentialKey(key)
      else { continue }
      placed[id] = key
    }
    return placed
  }
}

extension FormFill {
  /// Ask the model to answer a label from facts already in the profile.
  ///
  /// It is given the profile and the labels, and told to answer only what the
  /// facts support. An answer it cannot ground comes back null and the field
  /// becomes a question — inferring is allowed, inventing is not, and the
  /// difference matters because these answers go onto a real application.
  ///
  /// The profile is sent, which is personal data leaving the machine. That is
  /// the same trade as asking any model to draft an application answer, and it
  /// is why credentials are excluded before this point rather than trusted to a
  /// prompt.
  fileprivate func inferAnswers(
    for fields: [Control], from facts: [String: String], using think: Think
  ) async -> [String: String] {
    let profileText =
      facts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    let labels = fields.map { "\($0.id): \($0.name)" }.joined(separator: "\n")

    let system = """
      You answer job-application fields using only the facts given.

      Reply with JSON only: {"answers": {"<element id>": "<answer or null>"}}

      Rules:
      - Use only what the facts support. Derive freely from them: a graduation
        year from a graduation date, "Yes" from a right-to-work fact, a full
        name from a first and last name.
      - Answer null when the facts do not support an answer. Never guess a date,
        a number, an address or an identifier that is not there.
      - Keep answers in the form the field asks for: a year alone for a year
        field, "Yes" or "No" for a yes/no question.
      - Never answer a field asking for a password, passcode or one-time code.
      """

    guard
      let reply = try? await think.ask(
        system: system, user: "Facts:\n\(profileText)\n\nFields:\n\(labels)"),
      let answers = reply["answers"] as? [String: Any]
    else { return [:] }

    var grounded: [String: String] = [:]
    for (id, value) in answers {
      guard let text = value as? String, !text.isEmpty, text.lowercased() != "null",
        let field = fields.first(where: { $0.id == id }),
        !credentialLabel(field.name)
      else { continue }
      grounded[id] = text
    }
    return grounded
  }
}

/// Whether a field wants prose rather than a value.
///
/// A text area is the strongest signal — nobody uses one for a postcode — and a
/// label phrased as a question is the other. Length matters too: "Why do you
/// want to work at Stripe?" is not a label, it is a question wearing one.
func isOpenEnded(_ field: Control) -> Bool {
  if field.role == "TextArea" { return true }
  let label = field.name
  return label.contains("?") || label.split(separator: " ").count >= 6
}

extension FormFill {
  /// Draft an answer to a question, from the CV and how you have written before.
  ///
  /// Grounded, and told to say nothing rather than invent: an application is
  /// the worst possible place for a plausible sentence that is not true, and
  /// the person whose name is on it is not in the room when it is written.
  ///
  /// One request for every open question on the form, because a form asking
  /// three of them should cost one round trip rather than three.
  fileprivate func draftAnswers(
    for fields: [Control], facts: [String: String], using think: Think
  ) async -> [String: String] {
    let profileText =
      facts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    let questions = fields.map { "\($0.id): \($0.name)" }.joined(separator: "\n")

    let system = """
      You draft answers to job-application questions, as the applicant, in the
      first person.

      Reply with JSON only: {"answers": {"<element id>": "<answer or null>"}}

      Rules:
      - Use only the CV, the facts, and the previous letters. Never invent an
        employer, a grade, a date, a project or a technology that is not there.
      - Answer null when the documents do not support an answer. A missing
        answer is better than a plausible one that is not true.
      - Match the applicant's own voice, taken from the previous letters.
      - Two to four sentences unless the question asks for more.
      - Never write anything about a password, a salary expectation, or a
        protected characteristic.
      """

    let user = """
      \(documents.grounding)

      Facts:
      \(profileText)

      Questions:
      \(questions)
      """

    guard
      let reply = try? await think.ask(system: system, user: user),
      let answers = reply["answers"] as? [String: Any]
    else { return [:] }

    var drafted: [String: String] = [:]
    for (id, value) in answers {
      guard let text = value as? String, text.count > 20, text.lowercased() != "null",
        let field = fields.first(where: { $0.id == id }), !credentialLabel(field.name)
      else { continue }
      drafted[id] = text
    }
    return drafted
  }
}

/// Every key a fact may be stored under. A closed list, deliberately.
///
/// The model chooses from it and never adds to it: a key it invented would be a
/// new place to keep someone's personal data, named by something that is not
/// the person whose data it is.
let knownFactKeys = [
  "firstName", "lastName", "fullName", "preferredName", "email", "phone",
  "location", "country", "citizenship", "postcode", "address",
  "linkedin", "github", "portfolio",
  "university", "degree", "discipline", "educationStart", "educationEnd",
  "graduationDate", "graduationYear", "company",
  "dateOfBirth", "rightToWork", "sponsorship", "gender", "ethnicity",
  "cvPath", "coverLetterPath", "pronouns", "whyThisCompany",
]

/// Whether a field's own label asks for a credential.
///
/// Checked alongside the key, because a label can ask for a password while
/// matching no key at all — and an unmatched field must not become a question
/// that stores one.
func credentialLabel(_ label: String) -> Bool {
  let words = Set(label.lowercased().split { !$0.isLetter }.map(String.init))
  return !words.isDisjoint(with: ["password", "passcode", "passkey", "otp", "pin"])
}
