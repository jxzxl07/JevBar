import Foundation

/// What happened, written down while it happens.
///
/// ## Why this exists from the first commit
///
/// JevDesk recorded `{"stepCount": 12}` for a failed run — a count, with no
/// steps — and its agent wrote no receipts at all. A failure could not be
/// diagnosed afterwards, only reproduced and guessed at, and several days went
/// into guessing. A run that leaves no record is a bug in the logging, not an
/// unlucky one.
///
/// ## What is never written
///
/// Field values. Labels, ids and element names, yes; the text put into a box,
/// never. A log that carries what was typed into an application form carries
/// someone's address and phone number, in plain text, forever.
actor RunLog {
  private let file: URL
  private let formatter = ISO8601DateFormatter()

  init(file: URL = supportDirectory().appendingPathComponent("runs.log")) {
    self.file = file
  }

  func started(runId: String, command: String, stepCount: Int) {
    append(runId, "started", "\(stepCount) step(s): \(command)")
  }

  func step(runId: String, step: Int, detail: String) {
    append(runId, "step \(step)", detail)
  }

  /// What the page offered when a field could not be found.
  ///
  /// Labels only, never values: this is about which control is which, and a
  /// log carrying what was typed into an application carries someone's address.
  func lookupFailed(label: String, query: String, offered: [String]) {
    let names = offered.isEmpty ? "nothing" : offered.joined(separator: " | ")
    append("lookup", "miss", "\(label) — asked '\(query)', got: \(names)")
  }

  func finished(runId: String, outcome: String) {
    append(runId, "finished", outcome)
  }

  /// The whole log, newest last. Read by the bar to show what happened.
  func recent(lines: Int = 200) -> [String] {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").suffix(lines).map(String.init)
  }

  private func append(_ runId: String, _ kind: String, _ detail: String) {
    let line = "\(formatter.string(from: Date()))\t\(runId)\t\(kind)\t\(detail)\n"
    guard let data = line.data(using: .utf8) else { return }

    if let handle = try? FileHandle(forWritingTo: file) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: file)
    }
  }
}
