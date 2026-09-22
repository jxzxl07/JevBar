import Foundation

/// One thing to do, in order.
struct Step: Equatable, Sendable {
  /// What the user asked for, in their own words, narrowed to this clause.
  let goal: String
  /// The application this clause is about, when the sentence named one.
  let app: String?
  /// The address this clause is about, when it named a site rather than an app.
  let site: String?
  /// A folder this clause asks to open.
  let folder: String?
  /// True when the clause asks to close or quit rather than to open.
  let closes: Bool
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
    // A site is checked first: "open LinkedIn" names a website, and there is
    // also a LinkedIn application, so a table lookup that preferred the app
    // would open the wrong one for most people most of the time.
    let closes = asksToClose(clause)
    // A folder is checked before a site, because "open my downloads" names
    // neither an application nor an address.
    let folder = Folders.resolve(clause).map(\.path)
    let site = folder == nil && !closes ? namedSite(in: clause) : nil
    if site == nil, folder == nil, let named = namedApp(in: clause) { currentApp = named }

    steps.append(
      Step(
        goal: clause,
        app: currentApp,
        site: site,
        folder: folder,
        closes: closes,
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

/// Whether the clause asks for a form to be filled in.
///
/// Separate from `looksLikeApplication`, which decides what is *refused*. This
/// one decides which path runs, and a plain "fill this in" on an ordinary web
/// form should take the fast path too.
func asksToFill(_ clause: String) -> Bool {
  let words = Set(clause.lowercased().split { !$0.isLetter }.map(String.init))
  let verbs: Set<String> = ["fill", "complete", "populate", "autofill"]
  return !words.isDisjoint(with: verbs)
}

/// Whether the clause asks for something to be closed rather than opened.
///
/// Quitting is not destructive — an application asked to quit runs its own
/// save-and-quit path, which is what Cmd-Q gives — so it is an ordinary verb
/// rather than one the policy has to weigh.
private func asksToClose(_ clause: String) -> Bool {
  let words = clause.lowercased().split { !$0.isLetter }.map(String.init)
  return words.contains { ["close", "quit", "exit"].contains($0) }
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

/// The application a clause names, out of everything installed.
///
/// The table is consulted first because it holds the names that are *said*
/// rather than the names on disk — "chrome" for `Google Chrome`, "settings" for
/// `System Settings`. Anything it does not know is looked up on the filesystem,
/// so "open GoodNotes" works on a Mac that has GoodNotes without anybody having
/// added it to a list.
private func namedApp(in clause: String) -> String? {
  let lower = clause.lowercased()
  for name in knownApps.keys.sorted(by: { $0.count > $1.count }) where lower.contains(name) {
    return knownApps[name]
  }

  // The words after the verb are the candidate name: "open goodnotes" asks
  // about "goodnotes", and passing the whole clause would match an application
  // whose name happens to contain a common word.
  let words = lower.split { !$0.isLetter && !$0.isNumber }.map(String.init)
  let skip: Set<String> = [
    "open", "close", "quit", "exit", "launch", "start", "please", "can", "you",
    "my", "the", "app", "application", "for", "me", "up",
  ]
  let remaining = words.filter { !skip.contains($0) }
  guard !remaining.isEmpty else { return nil }

  // Longest phrase first: "microsoft word" before "microsoft".
  for length in stride(from: remaining.count, through: 1, by: -1) {
    let phrase = remaining.prefix(length).joined(separator: " ")
    if let match = Apps.resolve(phrase) { return match.name }
  }
  return nil
}
