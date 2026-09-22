import Foundation

/// One thing to do, in order.
struct Step: Equatable, Sendable {
  /// What the user asked for, in their own words, narrowed to this clause.
  let goal: String
  /// The application this clause is about, when the sentence named one.
  let app: String?
  /// Whether this clause is filling in an application, which changes what is
  /// refused.
  let kind: TaskKind
}

/// Split one sentence into an ordered plan.
///
/// ## Why this exists at all
///
/// JevDesk matched exactly one intent per utterance and discarded the rest.
/// "Open my desktop folder and delete the screenshots" opened the folder and
/// silently dropped the second half — safe by accident there, and the same
/// mechanism that loses the second half of anything legitimate. A dropped clause
/// must never be silent.
///
/// ## Why the split is deterministic
///
/// Conjunctions are punctuation, not judgement. Sending the sentence to a model
/// to be divided costs a round trip before anything can start, and the round
/// trip is the thing mid-utterance dispatch cannot afford. A model is asked what
/// to *do* with a clause, never where a clause ends.
func planSteps(from command: String) -> [Step] {
  let clauses = splitClauses(command)
  guard !clauses.isEmpty else { return [] }

  // The application a clause is about carries forward. "Open Notes and write a
  // note saying X" is two clauses, and the second one is still about Notes —
  // a reader who has just been told which app is in play does not expect to be
  // told again.
  var currentApp: String?
  var steps: [Step] = []

  for clause in clauses {
    if let named = namedApp(in: clause) { currentApp = named }
    steps.append(
      Step(
        goal: clause,
        app: currentApp,
        kind: looksLikeApplication(clause) ? .jobApplication : .general))
  }
  return steps
}

/// The words people use to mean "and then".
///
/// `and` alone is not enough and is not safe to use alone: "fill in my first and
/// last name" is one clause, not two. A conjunction only splits when what
/// follows starts like an instruction — an imperative verb this list knows.
private let sequencers = ["and then", "then", "after that", "and"]

private let imperatives = [
  "open", "close", "quit", "go", "search", "find", "fill", "complete", "type",
  "write", "play", "show", "check", "read", "click", "press", "select", "scroll",
  "mute", "unmute", "take", "make", "create", "start", "stop", "send", "reply",
  "navigate", "visit", "launch", "switch", "delete", "remove", "move", "copy",
  "paste", "attach", "upload", "answer", "add", "save", "download", "email",
  "message", "call", "watch", "listen", "pause", "resume",
]

private func startsAnInstruction(_ word: String) -> Bool {
  imperatives.contains(word.lowercased().trimmingCharacters(in: .punctuationCharacters))
}

func splitClauses(_ command: String) -> [String] {
  let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return [] }

  var clauses: [String] = []
  var current = ""
  let words = trimmed.split(separator: " ").map(String.init)
  var index = 0

  while index < words.count {
    let matched = sequencers.first { sequencer in
      let parts = sequencer.split(separator: " ").map(String.init)
      guard index + parts.count <= words.count else { return false }
      let ahead = words[index..<index + parts.count]
        .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
      guard Array(ahead) == parts else { return false }
      // Only a sequencer if an instruction follows it. "first and last name"
      // keeps its `and`; "open Notes and write a note" does not.
      let next = index + parts.count
      guard next < words.count else { return false }
      return startsAnInstruction(words[next])
    }

    if let matched, !current.isEmpty {
      clauses.append(current.trimmingCharacters(in: .whitespaces))
      current = ""
      index += matched.split(separator: " ").count
      continue
    }

    current += (current.isEmpty ? "" : " ") + words[index]

    /*
     A comma is a sequencer too, but it is never its own word.

     "open Safari, go to bbc.co.uk" tokenises as `Safari,` — so a comma checked
     alongside "and" and "then" above would never match anything. It is checked
     here instead, after the word it is attached to has been kept, and on the
     same condition as the others: only when an instruction follows it.
    */
    if words[index].hasSuffix(","), index + 1 < words.count,
      startsAnInstruction(words[index + 1])
    {
      clauses.append(
        current.trimmingCharacters(in: CharacterSet(charactersIn: " ,")))
      current = ""
    }

    index += 1
  }

  if !current.isEmpty { clauses.append(current.trimmingCharacters(in: .whitespaces)) }
  return clauses
}

/// Whether this clause is about filling in a job application.
///
/// It decides which refusals apply, so it is deliberately generous: a clause
/// wrongly treated as an application is merely more careful, while one wrongly
/// treated as general loses the submit refusal.
private func looksLikeApplication(_ clause: String) -> Bool {
  let lower = clause.lowercased()
  let subjects = ["application", "form", "internship", "job"]
  return subjects.contains { lower.contains($0) }
}

/// Applications people name out loud, and what they are actually called.
private let knownApps: [String: String] = [
  "notes": "Notes", "mail": "Mail", "safari": "Safari", "chrome": "Google Chrome",
  "google chrome": "Google Chrome", "finder": "Finder", "messages": "Messages",
  "whatsapp": "WhatsApp", "spotify": "Spotify", "music": "Music", "calendar": "Calendar",
  "terminal": "Terminal", "reminders": "Reminders", "preview": "Preview",
  "system settings": "System Settings", "settings": "System Settings",
]

private func namedApp(in clause: String) -> String? {
  let lower = clause.lowercased()
  // Longest first, so "google chrome" wins over "chrome".
  for name in knownApps.keys.sorted(by: { $0.count > $1.count }) where lower.contains(name) {
    return knownApps[name]
  }
  return nil
}
