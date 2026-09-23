import Foundation

/// Where the models live, and the key for them.
struct ThinkConfig: Sendable {
  let baseURL: URL
  let model: String
  let apiKey: String

  /// Read from `~/Library/Application Support/JevBar/.env`, never from the
  /// working directory.
  ///
  /// Anything resolved against the working directory works in a checkout and
  /// fails inside a `.app`, where the working directory is the filesystem root.
  /// JevDesk hit that four separate times in four different subsystems, so
  /// JevBar has exactly one place a configuration file can be.
  static func load() -> ThinkConfig? {
    let path = supportDirectory().appendingPathComponent(".env")
    guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }

    var values: [String: String] = [:]
    for line in text.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.hasPrefix("#"), let split = trimmed.firstIndex(of: "=") else { continue }
      let key = String(trimmed[trimmed.startIndex..<split])
      let value = String(trimmed[trimmed.index(after: split)...])
      // Blank means absent, not empty string: a key left in the file with no
      // value is "not configured", and treating it as "" produces a confident
      // request that fails with a bad-credentials error instead.
      if !value.isEmpty { values[key] = value }
    }

    guard let key = values["GEMINI_API_KEY"] ?? values["REASONING_API_KEY"],
      let base = URL(
        string: values["REASONING_BASE_URL"]
          ?? "https://generativelanguage.googleapis.com/v1beta/openai/")
    else { return nil }

    return ThinkConfig(
      baseURL: base,
      model: values["REASONING_MODEL"] ?? "gemini-3.5-flash-lite",
      apiKey: key)
  }
}

func supportDirectory() -> URL {
  let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  let directory = base.appendingPathComponent("JevBar", isDirectory: true)
  try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

/// The model, asked only questions whose answers land in a code-owned slot.
///
/// ## What it is never asked
///
/// Where something is, what URL to open, or whether an action is permitted. It
/// chooses an id from a list JevBar built by reading the screen, or supplies a
/// string for a field JevBar has already decided to fill. A hallucinated id is
/// not in the list and is refused, so the worst case is a wasted turn rather
/// than an action nobody authorized.
struct Think: Sendable {
  let config: ThinkConfig
  var session: URLSession = .shared

  /// Ask for JSON matching a shape, and hand back the parsed object.
  /// Ask for JSON matching a shape, hedged against the API's slow tail.
  ///
  /// ## Why the same question is asked more than once
  ///
  /// Measured against this key: an identical two-label request took 0.8s, then
  /// 20s, then 0.6s, 0.9s, 0.9s, 20.8s. Roughly one request in four sits for
  /// twenty seconds, independent of the prompt and of reasoning effort. A form
  /// fill makes several of these, and waiting out the tail on each is what left
  /// the bar on "Working…" with an untouched page for minutes.
  ///
  /// So a second copy is sent if the first has not answered in three seconds,
  /// and a third at eight, and the first answer wins; the others are cancelled.
  /// A slow request rarely repeats, so the typical wait stays under a second
  /// and the worst case falls from twenty seconds to a few. The cost is an
  /// extra request only in the cases that were already slow.
  func ask(system: String, user: String) async throws -> [String: Any] {
    try await withThrowingTaskGroup(of: [String: Any].self) { group in
      for delay in [0, 3, 8] {
        group.addTask {
          if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
          return try await askOnce(system: system, user: user)
        }
      }
      defer { group.cancelAll() }

      var lastError: Error = ThinkError.unreadable
      while true {
        do {
          guard let answer = try await group.next() else { break }
          return answer
        } catch {
          // One copy failing — a 429, a dropped connection — is not the
          // question failing while another copy is still in flight.
          lastError = error
        }
      }
      throw lastError
    }
  }

  private func askOnce(system: String, user: String) async throws -> [String: Any] {
    var request = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
    // Short, because a slower copy is already on its way: this bounds one
    // attempt, not the question.
    request.timeoutInterval = 15

    let body: [String: Any] = [
      "model": config.model,
      "messages": [
        ["role": "system", "content": system],
        ["role": "user", "content": user],
      ],
      "response_format": ["type": "json_object"],
      "temperature": 0,
      // Lower thinking effort. It does not remove the slow tail — that is the
      // API — but these are lookups and short drafts, not problems to reason
      // through, and less thinking is less time on every request.
      "reasoning_effort": "low",
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw ThinkError.unreadable
    }

    /*
     A quota refusal said as one sentence, not as three hundred characters of JSON.

     "Search sidemen on YouTube" failed with `The model refused the request: [{
     "error": { "code": 429,…` — which is true, unreadable, and gives no idea
     that the fix is to wait. The loop asks the model once per turn, so a run of
     any length is several requests and a free tier is reached quickly.
    */
    if http.statusCode == 429 {
      throw ThinkError.rateLimited
    }
    guard (200..<300).contains(http.statusCode) else {
      let detail = String(data: data, encoding: .utf8) ?? ""
      throw ThinkError.refused(String(detail.prefix(300)))
    }

    guard
      let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let choices = envelope["choices"] as? [[String: Any]],
      let message = choices.first?["message"] as? [String: Any],
      let content = message["content"] as? String,
      let parsed = parseLenientJSON(content)
    else {
      throw ThinkError.unreadable
    }
    return parsed
  }
}

enum ThinkError: Error, CustomStringConvertible {
  case notConfigured
  case rateLimited
  case refused(String)
  case unreadable

  var description: String {
    switch self {
    case .notConfigured:
      return
        "No model key is configured. Put GEMINI_API_KEY in "
        + "~/Library/Application Support/JevBar/.env"
    case .rateLimited:
      return
        "The model is rate limited — too many requests for now. Wait a minute and try again, "
        + "or add billing to the API key."
    case .refused(let detail): return "The model refused the request: \(detail)"
    case .unreadable: return "The model replied with something that was not the shape asked for."
    }
  }
}

/// A model's JSON, forgiven the ways it gets JSON wrong.
///
/// The lite model asked for `{"answers": {"q0": ...}}` wrote `q0: "..."` —
/// unquoted keys — and the strict parser threw away every answer in the batch,
/// essay included. Code fences and trailing commas turn up too.
func parseLenientJSON(_ text: String) -> [String: Any]? {
  func parse(_ s: String) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
  }
  if let strict = parse(text) { return strict }
  var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
  if let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}"), open < close {
    s = String(s[open...close])
  }
  if let trimmed = parse(s) { return trimmed }
  // Bare keys after `{` or `,` at the start of a line or after whitespace.
  s = s.replacingOccurrences(
    of: #"([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:"#, with: "$1\"$2\":",
    options: .regularExpression)
  s = s.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
  return parse(s)
}
