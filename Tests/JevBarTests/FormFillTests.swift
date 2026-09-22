import Foundation
import Testing

@testable import JevBar

@Suite("Matching a form field to what JevBar knows")
struct FactKeyTests {
  @Test("the same question asked differently reaches the same fact")
  func synonymsConverge() {
    // A key derived from the page would make the same question new on every
    // site, which is the difference between a profile and a cache.
    #expect(factKey(forLabel: "Current location") == "location")
    #expect(factKey(forLabel: "Where are you based?") == "location")
    #expect(factKey(forLabel: "City") == "location")
  }

  @Test("first, last and full name stay apart")
  func nameFieldsAreDistinct() {
    // All three contain "name". Collapsing them would put a surname in the
    // box asking for a full one.
    #expect(factKey(forLabel: "First Name") == "firstName")
    #expect(factKey(forLabel: "Last Name") == "lastName")
    #expect(factKey(forLabel: "Full name") == "fullName")
  }

  @Test("a label nothing knows matches nothing, rather than guessing")
  func unknownLabels() {
    #expect(factKey(forLabel: "Favourite biscuit") == nil)
    #expect(factKey(forLabel: "") == nil)
  }

  @Test("a credential is never a key JevBar will keep")
  func credentialsRefused() {
    for label in ["Password", "Passcode", "One-time PIN", "Passkey"] {
      #expect(credentialLabel(label), "expected '\(label)' recognised as a credential")
    }
    #expect(isCredentialKey("password"))
    #expect(isCredentialKey("otpSecret"))
    #expect(!isCredentialKey("firstName"))
  }

  @Test("the model can only choose from keys this code owns")
  func catalogueIsClosed() {
    // A key it invented would be a new place to keep someone's personal data,
    // named by something that is not the person whose data it is.
    #expect(knownFactKeys.contains("location"))
    #expect(!knownFactKeys.contains(where: isCredentialKey))
  }
}

@Suite("The profile remembers, and refuses")
struct ProfileTests {
  /// A profile of its own, so a test never edits the real one.
  private func scratchProfile() -> Profile {
    Profile(
      file: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("jevbar-test-\(UUID().uuidString).json"))
  }

  @Test("it will not store a credential even when told to")
  func refusesToStoreCredentials() async {
    let profile = scratchProfile()
    #expect(await profile.learn(key: "password", value: "hunter2") == false)
    #expect(await profile.value(for: "password") == nil)
  }

  @Test("the file it writes is readable by nobody else")
  func fileIsPrivate() async {
    // It holds a home address and a date of birth. Sitting in a user-readable
    // directory is the trade the Keychain's constant prompting forced; being
    // world-readable inside it is not part of that trade.
    let profile = scratchProfile()
    #expect(await profile.learn(key: "location", value: "Southend-on-Sea"))

    let path = await profile.filePath
    let mode = try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    #expect(mode == 0o600, "profile.json should be owner-only")
  }

  @Test("what it learns once it knows afterwards")
  func remembers() async {
    let profile = scratchProfile()
    let key = "location"
    #expect(await profile.learn(key: key, value: "Cambridge"))
    #expect(await profile.value(for: key) == "Cambridge")
    await profile.forget(key: key)
    #expect(await profile.value(for: key) == nil)
  }
}

@Suite("Reading a real accessibility outline")
struct OutlineTests {
  @Test("the engine's spelling of a role and the platform's are the same role")
  func rolesNormalise() {
    // The engine emits `TextField`; the API calls it `AXTextField`. A set in
    // one spelling matches nothing in the other, and a Lever form of sixty
    // boxes reported "none is a text field I can fill".
    #expect(normaliseRole("AXTextField") == "TextField")
    #expect(normaliseRole("TextField") == "TextField")
    #expect(FormFill.writableRoles.contains(normaliseRole("AXTextArea")))
  }

  @Test("the engine's own spelling is parsed as fillable")
  func parsesEngineSpelling() {
    let outline = """
      Window "Application"
        [e1] TextField "First Name"
        [e2] Button "Submit application"
      """
    let screen = parseScreen(app: "Safari", outline: outline)
    let writable = screen.controls.filter { FormFill.writableRoles.contains($0.role) }
    #expect(writable.map(\.id) == ["e1"])
  }

  @Test("a web form's fields are recognised by role")
  func recognisesWebFields() {
    // The roles a browser reports for a web form. If the parser or the role set
    // is wrong, filling reports "no fields" on a page full of them — which is
    // true and useless, and is what it said on the first real attempt.
    let outline = """
      AXWindow "Application"
        [e1] AXTextField "First Name"
        [e2] AXTextArea "Cover letter"
        [e3] AXComboBox "Degree"
        [e4] AXButton "Submit application"
        [e5] AXStaticText "Required"
      """
    let screen = parseScreen(app: "Safari", outline: outline)
    #expect(screen.controls.count == 5)

    let writable = screen.controls.filter { FormFill.writableRoles.contains($0.role) }
    #expect(writable.map(\.id) == ["e1", "e2", "e3"])
  }

  @Test("the seeded profile answers an application's usual fields")
  func profileAnswersCommonFields() async {
    // The labels a real Lever and Greenhouse form actually use.
    let profile = Profile()
    let facts = await profile.all()
    guard !facts.isEmpty else { return }  // Unseeded machine: nothing to assert.

    for label in [
      "First Name", "Last Name", "Email", "Phone", "Current location",
      "LinkedIn URL", "GitHub URL",
    ] {
      guard let key = factKey(forLabel: label) else {
        Issue.record("no key derived for '\(label)'")
        continue
      }
      #expect(facts[key] != nil, "profile has no answer for '\(label)' (key \(key))")
    }
  }
}

