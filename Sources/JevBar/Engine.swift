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

  /// How long any one tool call may take before it is abandoned.
  ///
  /// Reading a long page is the slowest thing the engine does and it takes a
  /// couple of seconds; thirty is not a budget to be spent, it is the point
  /// past which the answer is not coming.
  private static let callTimeout: Duration = .seconds(30)

  private let executable: URL
  private var process: Process?
  private var input: FileHandle?
  private var nextId = 1
  private var buffer = Data()
  private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]

  init(executable: URL) {
    self.executable = executable
  }

  /// Start the engine and complete the MCP handshake.
  ///
  /// Idempotent: a second call while it is already running is a no-op, because
  /// every lane asks for the engine and none of them should own its lifetime.
  func start(handshakeTimeout: Duration = Engine.callTimeout) async throws {
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

    /*
     Output is read by a handler, never by the actor.

     This used to be a `while` loop calling `availableData` from inside
     `request`, which is blocking I/O on an actor: one call that never returned
     held the actor forever, every later call queued behind it, and the app was
     wedged with nothing to do but quit it. A real run sat on "Working…"
     indefinitely, and the engine process had already died — so the read was
     waiting on a pipe whose writer was gone.

     A readability handler runs on its own queue and hands finished lines back
     in, so the actor only ever does bookkeeping.
    */
    fromEngine.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      guard let self else { return }
      Task { await self.receive(chunk) }
    }
    task.terminationHandler = { [weak self] _ in
      guard let self else { return }
      Task { await self.engineStopped() }
    }

    try task.run()
    process = task
    input = toEngine.fileHandleForWriting

    _ = try await request(
      "initialize",
      [
        "protocolVersion": "2024-11-05",
        "capabilities": [:],
        "clientInfo": ["name": "JevBar", "version": "0.1.0"],
      ],
      timeout: handshakeTimeout)
  }

  func stop() {
    (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    process?.terminate()
    process = nil
    input = nil
    buffer = Data()
    failAllPending(with: Failure.crashed("it was stopped"))
  }

  /// Call one tool and return its text result.
  ///
  /// The engine reports a tool-level failure as a *successful* response whose
  /// `isError` is true, which is easy to read past — so it is turned into a
  /// thrown `Failure.tool` here, once, rather than at each call site.
  func call(_ tool: String, _ arguments: [String: Any] = [:]) async throws -> String {
    try await start()
    let result = try await request("tools/call", ["name": tool, "arguments": arguments])
    guard let content = result["content"] as? [[String: Any]] else {
      throw Failure.protocolError("a tool result with no content")
    }
    let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    if result["isError"] as? Bool == true {
      throw Failure.tool(text.isEmpty ? "The engine refused, without saying why." : text)
    }
    return text
  }

  /// `call`, with the timeout overridden. For tests that must not take 30s.
  func callForTesting(_ tool: String, timeout: Duration) async throws -> String {
    try await start(handshakeTimeout: timeout)
    let result = try await request(
      "tools/call", ["name": tool, "arguments": [:]], timeout: timeout)
    return (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }
      .joined(separator: "\n") ?? ""
  }

  private func request(
    _ method: String,
    _ params: [String: Any],
    timeout: Duration = Engine.callTimeout,
  ) async throws -> [String: Any] {
    guard let input else { throw Failure.crashed("it was never started") }

    let id = nextId
    nextId += 1
    let envelope: [String: Any] = [
      "jsonrpc": "2.0", "id": id, "method": method, "params": params,
    ]
    var line = try JSONSerialization.data(withJSONObject: envelope)
    line.append(0x0A)
    try input.write(contentsOf: line)

    /*
     The reply, or a timeout — never neither.

     Racing the wait against a sleep is what makes a hung engine a failed run
     rather than a wedged application. The loser of the race is cancelled, and
     the pending entry is removed by whichever side finishes first, so a late
     reply cannot resume a continuation twice.
    */
    return try await withThrowingTaskGroup(of: [String: Any].self) { group in
      group.addTask { try await self.awaitReply(id: id) }
      group.addTask {
        try await Task.sleep(for: timeout)
        await self.abandon(id: id)
        throw Failure.crashed("it did not answer within \(Int(timeout.components.seconds))s")
      }
      defer { group.cancelAll() }
      guard let first = try await group.next() else {
        throw Failure.crashed("it produced no answer")
      }
      return first
    }
  }

  private func awaitReply(id: Int) async throws -> [String: Any] {
    try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
    }
  }

  /// Give up on one call, so its continuation is resumed exactly once.
  private func abandon(id: Int) {
    guard let continuation = pending.removeValue(forKey: id) else { return }
    continuation.resume(throwing: Failure.crashed("it did not answer in time"))
  }

  /// Bytes from the engine, split into whole lines and matched to their calls.
  private func receive(_ chunk: Data) {
    guard !chunk.isEmpty else { return }
    buffer.append(chunk)

    while let newline = buffer.firstIndex(of: 0x0A) {
      let line = Data(buffer[buffer.startIndex..<newline])
      buffer.removeSubrange(buffer.startIndex...newline)
      guard !line.isEmpty,
        let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        let id = object["id"] as? Int,
        let continuation = pending.removeValue(forKey: id)
      else { continue }

      if let error = object["error"] as? [String: Any] {
        continuation.resume(
          throwing: Failure.tool(error["message"] as? String ?? "the engine reported an error"))
      } else {
        continuation.resume(returning: object["result"] as? [String: Any] ?? [:])
      }
    }
  }

  /// The child died. Every call waiting on it fails now rather than never.
  private func engineStopped() {
    process = nil
    input = nil
    failAllPending(with: Failure.crashed("it exited"))
  }

  private func failAllPending(with error: Error) {
    let waiting = pending
    pending = [:]
    for continuation in waiting.values { continuation.resume(throwing: error) }
  }

}
