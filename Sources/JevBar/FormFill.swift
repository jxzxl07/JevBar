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
  /// For recording why a lookup failed. Absent in tests, which have no log.
  var log: RunLog?

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

  /// Roles that hold a value but cannot be typed into.
  ///
  /// `School`, `Degree` and `Pronouns` on a real application came back as "the
  /// page would not keep this value", because a text write cannot set a
  /// dropdown at all. They are opened and the matching option is pressed —
  /// which is what a person does.
  static let chooserRoles: Set<String> = ["PopUpButton", "MenuButton", "Menu"]

  func fillVisible(screen: Screen, task: TaskKind) async -> FillResult {
    let fields = screen.controls.filter {
      Self.writableRoles.contains($0.role) && !$0.name.isEmpty
        && !isPageChrome($0)
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
    /*
     An array, not a dictionary, because a form is filled in its own order.

     This was keyed by element id, and a dictionary has no order — so the boxes
     were filled third, first, second, which looks broken even when every value
     is right. Document order is the order the fields were observed in.
    */
    var written: [(id: String, label: String, key: String, value: String)] = []
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

    /*
     Why a written question was not answered, when it was not.

     Drafting depends on three things being true at once — a model key, a CV to
     ground it, and a field recognised as wanting prose — and when any is
     missing the field simply came out as "nothing in your profile names this".
     That reads as the matcher failing, not as the CV never having been found,
     and the two need opposite fixes.
    */
    var draftingSkipped: String?
    if !openEnded.isEmpty {
      if think == nil {
        draftingSkipped = "no model is configured, so I could not write an answer"
      } else if documents.isEmpty {
        draftingSkipped = "I could not read your CV, so I had nothing to write from"
      } else {
        drafted = await draftAnswers(for: openEnded, facts: known, using: think!)
      }
    }

    for field in fields {
      // A drafted answer belongs to this field alone, so it is written straight
      // through rather than stored: "why this company" has a different answer
      // for every company, and keeping the first one would put Stripe's answer
      // on Palantir's form.
      if let draft = drafted[field.id] {
        do {
          _ = try await engine.call("set_value", ["element_id": field.id, "value": draft])
          written.append((id: field.id, label: field.name, key: "drafted", value: draft))
        } catch {
          outcomes.append(.init(label: field.name, state: .skipped("\(error)")))
        }
        continue
      }

      if isOpenEnded(field), drafted[field.id] == nil,
        openEnded.contains(where: { $0.id == field.id })
      {
        outcomes.append(
          .init(
            label: field.name,
            state: .skipped(
              draftingSkipped ?? "my CV does not support an answer to this, so I left it")))
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

      /*
       A value that cannot be right for this field is not written.

       A real Stripe application ended up with "No" in the Phone box — a yes/no
       answer that reached a field expecting digits, through a label the model
       mapped wrongly. Nothing downstream could catch it: the write succeeded,
       the page kept it, and it read back exactly as asked, so every check said
       filled.

       This is a shape check, not a validation: it refuses "No" for a phone and
       a sentence for an email, and lets everything plausible through. The cost
       of being wrong in one direction is a field left empty; in the other it is
       a wrong answer on a real application, under someone's name.
      */
      guard valueSuits(key: key, value: value) else {
        outcomes.append(
          .init(
            label: field.name,
            state: .skipped("the answer I have for this does not look like a \(key)")))
        continue
      }

      let decision = authorize(
        Action(verb: .setValue, controlName: field.name, value: value), in: task)
      if case .refuse(let why) = decision {
        outcomes.append(.init(label: field.name, state: .refused(why)))
        continue
      }

      if Self.chooserRoles.contains(field.role) {
        outcomes.append(await choose(value, in: field, task: task, key: key, app: screen.app))
        continue
      }

      do {
        /*
         No scrolling here. There is no "scroll this into view".

         `scroll` with an `element_id` moves *the nearest scrollable area
         around* that element — it is "scroll this pane", not
         `scrollIntoView`. Calling it per field simply pushed the page down
         five lines each time, so a form ended at its own footer and the only
         thing still writable was the page's language picker. Visibility is
         handled by `fillWholeForm`, which scrolls once per pass and looks
         again.
        */
        /*
         The field is found again, by label, immediately before it is written.

         Ids belong to one snapshot. The list of fields here was observed once,
         before anything was written, and every write re-renders the form —
         validation appears, a list opens, a row is chosen — which invalidates
         every id after it. Writing to a stale id writes into whatever now holds
         it, and the values land in the wrong boxes and append:

             First Name:  United KingdomJazil
             Last Name:   Southend-on-SeaImran
             Email:       jazil.imran@gmail.comjazil.imran@gmail.com

         That is a fresh observation per field, which is expensive and is the
         only thing that is correct. A label survives a re-render; an id does
         not.
        */
        guard let live = try await currentField(labelled: field.name, app: screen.app) else {
          outcomes.append(
            .init(label: field.name, state: .skipped("the field moved before I could write it")))
          continue
        }

        /*
         Clicked first, which is also what brings it into view.

         `set_value` refuses an element that is not visible — every field on a
         real form came back as "e130 is not visible in its window". `click`
         does not: it uses the accessibility press action, which works on an
         element that is scrolled out of view, and focusing a field is what
         makes a browser scroll to it. So the click is not only about focus; it
         is the only thing that makes the write possible at all.
        */
        _ = try? await engine.call("click", ["element_id": live.id])
        // The scroll that follows a focus takes a moment, and writing during it
        // is writing to something still moving.
        try? await Task.sleep(for: .milliseconds(250))

        // `set_value` replaces the whole field in one step rather than typing
        // into it, so there are no keystrokes to lose and nothing to append to.
        /*
         Every attempt at this field happens now, not on a later pass.

         The first pass used to click each field, fail to write it, and leave
         it — so the form was visibly *selected* four fields at a time with
         nothing typed, and only a later pass filled them in. Watching it do
         that is watching it fail and retry, which is not what it should look
         like and not what it should do.

         A field that refuses a written value gets a moment for its scroll to
         finish, then a second attempt, then a typed one — typing produces the
         events a controlled component listens for, and the field already has
         focus from the click above.
        */
        var wrote = false
        for attempt in 0..<2 where !wrote {
          if attempt > 0 { try? await Task.sleep(for: .milliseconds(400)) }
          wrote = (try? await engine.call(
            "set_value", ["element_id": live.id, "value": value])) != nil
        }
        if !wrote {
          _ = try await engine.call("type_text", ["element_id": live.id, "text": value])
        }

        // A list is committed by clicking the row it offers. Nothing is ever
        // typed into a form to make it commit — see `commitByClicking`.
        if Self.listRoles.contains(live.role) {
          _ = await commitByClicking(field: live, value: value, app: screen.app, task: task)
        }

        written.append((id: live.id, label: field.name, key: key, value: value))
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
    _ written: [(id: String, label: String, key: String, value: String)],
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
      return written.map {
        .init(label: $0.label, state: .skipped("written, but I could not check it landed"))
      }
    }

    // Lists were already committed, field by field, while they were open.
    let committed = after

    var outcomes: [FieldOutcome] = []
    var stubborn: [(id: String, label: String, key: String, value: String)] = []

    for write in written {
      /*
       Found by label, not by id.

       An id belongs to one snapshot, and committing a list or scrolling to a
       field re-renders the page and invalidates every id in it. Looking the
       field up by id after that finds nothing, the comparison fails, and a
       field that is visibly correct on screen is reported as "the page would
       not keep this value" — which is what happened to First Name, Email and
       Phone on a form where all three were plainly filled.
      */
      let now =
        committed.control(id: write.id)?.value
        ?? committed.controls.first { $0.name == write.label }?.value
      // A committed option often says more than was typed — "United Kingdom"
      // for "United", "Bachelor's Degree (BA)" for "Bachelor's Degree" — so a
      // prefix counts as landed.
      let landed =
        now == write.value
        || (now?.lowercased().hasPrefix(write.value.lowercased()) ?? false)
      if landed {
        outcomes.append(.init(label: write.label, state: .filled(from: write.key)))
      } else {
        stubborn.append((write.id, write.label, write.key, write.value))
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

    return outcomes
  }

  /// Roles that open a list when written into, and only these get a Return.
  static let listRoles: Set<String> = ["ComboBox", "PopUpButton", "MenuButton"]

  /// Click the row the list is offering, having just typed into the field.
  ///
  /// ## Why clicking and not Return
  ///
  /// Return was tried. In a text input it submits the form, and a Stripe
  /// application came back with "Last Name is required", "Select a country" and
  /// "Please enter your location" — validation errors, which a page only shows
  /// after a submission was attempted. It did that once per field.
  ///
  /// Clicking the row is what a person does and cannot submit anything: the
  /// thing being pressed is a row in a list, and its name is checked against
  /// the policy first, so a row that somehow read "Submit application" is
  /// refused like any other control.
  ///
  /// ## Why the row is matched by text
  ///
  /// Pressing the first row commits whatever the list happens to show, which on
  /// a slow autocomplete is still the previous query's answer — that is how
  /// "Southend-on-Sea" was once committed as "North Sumatra, Indonesia". The
  /// match is a prefix because the row says more than was typed: "United
  /// Kingdom +44" for "United Kingdom".
  private func commitByClicking(
    field: Control, value: String, app: String, task: TaskKind
  ) async -> Bool {
    // A list renders on the next frame; looking before it does finds nothing
    // and concludes there was nothing to commit.
    try? await Task.sleep(for: .milliseconds(500))

    // The rows of an open list, not the whole page: the same reason
    // `currentField` asks by query. A full read here costs as much as the fill.
    guard
      let outline = try? await engine.call(
        "get_app_state", ["app": app, "query": value, "max_elements": 60])
    else { return false }
    let open = parseScreen(app: app, outline: outline)

    /*
     The row that is showing, which is the one under the field.

     A prefix match was tried first and is too strict: a list offers "United
     Kingdom +44" for "United Kingdom" but also "Bachelor's Degree (BA)" for
     "Bachelor's", and a school picker rewrites what it shows entirely. Since
     the value was typed into the field a moment ago, the list is already
     filtered to it — so the first row it offers is the answer, and taking it
     is the same action as clicking the option just below the box.

     Matching is still tried first, because when it does match it is certain;
     the first row is the fallback rather than the rule.
    */
    let wanted = value.lowercased()
    let rows = open.controls.filter { control in
      control.id != field.id && Self.suggestionRoles.contains(control.role)
        && !control.name.isEmpty && !isPageChrome(control)
    }
    guard
      let row = rows.first(where: { $0.name.lowercased().hasPrefix(wanted) })
        ?? rows.first(where: { wanted.hasPrefix($0.name.lowercased()) })
        ?? rows.first
    else { return false }

    guard case .allow = authorize(
      Action(verb: .click, controlName: row.name, value: nil), in: task)
    else { return false }

    return (try? await engine.call("click", ["element_id": row.id])) != nil
  }

  /// Roles a page uses for the rows of an autocomplete.
  static let suggestionRoles: Set<String> = [
    "MenuItem", "Row", "Cell", "ListItem", "StaticText", "Link", "Button",
  ]

  /// Open a dropdown and press the option that matches.
  ///
  /// The match is on text, not position: pressing the first item commits
  /// whatever the menu happens to list first, which on a school picker is an
  /// arbitrary university. Exact first, then a prefix — "University of
  /// Cambridge" against a list offering "University of Cambridge (Cambridge,
  /// UK)".
  ///
  /// If nothing matches, the menu is dismissed rather than left hanging over
  /// the page: an open menu swallows the next click, so leaving one behind
  /// breaks every field after it.
  private func choose(
    _ value: String, in field: Control, task: TaskKind, key: String, app: String
  ) async -> FieldOutcome {
    guard case .allow = authorize(
      Action(verb: .click, controlName: field.name, value: nil), in: task)
    else {
      return .init(label: field.name, state: .refused("opening this control is not allowed"))
    }

    do {
      _ = try await engine.call("click", ["element_id": field.id])
    } catch {
      return .init(label: field.name, state: .skipped("could not open the list: \(error)"))
    }

    // A menu renders on the next frame, and reading before it does sees the
    // page underneath with no options on it.
    try? await Task.sleep(for: .milliseconds(450))

    guard let opened = try? await reread(app: app) else {
      await dismissMenu()
      return .init(label: field.name, state: .skipped("could not read the list"))
    }

    let wanted = value.lowercased()
    let candidates = opened.controls.filter { $0.id != field.id }
    let exact: Control? = candidates.first { $0.name.lowercased() == wanted }
    let prefixed: Control? = candidates.first { candidate in
      guard Self.optionRoles.contains(candidate.role) else { return false }
      return candidate.name.lowercased().hasPrefix(wanted)
    }
    let option: Control? = exact ?? prefixed

    guard let option else {
      await dismissMenu()
      return .init(
        label: field.name,
        state: .skipped("the list does not offer \u{201C}\(value)\u{201D}"))
    }

    guard case .allow = authorize(
      Action(verb: .click, controlName: option.name, value: nil), in: task)
    else {
      await dismissMenu()
      return .init(label: field.name, state: .refused("that option is not allowed"))
    }

    do {
      _ = try await engine.call("click", ["element_id": option.id])
      return .init(label: field.name, state: .filled(from: key))
    } catch {
      await dismissMenu()
      return .init(label: field.name, state: .skipped("could not choose it: \(error)"))
    }
  }

  /// Roles a dropdown uses for the things inside it.
  private static let optionRoles: Set<String> = [
    "MenuItem", "Row", "Cell", "ListItem", "StaticText", "Button",
  ]

  /// Close a menu that was opened and not used.
  ///
  /// An open menu swallows the next click, so a dropdown left hanging breaks
  /// every field after it rather than just its own.
  private func dismissMenu() async {
    _ = try? await engine.call("press_key", ["key": "escape"])
  }

  /// This field as it is *now*, found by the label that does not change.
  ///
  /// Asked for by label rather than read whole. `get_app_state` takes a `query`
  /// that filters to elements whose label contains the text, and on a page with
  /// four hundred and fifty controls that is the difference between a fill that
  /// finishes and one that does not: a full read of this form takes about
  /// thirty seconds, and doing it once per field left runs that never came
  /// back at all.
  private func currentField(labelled label: String, app: String) async throws -> Control? {
    /*
     Asked for by a few plain words, and matched loosely.

     Every field on a real Stripe application came back as "the field moved
     before I could write it" — not because anything moved, but because this
     searched for the label exactly as observed and compared it with `==`. Real
     labels carry a required marker and their own spacing: `Full name ✱`. A
     query containing that marker matches nothing, and an exact comparison then
     rejects the row even when the query happens to find it.

     So: search for the first few letters-only words, which is what the page
     actually prints, and compare on a normalised form.
    */
    let query = searchableWords(of: label)
    guard !query.isEmpty else { return nil }

    let outline = try await engine.call(
      "get_app_state", ["app": app, "query": query, "max_elements": 80])
    let found = parseScreen(app: app, outline: outline)

    let wanted = normalisedLabel(label)
    let writable = found.controls.filter {
      !isPageChrome($0) && (Self.writableRoles.contains($0.role) || Self.listRoles.contains($0.role))
    }

    if let exact = writable.first(where: { normalisedLabel($0.name) == wanted }) { return exact }

    /*
     Then a looser match, because a page does not always print a label twice
     the same way.

     A full read calls it "Location (City)" and a filtered read can call the
     same control "Location (City) *" or wrap it — and an equality test then
     says the field has gone. Containment either way round catches that without
     matching a different field, because the query has already narrowed the
     page to this label's own words.
    */
    if let loose = writable.first(where: { control in
      let name = normalisedLabel(control.name)
      return name.contains(wanted) || wanted.contains(name)
    }) {
      return loose
    }

    /*
     And if there is still nothing, say what the page did offer.

     "The field moved before I could write it" was true of a page that had
     changed and of a lookup that was simply wrong, and those need opposite
     fixes. Recording the names that came back turns the next run into an
     answer instead of another guess — which is how the missing `AX` prefix and
     the required marker were both found in one run each.
    */
    await log?.lookupFailed(
      label: label, query: query, offered: Array(found.controls.map(\.name).prefix(12)))
    return nil
  }

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

extension FormFill {
  /// Fill the whole form, not just the part that happens to be on screen.
  ///
  /// ## Why this loops
  ///
  /// The engine refuses an element it cannot see — `e71 is not visible in its
  /// window — scroll it into view` — which is right for a click and fatal for a
  /// form. A real Stripe application skipped five required fields for that
  /// reason alone, and the ones below the fold were never even offered.
  ///
  /// So: fill what is reachable, scroll a screenful, look again, and stop when
  /// a pass finds nothing new. Scrolling *between* passes rather than per field
  /// is what keeps this to a handful of round trips instead of one per box.
  ///
  /// ## How it knows it is finished
  ///
  /// By label, not by element id: ids belong to one snapshot and every scroll
  /// invalidates them, so counting ids would make the same field look new on
  /// every pass and loop forever. A pass that reports no label it has not seen
  /// before is the end of the form.
  func fillWholeForm(
    observe: () async throws -> Screen,
    task: TaskKind,
    maxPasses: Int = 8,
    budget: Duration = .seconds(180)
  ) async -> FillResult {
    var outcomes: [FieldOutcome] = []
    var seen: Set<String> = []

    /*
     A fill that runs out of time says so, rather than appearing to hang.

     A full read of a real Stripe application takes about thirty seconds, and
     doing one per field produced runs that never came back — the bar sat on
     "Working…" with no way to tell whether it was thinking or wedged. Reading
     by query fixed the cost; this makes the failure honest if anything else
     ever gets slow again.
    */
    let deadline = ContinuousClock.now + budget

    for pass in 0..<maxPasses {
      if ContinuousClock.now >= deadline {
        outcomes.append(
          .init(
            label: "the rest of the form",
            state: .skipped("I ran out of time before reaching these")))
        break
      }

      guard let screen = try? await observe() else { break }

      let fresh = screen.controls.filter { control in
        (Self.writableRoles.contains(control.role) || Self.chooserRoles.contains(control.role))
          && !control.name.isEmpty && !seen.contains(control.name)
      }

      if fresh.isEmpty && pass > 0 { break }

      let result = await fillVisible(screen: screen, task: task)
      let novel = result.outcomes.filter { !seen.contains($0.label) }
      outcomes.append(contentsOf: novel)

      /*
       A field refused for being off screen is not finished with.

       Every outcome used to be marked seen, including "e130 is not visible in
       its window" — so a field that simply had not been scrolled to yet was
       recorded as done and never tried again. The pass that would have reached
       it skipped it, and a whole Stripe application came back untouched.
      */
      for outcome in novel where !isRetryable(outcome) { seen.insert(outcome.label) }

      // Nothing new on this screenful and nowhere left to go.
      if novel.isEmpty && pass > 0 { break }

      do {
        _ = try await engine.call("scroll", ["direction": "down", "amount": 8])
      } catch {
        break
      }
      // A page scrolls on the next frame; reading before it does sees the same
      // fields again and ends the loop a screenful early.
      try? await Task.sleep(for: .milliseconds(500))
    }

    /*
     One outcome per field: the last one, which is the one that stuck.

     A field tried on three passes produces three outcomes — two "not visible"
     and one "filled" — and reporting all three would count the same box twice
     and make "filled 6 fields" meaningless.
    */
    var latest: [String: FieldOutcome] = [:]
    for outcome in outcomes { latest[outcome.label] = outcome }
    let ordered = outcomes.compactMap { outcome -> FieldOutcome? in
      guard let best = latest[outcome.label], best.label == outcome.label else { return nil }
      latest.removeValue(forKey: outcome.label)
      return best
    }
    return FillResult(outcomes: ordered)
  }

  /// Whether this outcome means "not yet", rather than "done".
  private func isRetryable(_ outcome: FieldOutcome) -> Bool {
    guard case .skipped(let why) = outcome.state else { return false }
    return why.contains("not visible")
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

/// Whether a value is the right *shape* for the fact it claims to answer.
///
/// Deliberately loose. It exists to catch a value that arrived through a wrong
/// mapping — "No" in a phone field — rather than to validate anyone's data, and
/// a check that rejected unusual but real answers would be worse than none.
func valueSuits(key: String, value: String) -> Bool {
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return false }

  // A yes or a no answers a question, never a field that wants a value.
  let yesNo = ["yes", "no", "n/a", "none"]
  let looksLikeAnAnswer = yesNo.contains(trimmed.lowercased())

  switch key {
  case "phone":
    return trimmed.filter(\.isNumber).count >= 7
  case "email":
    return trimmed.contains("@") && trimmed.contains(".")
  case "linkedin", "github", "portfolio":
    return trimmed.contains(".") && !trimmed.contains(" ")
  case "graduationYear", "educationStart", "educationEnd":
    return trimmed.contains { $0.isNumber }
  case "firstName", "lastName", "fullName", "preferredName", "location", "country",
    "citizenship", "university", "degree", "discipline":
    return !looksLikeAnAnswer
  default:
    return true
  }
}

/// A label reduced to what a page search can match: letters, digits, spaces.
///
/// Markers like `✱`, colons and stray spacing are what a form prints around a
/// label, not part of it, and a query containing one matches nothing.
func normalisedLabel(_ label: String) -> String {
  let plain = String(label.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
  return plain.split(separator: " ").map(String.init).joined(separator: " ")
}

/// The first few words of a label, for asking the page about it.
///
/// A few rather than all: a long question ("We are always aiming to keep our
/// school list inclusive…") is printed with line breaks and wrapping that no
/// exact query survives, while its opening words are stable.
func searchableWords(of label: String, count: Int = 4) -> String {
  normalisedLabel(label).split(separator: " ").prefix(count).joined(separator: " ")
}

/// Whether a control belongs to the page rather than to the form on it.
///
/// A Stripe application ends with the site's own footer, and that footer holds
/// a country picker labelled "United States. Choose your country". It is a
/// combobox with a country in it, so every test for "is this a form field"
/// said yes — and once the page had scrolled far enough, it was the only thing
/// still on screen. JevBar opened it and changed the site's language.
///
/// The distinguishing feature is not the role or the value but the phrasing: a
/// form field is labelled with the thing it wants, while page furniture is
/// labelled with an instruction to the reader.
func isPageChrome(_ control: Control) -> Bool {
  let label = control.name.lowercased()
  let furniture = [
    "choose your", "select your language", "change language", "change region",
    "skip to", "search this site", "cookie", "accept all", "manage preferences",
  ]
  return furniture.contains { label.contains($0) }
}

/// Whether a field's own label asks for a credential.
///
/// Checked alongside the key, because a label can ask for a password while
/// matching no key at all — and an unmatched field must not become a question
/// that stores one.
func credentialLabel(_ label: String) -> Bool {
  let words = Set(label.lowercased().split { !$0.isLetter }.map(String.init))
  return !words.isDisjoint(with: ["password", "passcode", "passkey", "otp", "pin"])
}
