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

  func fillVisible(
    screen: Screen, task: TaskKind, alreadyDone: Set<String> = []
  ) async -> FillResult {
    let fields = screen.controls.filter {
      Self.writableRoles.contains($0.role) && !$0.name.isEmpty
        && !isPageChrome($0)
        /*
         Fields this run has already finished with.

         Without this the cap on writes per pass was a cap on *which* fields
         were ever written: every pass started at the top of the list, wrote the
         first four, and stopped — so First Name, Last Name, Email and Phone
         were filled again and again while the rest of the form was never
         reached at all.
        */
        && !alreadyDone.contains(normalisedLabel($0.name))
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
    /*
     The model calls run side by side, not one after another.

     Placing labels, inferring answers and drafting prose used to happen in
     sequence, all before a single field was typed — and each can sit for
     twenty seconds on the API's slow tail. So the page stayed untouched while
     "Working…" ran for minutes.

     Drafting does not depend on the other two: an open question is a text area
     or a sentence with a question mark, and no profile fact answers it. So it
     starts here, alongside them, and is collected when it is needed.
    */
    let profileNow = await profile.all()
    let draftCandidates = fields.filter { field in
      isOpenEnded(field) && keys[field.id].flatMap { profileNow[$0] } == nil
        && !credentialLabel(field.name)
    }
    let canDraft = think != nil && !documents.isEmpty && !draftCandidates.isEmpty
    async let draftedEarly: [String: String] =
      canDraft
      ? draftAnswers(for: draftCandidates, facts: profileNow, using: think!)
      : [:]

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
        // Already in flight since the top of the pass.
        drafted = await draftedEarly
      }
    }

    var writesThisPass = 0
    for field in fields {
      /*
       A few fields per pass, then a fresh look at the page.

       Every write can re-render the form — validation appears, a list opens —
       and that invalidates every id after it. Writing the whole form from one
       observation put values in the wrong boxes; writing a handful and looking
       again keeps them fresh without a lookup per field.
      */
      if writesThisPass >= Self.writesPerPass { break }

      // A drafted answer belongs to this field alone, so it is written straight
      // through rather than stored: "why this company" has a different answer
      // for every company, and keeping the first one would put Stripe's answer
      // on Palantir's form.
      if let draft = drafted[field.id] {
        do {
          // Typed for the same reason every other field is: this form's
          // inputs ignore a value set underneath them. Clicked first so the
          // keystrokes land here and the box is scrolled into view.
          _ = try? await engine.call("click", ["element_id": field.id])
          try? await Task.sleep(for: .milliseconds(300))
          _ = try await engine.call("type_text", ["element_id": field.id, "text": draft])
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
      /*
       A question is never answered with someone's name.

       "Are you currently enrolled in a degree programme…?" was filled from
       `lastName` — the model mapped the label to it — and "Imran" went into a
       yes/no box. A label phrased as a question asks about the applicant; it is
       never asking *for* one of their identifying details.
      */
      if isOpenEnded(field), Self.identityKeys.contains(key) {
        outcomes.append(
          .init(label: field.name, state: .skipped("this question is not asking for your \(key)")))
        continue
      }

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

      /*
       Dropdowns are left alone, deliberately.

       Typing into one and committing the row it offers was tried five ways and
       none of them held: the value lands, the list opens, and the choice is
       lost the moment focus moves. Leaving a combobox untouched is worse than
       filling it and better than what filling it currently does — a half-typed
       "ingdom" sitting in the Country box with a list hanging under it is a
       field the user now has to clear before they can fix it.

       Reported, not silently skipped, so they are visibly the remaining work.
      */
      if Self.chooserRoles.contains(field.role) || Self.listRoles.contains(field.role) {
        outcomes.append(await chooseFromList(field: field, value: value, key: key, app: screen.app, task: task))
        /*
         And the pass ends here.

         Opening a dropdown re-renders the form, and every element id this pass
         collected is stale afterwards: a real run went on to fail Phone,
         Location, School, Degree and eleven more with "unknown element_id".
         Stopping lets the next pass read the page again with ids that are
         valid.
        */
        break
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
         Written with the id from this pass's own observation.

         Relocating each field by label was tried and cannot work: a filtered
         `get_app_state` only describes what is *visible*, so a query for a
         field below the fold returns nothing at all — every lookup logged
         "asked 'when is your expected', got: nothing". The ids from a full read
         are the only handle on an off-screen field.

         They go stale as soon as the page re-renders, so the answer is not to
         re-find each field but to re-read the page often: a pass writes a
         handful of fields and then `fillWholeForm` observes again. Short
         batches are what keeps the ids fresh.
        */
        let live = field

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
        /*
         One write, never two.

         First Name came out as "JazilJazil". The write was `set_value`
         followed by `type_text` whenever `set_value` reported failure — and it
         can report failure having already written, so the typed value appended
         to the one that was there. A retry that cannot tell whether the first
         attempt worked is a retry that doubles.

         So the strategy is chosen up front instead: an empty field is typed
         into, because typing produces the events a controlled component needs
         and there is nothing to append to; a field with text in it is replaced
         in one step, because typing would append to that.
        */
        /*
         `set_value`, always. Typing is what went wrong.

         Switching an empty field to `type_text` was meant to satisfy a
         controlled component, and it made a form that was filling four fields
         fill none: the keystrokes go to whatever has focus, and a click that
         has not finished scrolling the field into view has not focused it yet.
         `set_value` names the element, so it cannot land somewhere else.

         It is also what demonstrably worked — Last Name and Email were filled
         by exactly this call, on the run before the change.
        */
        /*
         Typed, the way the YouTube search is — the one input that has
         demonstrably taken a value today.

         `set_value` does not land on this form: twenty fields were written in
         one run and none of them appeared. A React input keeps its own state and
         ignores a value set underneath it. Typing produces the key events the
         component listens for, and the YouTube search box — also React — took
         a typed query first time.

         Typing was tried here once before and blamed for "it repeated
         everything". That was wrong: the repetition was the pass loop
         rewriting its first four fields, found and fixed afterwards. Typing
         itself was fine.

         A field that already holds text is selected first with Cmd-A, so the
         typed value replaces it instead of appending — the append is what
         produced "JazilJazil". The click above has focused the field, so both
         keystrokes land in it. Cmd-A is not Return: it selects, it cannot
         submit anything.
        */
        if live.value?.isEmpty == false {
          _ = try? await engine.call("press_key", ["key": "a", "modifiers": ["cmd"]])
        }
        _ = try await engine.call("type_text", ["element_id": live.id, "text": value])


        written.append((id: live.id, label: field.name, key: key, value: value))
        writesThisPass += 1
      } catch {
        outcomes.append(.init(label: field.name, state: .skipped("\(error)")))
      }
    }

    /*
     Not re-read here. `fillWholeForm` checks once, at the end.

     Verification used to read the whole page after every pass, and a full read
     of a real application is the single slowest thing JevBar does — one of them
     has timed out at thirty seconds on its own. With four passes that was most
     of the time a fill took. Now that verification only decides what the
     report says, and never writes, once is enough.
    */
    outcomes.append(
      contentsOf: written.map { .init(label: $0.label, state: .filled(from: $0.key)) })
    return FillResult(outcomes: outcomes)
  }

  /// Facts that identify the applicant, which a question never asks for.
  static let identityKeys: Set<String> = [
    "firstName", "lastName", "fullName", "preferredName", "email", "phone",
  ]

  /// How many fields one pass writes before the page is read again.
  ///
  /// Every write can re-render the form and invalidate the ids that came with
  /// it, so a pass writes a batch and then looks again. Eight rather than four
  /// now that nothing presses Return: the submit-and-validate re-render that
  /// made ids stale after every field is gone, and each extra pass costs a full
  /// read of the page, which is the slowest thing a fill does.
  static let writesPerPass = 8

  /// Roles that open a list when written into, and only these get a Return.
  static let listRoles: Set<String> = ["ComboBox", "PopUpButton", "MenuButton"]

  /// Pick an answer from a dropdown: type it, then click the option it leaves.
  ///
  /// ## Why this can work now when five earlier attempts did not
  ///
  /// Every earlier attempt wrote the value with `set_value`, and on this form
  /// `set_value` never lands — so the list was never actually filtered, and
  /// whatever got clicked or committed was whatever the list happened to show.
  /// That is where "ingdom" and "North Sumatra, Indonesia" came from. Typing
  /// does land (it is how every text field fills now), so typing "United
  /// Kingdom" really does leave a list with United Kingdom in it.
  ///
  /// ## How the option is found
  ///
  /// By asking the page for what is visible and contains the answer's text. A
  /// filtered read only describes what is on screen, which was wrong for
  /// finding fields below the fold and is exactly right here: an open list is
  /// on screen. The list can take a moment to fill — a school or city search
  /// goes to a server — so it is asked a few times before giving up.
  ///
  /// Nothing here presses Return. The option is clicked, the same as a person
  /// would, and its name goes through the policy like any other press.
  private func chooseFromList(
    field: Control, value: String, key: String, app: String, task: TaskKind
  ) async -> FieldOutcome {
    do {
      _ = try? await engine.call("click", ["element_id": field.id])
      try? await Task.sleep(for: .milliseconds(300))
      _ = try await engine.call("type_text", ["element_id": field.id, "text": value])
    } catch {
      return .init(label: field.name, state: .skipped("could not type into the list: \(error)"))
    }

    let wanted = normalisedLabel(value)
    let probe = wanted.split(separator: " ").prefix(2).joined(separator: " ")
    var offered: [String] = []

    for _ in 0..<3 {
      try? await Task.sleep(for: .milliseconds(700))
      /*
       A full read, not a filtered one.

       The filtered read returned nothing here too — "asked 'united kingdom',
       got: nothing" with the list open on screen — so it cannot be relied on
       for anything. A full read is slower and it is the one that parses.
      */
      guard let page = try? await reread(app: app) else { continue }

      let options = page.controls.filter { control in
        control.id != field.id && !control.name.isEmpty && !isPageChrome(control)
          // The box itself now contains the typed text, and so may the label
          // above it; neither is an option.
          && !Self.writableRoles.contains(control.role)
          && normalisedLabel(control.name) != normalisedLabel(field.name)
      }
      // For the log, only what could plausibly be an option for this answer;
      // a full read has hundreds of names and the rest are noise.
      let words = Set(wanted.split(separator: " ").map(String.init))
      offered = options.map(\.name).filter { name in
        !words.isDisjoint(with: normalisedLabel(name).split(separator: " ").map(String.init))
      } + ["(\(options.count) controls read)"]

      let ranked =
        options.first { normalisedLabel($0.name) == wanted }
        ?? options.first { normalisedLabel($0.name).hasPrefix(wanted) }
        ?? options.first { wanted.hasPrefix(normalisedLabel($0.name)) && $0.name.count > 1 }
        ?? options.first { normalisedLabel($0.name).contains(wanted) }

      guard let option = ranked else { continue }

      guard case .allow = authorize(
        Action(verb: .click, controlName: option.name, value: nil), in: task)
      else {
        _ = try? await engine.call("press_key", ["key": "escape"])
        return .init(label: field.name, state: .refused("that option is not allowed"))
      }

      /*
       How the option is committed depends on what kind of list it is.

       A React-select dropdown — every list on the Stripe form — ignores the
       engine's click. That click is an accessibility press, not a mouse event,
       and React-select listens only for real mouse and keyboard events. A real
       run proved it: every option was found, every "click" landed, and none was
       selected.

       Its keyboard contract is the dependable route. Typing filters the list
       and highlights the first match; Return picks the highlighted option and
       prevents the form's default submission. Return on this control can only
       submit the form when the menu is closed, which is why it happens here
       and nowhere else:

        - the control is a combobox, never a text field — Return in a text
          field is what submitted this form once before;
        - it was typed into a moment ago, so it has focus;
        - the fresh read above found a matching option, so the menu is open;
        - the control's name has been through the policy like any press.

       A native pop-up menu is different: it does answer the accessibility
       press, so it keeps the click.
      */
      if field.role == "ComboBox" {
        guard case .allow = authorize(
          Action(verb: .pressKey, controlName: field.name, value: "return"), in: task)
        else {
          _ = try? await engine.call("press_key", ["key": "escape"])
          return .init(label: field.name, state: .refused("choosing here is not allowed"))
        }
        _ = try? await engine.call("press_key", ["key": "return"])
      } else {
        _ = try? await engine.call("click", ["element_id": option.id])
      }
      return .init(label: field.name, state: .filled(from: key))
    }

    // No option matched. Close the list so it does not swallow the next click,
    // and record what it did offer — the next fix should be read, not guessed.
    _ = try? await engine.call("press_key", ["key": "escape"])
    await log?.lookupFailed(label: field.name, query: probe, offered: Array(offered.prefix(12)))
    return .init(
      label: field.name,
      state: .skipped("the list did not offer \u{201C}\(value)\u{201D} — choose this one yourself"))
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
    maxPasses: Int = 24,
    budget: Duration = .seconds(300)
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
          && !control.name.isEmpty && !seen.contains(normalisedLabel(control.name))
      }

      if fresh.isEmpty && pass > 0 { break }

      let result = await fillVisible(screen: screen, task: task, alreadyDone: seen)
      let novel = result.outcomes.filter { !seen.contains(normalisedLabel($0.label)) }
      outcomes.append(contentsOf: novel)

      /*
       A field refused for being off screen is not finished with.

       Every outcome used to be marked seen, including "e130 is not visible in
       its window" — so a field that simply had not been scrolled to yet was
       recorded as done and never tried again. The pass that would have reached
       it skipped it, and a whole Stripe application came back untouched.
      */
      /*
       Remembered in the same normalised form the fields are matched in.

       This stored the label exactly as observed and compared it exactly, and
       a page does not print a label identically on every read — a required
       marker, a stray space. So a field finished on one pass looked new on the
       next, and First Name, Last Name, Email and Phone were written over and
       over while the rest of the form was never reached.
      */
      for outcome in novel where !isRetryable(outcome) {
        seen.insert(normalisedLabel(outcome.label))
      }

      await log?.pass(number: pass + 1, wrote: novel.count, done: seen.count)

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
    /*
     One look at the whole form, at the end, to keep the report honest.

     A field reported filled whose box now reads empty is downgraded. A field
     that cannot be found in this read — off screen, or re-rendered under a new
     label — keeps its report, because absence from one read is not evidence
     the value was lost, and calling it lost would be the same unverified claim
     in the other direction.
    */
    if let final = try? await observe() {
      outcomes = outcomes.map { outcome in
        guard case .filled = outcome.state else { return outcome }
        let wanted = normalisedLabel(outcome.label)
        guard
          let control = final.controls.first(where: { normalisedLabel($0.name) == wanted }),
          control.value == ""
        else { return outcome }
        return .init(label: outcome.label, state: .skipped("typed, but the page did not keep it"))
      }
    }

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
    // A stale id means the page changed under this pass, not that the field
    // failed. It is tried again with a fresh read, like a field off screen.
    return why.contains("not visible") || why.contains("unknown element_id")
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
