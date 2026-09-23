import Foundation

/// What JevBar knows about you, and how it learns the rest.
///
/// ## Where it lives, and why not the Keychain
///
/// A file in the app's own support directory, readable only by you.
///
/// The Keychain was the first answer and it was wrong in practice. macOS
/// prompts for the login password whenever an application that is not on an
/// item's access list reads it, and getting an application *onto* that list
/// non-interactively needs the login password too. The result was a prompt on
/// every single form — which trains the habit of typing a password at whatever
/// asks, and that is a worse outcome than where the file sits.
///
/// The facts here are personal but they are not secrets: a name, an email, a
/// university, a graduation year. The one thing that genuinely is a secret — a
/// password, a passkey, a one-time code — is refused before it can be stored,
/// so the store that would need protecting never holds anything that needs it.
/// The file is 0600 and sits beside the API keys, which is the same trade
/// already made for those.
///
/// ## Ask once, remember forever
///
/// A field nothing answers becomes a question at the end of a run. The answer
/// is stored under a key derived from what the *field* means rather than from
/// the site it appeared on, so "Current location" answered on one application
/// fills "Where are you based?" on the next. The first form asks a lot; the
/// fifth should ask nothing.
actor Profile {
  private let file: URL

  init(file: URL = supportDirectory().appendingPathComponent("profile.json")) {
    self.file = file
  }

  /// Read fresh each time: the file is small, and a person may have just
  /// edited it from the bar's Profile button.
  func all() -> [String: String] {
    read()
  }

  func value(for key: String) -> String? {
    all()[key]
  }

  /// Remember an answer. Refuses a credential even when asked directly.
  @discardableResult
  func learn(key: String, value: String) -> Bool {
    guard !isCredentialKey(key) else { return false }
    var facts = all()
    facts[key] = value
    write(facts)
    return true
  }

  /// Where the facts are, for a test that checks how they are protected.
  var filePath: String { file.path }

  func forget(key: String) {
    var facts = all()
    facts.removeValue(forKey: key)
    write(facts)
  }

  private func read() -> [String: String] {
    guard let data = try? Data(contentsOf: file),
      let facts = try? JSONDecoder().decode([String: String].self, from: data)
    else { return [:] }
    return facts
  }

  private func write(_ facts: [String: String]) {
    guard
      let data = try? JSONEncoder(sortingKeys: true).encode(facts)
    else { return }
    try? data.write(to: file, options: [.atomic, .completeFileProtection])
    // Readable by this user alone. Written every time rather than once at
    // creation, because an atomic write replaces the file and its mode with it.
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
}

extension JSONEncoder {
  /// Sorted keys, so the file is readable and a diff means something.
  fileprivate convenience init(sortingKeys: Bool) {
    self.init()
    if sortingKeys { outputFormatting = [.prettyPrinted, .sortedKeys] }
  }
}

/// A key for a field, derived from what it means rather than where it appeared.
///
/// "Current location", "Your location" and "Where are you based?" all become
/// `location`, so answering one answers the others — on any site, forever. A key
/// derived from the page would make the same question new every time, which is
/// the difference between a profile and a cache.
func factKey(forLabel label: String) -> String? {
  let words = Set(
    label.lowercased().split { !$0.isLetter }.map(String.init))
  guard !words.isEmpty else { return nil }

  for (key, synonyms) in knownFields where !words.isDisjoint(with: synonyms) {
    // "Full name" and "First name" share "name", so the more specific keys are
    // tried by how many of their words match rather than in dictionary order.
    if key == "fullName", words.contains("first") || words.contains("last") { continue }
    return key
  }
  return nil
}

private let knownFields: [(String, Set<String>)] = [
  // First: "Preferred name" also says "name", and is not the full name.
  ("preferredName", ["preferred"]),
  // Before lastName: "family members" is not "family name".
  ("familyAtCompany", ["relatives", "relative", "members"]),
  ("firstName", ["first", "forename", "given"]),
  ("lastName", ["last", "surname", "family"]),
  ("fullName", ["fullname", "name"]),
  ("email", ["email", "e"]),
  ("phone", ["phone", "telephone", "mobile", "cell"]),
  ("location", ["location", "city", "town", "based"]),
  ("country", ["country"]),
  ("postcode", ["postcode", "zip", "postal"]),
  ("address", ["address", "street"]),
  ("linkedin", ["linkedin", "link"]),
  ("github", ["github"]),
  ("portfolio", ["portfolio", "website"]),
  ("university", ["university", "school", "college"]),
  ("degree", ["degree"]),
  ("discipline", ["discipline", "major", "subject"]),
  ("graduationYear", ["graduation", "graduate"]),
  ("company", ["company", "employer"]),
  ("rightToWork", ["authorized", "authorised", "eligible"]),
  ("sponsorship", ["sponsorship", "sponsor", "visa"]),
  ("dateOfBirth", ["birth", "dob", "birthday"]),
  ("citizenship", ["citizenship", "nationality", "citizen"]),
  ("educationStart", ["start"]),
  ("educationEnd", ["end"]),
  ("gender", ["gender"]),
  ("ethnicity", ["ethnicity", "race"]),
  ("pronouns", ["pronouns"]),
]

/// Whether a key names something JevBar must never keep.
func isCredentialKey(_ key: String) -> Bool {
  let lower = key.lowercased()
  return ["password", "passcode", "passkey", "otp", "pin", "secret", "token"]
    .contains { lower.contains($0) }
}
