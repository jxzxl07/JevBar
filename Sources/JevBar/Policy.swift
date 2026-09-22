import Foundation

/// What a run is for. Some refusals only apply inside an application.
enum TaskKind: String, Sendable {
  case general
  case jobApplication
}

/// An effect JevBar is about to have on the world.
struct Action: Sendable {
  enum Verb: String, Sendable {
    case click, typeText, setValue, pressKey, scroll, activateApp, screenshot, readState
  }

  let verb: Verb
  /// The accessible name JevBar read from the tree. Never a model's wording.
  let controlName: String
  /// The text about to be written, when there is any.
  let value: String?
}

enum Decision: Equatable, Sendable {
  case allow
  case refuse(String)
}

/// Whether an action may happen. A pure function, deliberately.
///
/// ## Why this is not a method on anything
///
/// Every refusal below is a product commitment, and a commitment that depends on
/// object state is one that can be arranged into being true. Taking the action
/// and the task and returning a decision means the whole contract can be read in
/// one screen and tested without a screen at all.
///
/// ## Why names come from the tree
///
/// `controlName` is what JevBar read from the accessibility tree, never what a
/// model called something. A model that wanted to submit an application could
/// otherwise describe the button as "Continue" and be believed. The name is
/// evidence; the model's opinion is not.
func authorize(_ action: Action, in task: TaskKind) -> Decision {
  if let refusal = credentialRefusal(action) { return .refuse(refusal) }

  if action.verb == .click, task == .jobApplication,
    looksLikeFinalSubmit(action.controlName)
  {
    return .refuse(
      "'\(action.controlName)' looks like it submits the application. JevBar fills it in and "
        + "stops; sending it is yours.")
  }

  if action.verb == .click, looksLikeCommunication(action.controlName) {
    return .refuse(
      "'\(action.controlName)' would send something to another person, which JevBar never does. "
        + "It prepares; you send.")
  }

  return .allow
}

/// A password, passkey or one-time code. Refused in every task, always.
///
/// The engine also refuses secure text fields, so this is the second of two
/// independent guards rather than the only one. It is here as well because the
/// engine's refusal is about the *field*, and this one is about the *intent* —
/// a command that asks for a password is refused before anything is typed
/// anywhere.
private func credentialRefusal(_ action: Action) -> String? {
  guard action.verb == .typeText || action.verb == .setValue else { return nil }
  guard credentialPattern.matches(action.controlName) else { return nil }
  return "JevBar never enters a password, passkey or one-time code. That one is yours to type."
}

private let credentialPattern = Pattern([
  "password", "passcode", "passkey", "one-time code", "one time code", "otp",
  "security code", "verification code", "pin",
])

/// Controls that end an application. Deliberately narrow.
///
/// "Continue", "Next" and "Save draft" are *not* here: a multi-page application
/// cannot be filled at all if moving between its pages is refused, and refusing
/// them would make the agent useless rather than safe. What is refused is the
/// control that ends the process.
private func looksLikeFinalSubmit(_ name: String) -> Bool {
  finalSubmitPattern.matches(name)
}

private let finalSubmitPattern = Pattern([
  "submit application", "submit my application", "submit", "apply now",
  "send application", "finish and submit", "complete application",
  "complete my application",
])

/// Controls that transmit to another person. Refused in every task.
private func looksLikeCommunication(_ name: String) -> Bool {
  communicationPattern.matches(name)
}

private let communicationPattern = Pattern([
  "send", "send message", "send email", "reply", "reply all", "post", "publish",
  "tweet", "share", "call", "start call", "join call",
])

/// Case-insensitive whole-phrase matching over a closed list.
///
/// Substring matching would be wrong in both directions: "resend" contains
/// "send", and a button named "Send" is missed by anything anchored. Phrases are
/// compared against the name's own words.
private struct Pattern {
  private let phrases: [String]

  init(_ phrases: [String]) {
    self.phrases = phrases
  }

  func matches(_ name: String) -> Bool {
    let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    guard !words.isEmpty else { return false }
    return phrases.contains { phrase in
      let needle = phrase.split(separator: " ").map(String.init)
      guard !needle.isEmpty, needle.count <= words.count else { return false }
      for start in 0...(words.count - needle.count)
      where Array(words[start..<start + needle.count]) == needle {
        return true
      }
      return false
    }
  }
}
