import Foundation

/// One thing on screen that JevBar can act on.
struct Control: Equatable, Sendable {
  /// The engine's id for this snapshot, such as `e12`. Stale after the UI moves.
  let id: String
  /// The element's kind, as the accessibility tree reports it.
  let role: String
  /// The accessible name. This is the evidence the policy reads.
  let name: String
  /// The text the field currently holds, when the outline reports one.
  let value: String?
  /// How deep in the outline it sat, which is the only structure worth keeping.
  let depth: Int
  /// Whether the outline marked it `(disabled)`.
  var disabled: Bool = false
}

/// The frontmost window, as a list of things that can be acted on.
struct Screen: Sendable {
  let app: String
  let controls: [Control]

  func control(id: String) -> Control? {
    controls.first { $0.id == id }
  }
}

/// Parse the engine's indented outline into controls.
///
/// ## Why parse it at all, rather than hand the text to a model
///
/// Because the policy has to read the control's *name* from somewhere, and that
/// somewhere must not be the model. Handing over the outline and accepting back
/// "press the Continue button" would mean the only description of what is about
/// to be pressed came from the thing asking to press it. Parsing gives JevBar
/// its own copy: the model picks an id, and JevBar looks up what that id is
/// called before deciding whether it may be touched.
///
/// ## Shape
///
/// The engine emits an indented outline in which actionable elements carry an
/// id, for example:
///
/// ```
///   AXWindow "Application"
///     [e3] AXTextField "First Name" value="Jazil"
///     [e4] AXButton "Submit application"
/// ```
///
/// Lines without an id are structure, not targets, and are skipped — they cannot
/// be acted on, so carrying them would only make the list longer for the model.
func parseScreen(app: String, outline: String) -> Screen {
  var controls: [Control] = []

  for line in outline.split(separator: "\n", omittingEmptySubsequences: false) {
    let text = String(line)
    guard let idRange = text.range(of: #"\[e\d+\]"#, options: .regularExpression) else { continue }

    let id = String(text[idRange]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let depth = text.prefix { $0 == " " }.count
    let rest = String(text[idRange.upperBound...]).trimmingCharacters(in: .whitespaces)

    controls.append(
      Control(
        id: id,
        role: normaliseRole(firstWord(of: rest)),
        name: quoted(in: rest) ?? "",
        value: value(in: rest),
        depth: depth,
        disabled: rest.contains("(disabled)")))
  }

  return Screen(app: app, controls: controls)
}

private func firstWord(of text: String) -> String {
  String(text.split(separator: " ").first ?? "")
}

/// A role, with or without the `AX` the platform sometimes puts in front.
///
/// The engine emits `TextField`; the accessibility API calls the same thing
/// `AXTextField`. A set written in one spelling matches nothing written in the
/// other, and the failure is silent in the worst way: a form of sixty boxes
/// reports "none is a text field I can fill", which reads as the page being
/// strange rather than as two names for one role.
func normaliseRole(_ role: String) -> String {
  role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
}

/// The first double-quoted run, which is where the outline puts the name.
private func quoted(in text: String) -> String? {
  guard let open = text.firstIndex(of: "\""),
    let close = text[text.index(after: open)...].firstIndex(of: "\"")
  else { return nil }
  return String(text[text.index(after: open)..<close])
}

/// `value="..."`, when the outline reports one.
///
/// Taken from the outline rather than by asking the tree again, because a second
/// round trip can answer about a screen that has since moved — and because the
/// accessibility API declines to report a value often enough that a guard
/// depending on it is a guard that does not run.
private func value(in text: String) -> String? {
  guard let marker = text.range(of: "value=\"") else { return nil }
  let after = text[marker.upperBound...]
  guard let close = after.firstIndex(of: "\"") else { return nil }
  return String(after[after.startIndex..<close])
}