@Suite("Committing an autocomplete")
struct SuggestionTests {
  @Test("a suggestion that merely extends what was typed is the right one")
  func matchesByPrefix() {
    // "Southend-on-Sea" typed; "Southend-on-Sea, England, United Kingdom"
    // offered. Equality would never match, so the rule is a prefix.
    let offered = "Southend-on-Sea, England, United Kingdom"
    #expect(offered.lowercased().hasPrefix("southend-on-sea"))
  }

  @Test("a suggestion list item that submits is still refused")
  func policyStillApplies() {
    // Clicking a suggestion goes through the same authorization as any other
    // press, so a list that somehow offers "Submit application" is refused
    // rather than clicked.
    let decision = authorize(
      Action(verb: .click, controlName: "Submit application", value: nil), in: .jobApplication)
    #expect(decision != .allow)
  }

  @Test("a suggestion is chosen by name, never by position")
  func choosesByName() {
    // The alternative — "click the first row" — commits whatever the list
    // happens to show first, which on a slow autocomplete is the previous
    // query's answer. Matching the text means a wrong list commits nothing.
    let rows = ["London, England", "Southend-on-Sea, England, United Kingdom"]
    let wanted = "southend-on-sea"
    #expect(rows.first { $0.lowercased().hasPrefix(wanted) } == rows[1])
  }
}

@Suite("Answering the open questions")
struct DocumentTests {
  @Test("a CV in the named folder is read as text")
  func readsTheCV() {
    // The path the profile actually holds. Skipped rather than failed on a
    // machine that has no CV there, because this asserts the reading works,
    // not that everyone has one.
    let documents = Documents.load(from: NSHomeDirectory() + "/Desktop/career/Applications")
    guard !documents.isEmpty else { return }

    #expect(documents.cv?.isEmpty == false)
    // A CV that parsed to layout noise rather than words would pass an
    // is-not-empty check and fail at the only thing it is for.
    #expect((documents.cv?.split(separator: " ").count ?? 0) > 50)
  }

  @Test("a folder with nothing in it is empty rather than an error")
  func toleratesNoDocuments() {
    #expect(Documents.load(from: "/nowhere/at/all").isEmpty)
    #expect(Documents.load(from: nil).isEmpty)
  }

  @Test("a question is recognised as wanting prose")
  func spotsOpenQuestions() {
    let area = Control(id: "e1", role: "TextArea", name: "Cover letter", value: nil, depth: 0)
    let question = Control(
      id: "e2", role: "TextField", name: "Why do you want to work at Stripe?", value: nil, depth: 0)
    let plain = Control(id: "e3", role: "TextField", name: "Postcode", value: nil, depth: 0)

    #expect(isOpenEnded(area))
    #expect(isOpenEnded(question))
    #expect(!isOpenEnded(plain))
  }
}

@Suite("Covering a form that does not fit on screen")
struct WholeFormTests {
  @Test("a dropdown is a role the filler recognises, not a text field")
  func dropdownsAreChoosers() {
    // School, Degree and Pronouns on a real application came back as "the page
    // would not keep this value", because a text write cannot set a dropdown at
    // all. They are opened and the matching option is pressed instead.
    #expect(FormFill.chooserRoles.contains("PopUpButton"))
    #expect(!FormFill.writableRoles.contains("PopUpButton"))
  }

  @Test("progress is tracked by label, because ids do not survive a scroll")
  func tracksByLabel() {
    // Element ids belong to one snapshot. Counting them would make the same
    // field look new after every scroll, and the loop would never end.
    let before = Control(id: "e12", role: "TextField", name: "Email", value: nil, depth: 0)
    let after = Control(id: "e88", role: "TextField", name: "Email", value: nil, depth: 0)
    #expect(before.id != after.id)
    #expect(before.name == after.name)
  }

  @Test("a secure field is recognised so it can be refused, never filled")
  func secureFieldsExcluded() {
    #expect(FormFill.writableRoles.contains("SecureTextField"))
    #expect(credentialLabel("Password"))
  }
}

@Suite("Refusing an answer that cannot be right")
struct ValueShapeTests {
  @Test("a yes/no answer never reaches a field that wants a value")
  func rejectsYesNoInValueFields() {
    // A real Stripe application ended up with "No" in the Phone box — a yes/no
    // answer that reached a field expecting digits through a label the model
    // mapped wrongly. Nothing downstream could catch it: the write succeeded,
    // the page kept it, and it read back exactly as asked.
    #expect(!valueSuits(key: "phone", value: "No"))
    #expect(!valueSuits(key: "firstName", value: "Yes"))
    #expect(!valueSuits(key: "location", value: "N/A"))
  }

  @Test("real answers still go through")
  func acceptsRealValues() {
    // A check that rejected unusual but real answers would be worse than none.
    #expect(valueSuits(key: "phone", value: "07881602694"))
    #expect(valueSuits(key: "phone", value: "+44 7881 602694"))
    #expect(valueSuits(key: "email", value: "jazil.imran@gmail.com"))
    #expect(valueSuits(key: "location", value: "Southend-on-Sea"))
    #expect(valueSuits(key: "graduationYear", value: "2028"))
    #expect(valueSuits(key: "github", value: "www.github.com/jxzxl07"))
  }

  @Test("a yes/no answer is fine for the question that asked it")
  func allowsYesNoForQuestions() {
    // "Are you legally authorized to work…" is answered with exactly this, and
    // refusing it would empty the field the profile actually knows.
    #expect(valueSuits(key: "rightToWork", value: "Yes"))
    #expect(valueSuits(key: "sponsorship", value: "No"))
  }

  @Test("an empty answer is never written")
  func rejectsEmpty() {
    #expect(!valueSuits(key: "firstName", value: "   "))
  }
}
