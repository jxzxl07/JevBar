import Foundation

/// The hands: `munim-computer-use`, launched as a child MCP server.
///
/// ## Why a child process rather than our own accessibility layer
///
/// JevDesk wrote its own, and the cost was not the tree-walking — it was
/// everything around it. A second signed binary whose permission grant rotted on
/// every rebuild, a JSON-RPC protocol we maintained, four readers that disagreed
/// about which window was in front, and guards that compared against values the
/// tree declines to report.
///
/// This engine is Apache 2.0, written in Swift against the same APIs, and gives
/// back stable element ids instead of coordinates — which is the safety rule
/// JevBar would otherwise have to enforce by parsing. It also refuses secure
/// text fields unless an environment variable is set, and JevBar never sets it.
///
/// ## The one thing to know about permissions
///
/// Accessibility is granted to the process that *hosts* this one. Run the binary
/// from a terminal and the grant belongs to the terminal; launch it from JevBar
/// and it belongs to JevBar. That is why `Accessibility permission is not
/// granted to the host app` is a statement about JevBar, not about the engine.
actor Engine {
  enum Failure: Error, CustomStringConvertible {
    case notBuilt
    case crashed(String)
    case protocolError(String)
    case tool(String)

    var description: String {
      switch self {
      case .notBuilt:
        return "The computer-use engine is missing from this build."
      case .crashed(let detail):
        return "The computer-use engine stopped: \(detail)"
      case .protocolError(let detail):
        return "The computer-use engine sent something unexpected: \(detail)"
      case .tool(let message):
        return message
      }
    }
  }

  private let executable: URL
  private var process: Process?
  private var input: FileHandle?
  private var output: FileHandle?
  private var nextId = 1
  private var buffer = Data()

  init(executable: URL) {
    self.executable = executable
  }

  /// Start the engine and complete the MCP handshake.
  ///
  /// Idempotent: a second call while it is already running is a no-op, because
  /// every lane asks for the engine and none of them should own its lifetime.
  func start() throws {
    if process?.isRunning == true { return }
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw Failure.notBuilt
    }

    let task = Process()
    task.executableURL = executable
    let toEngine = Pipe()
    let fromEngine = Pipe()
    task.standardInput = toEngine
    task.standardOutput = fromEngine
    // Discarded deliberately: the engine logs diagnostics here, and a pipe
    // nobody drains fills and blocks the process it belongs to.
    task.standardError = FileHandle.nullDevice

    var environment = ProcessInfo.processInfo.environment
    // §3: never. Named here rather than merely left unset, so that a future
    // reader sees the decision instead of an absence.
    environment["COMPUTER_USE_ALLOW_SECURE_FIELD_INPUT"] = "0"
    task.environment = environment

    try task.run()
    process = task
    input = toEngine.fileHandleForWriting
    output = fromEngine.fileHandleForReading

    _ = try request(
      "initialize",
      [
        "protocolVersion": "2024-11-05",
        "capabilities": [:],
        "clientInfo": ["name": "JevBar", "version": "0.1.0"],
      ])
  }

  func stop() {
    process?.terminate()
    process = nil
    input = nil
    output = nil
    buffer = Data()
  }

  /// Call one tool and return its text result.
  ///
  /// The engine reports a tool-level failure as a *successful* response whose
  /// `isError` is true, which is easy to read past — so it is turned into a
  /// thrown `Failure.tool` here, once, rather than at each call site.
  func call(_ tool: String, _ arguments: [String: Any] = [:]) throws -> String {
    try start()
    let result = try request("tools/call", ["name": tool, "arguments": arguments])
    guard let content = result["content"] as? [[String: Any]] else {
      throw Failure.protocolError("a tool result with no content")
    }
    let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    if result["isError"] as? Bool == true {
      throw Failure.tool(text.isEmpty ? "The engine refused, without saying why." : text)
    }
    return text
  }

  private func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
    guard let input, let output else { throw Failure.crashed("it was never started") }

    let id = nextId
    nextId += 1
    let envelope: [String: Any] = [
      "jsonrpc": "2.0", "id": id, "method": method, "params": params,
    ]
    var line = try JSONSerialization.data(withJSONObject: envelope)
    line.append(0x0A)
    try input.write(contentsOf: line)

    // Read until the reply with *this* id arrives. Notifications and replies to
    // other calls are skipped rather than mistaken for the answer.
    while true {
      guard let message = try readLine(from: output) else {
        throw Failure.crashed("it closed its output")
      }
      guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any] else {
        continue
      }
      guard object["id"] as? Int == id else { continue }
      if let error = object["error"] as? [String: Any] {
        throw Failure.tool(error["message"] as? String ?? "the engine reported an error")
      }
      return object["result"] as? [String: Any] ?? [:]
    }
  }

  private func readLine(from handle: FileHandle) throws -> Data? {
    while true {
      if let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer[buffer.startIndex..<newline]
        buffer.removeSubrange(buffer.startIndex...newline)
        if !line.isEmpty { return Data(line) }
        continue
      }
      let chunk = handle.availableData
      if chunk.isEmpty { return nil }
      buffer.append(chunk)
    }
  }
}
