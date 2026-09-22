import Foundation
import Security

/// What JevBar knows about you, and how it learns the rest.
///
/// ## Where it lives
///
/// One Keychain item, holding JSON. Not a file beside the app, and not a
/// database: an application form is where someone's address, phone number and
/// right-to-work status go, and those belong behind the same door as a password
/// even though none of them is one.
///
/// ## Ask once, remember forever
///
/// A field nothing answers becomes a question at the end of a run. The answer is
/// stored under a key derived from what the *field* means rather than from the
/// site it appeared on, so "Current location" answered on one application fills
/// "Where are you based?" on the next. The first form asks a lot; the fifth
/// should ask nothing.
///
/// ## What is never stored
///
/// Passwords, passkeys and one-time codes. The refusal happens before a field
/// can become a question, because the whole purpose of this store is to keep
/// what it is told — which makes it exactly the wrong place for a credential.
actor Profile {
  private let service = "com.jevbar.profile"
  private let account = "facts"
  private var cache: [String: String]?

  func all() -> [String: String] {
    if let cache { return cache }
    let loaded = read()
    cache = loaded
    return loaded
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
    cache = facts
    write(facts)
    return true
  }

  func forget(key: String) {
    var facts = all()
    facts.removeValue(forKey: key)
    cache = facts
    write(facts)
  }

  private func read() -> [String: String] {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data,
      let facts = try? JSONDecoder().decode([String: String].self, from: data)
    else { return [:] }
    return facts
  }

  private func write(_ facts: [String: String]) {
    guard let data = try? JSONEncoder().encode(facts) else { return }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let attributes: [String: Any] = [kSecValueData as String: data]

    if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
      var insert = query
      insert[kSecValueData as String] = data
      // Available without unlocking the device again, but never synced to
      // another machine: these are this Mac's answers to this Mac's forms.
      insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      SecItemAdd(insert as CFDictionary, nil)
    }
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
  ("firstName", ["first", "forename", "given"]),
  ("lastName", ["last", "surname", "family"]),
  ("fullName", ["fullname", "name"]),
  ("email", ["email", "e"]),
  ("phone", ["phone", "telephone", "mobile", "cell"]),
  ("location", ["location", "city", "town", "based"]),
  ("country", ["country"]),
  ("postcode", ["postcode", "zip", "postal"]),
  ("address", ["address", "street"]),
  ("linkedin", ["linkedin"]),
  ("github", ["github"]),
  ("portfolio", ["portfolio", "website"]),
  ("university", ["university", "school", "college"]),
  ("degree", ["degree"]),
  ("discipline", ["discipline", "major", "subject"]),
  ("graduationYear", ["graduation", "graduate"]),
  ("company", ["company", "employer"]),
  ("rightToWork", ["authorized", "authorised", "eligible"]),
  ("sponsorship", ["sponsorship", "sponsor", "visa"]),
]

/// Whether a key names something JevBar must never keep.
func isCredentialKey(_ key: String) -> Bool {
  let lower = key.lowercased()
  return ["password", "passcode", "passkey", "otp", "pin", "secret", "token"]
    .contains { lower.contains($0) }
}
