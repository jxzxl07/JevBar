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
  func ask(system: String, user: String) async throws -> [String: Any] {
    var request = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 30

    let body: [String: Any] = [
      "model": config.model,
      "messages": [
        ["role": "system", "content": system],
        ["role": "user", "content": user],
      ],
      "response_format": ["type": "json_object"],
      "temperature": 0,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let detail = String(data: data, encoding: .utf8) ?? ""
      throw ThinkError.refused(String(detail.prefix(300)))
    }

    guard
      let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let choices = envelope["choices"] as? [[String: Any]],
      let message = choices.first?["message"] as? [String: Any],
      let content = message["content"] as? String,
      let parsed = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
    else {
      throw ThinkError.unreadable
    }
    return parsed
  }
}

enum ThinkError: Error, CustomStringConvertible {
  case notConfigured
  case refused(String)
  case unreadable

  var description: String {
    switch self {
    case .notConfigured:
      return
        "No model key is configured. Put GEMINI_API_KEY in "
        + "~/Library/Application Support/JevBar/.env"
    case .refused(let detail): return "The model refused the request: \(detail)"
    case .unreadable: return "The model replied with something that was not the shape asked for."
    }
  }
}
