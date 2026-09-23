import AppKit
import Foundation

/// A local control channel, so a change can be tested without a person pressing keys.
///
/// ## Why it exists
///
/// Every form fix used to need the user to run it and report back, because the
/// only process holding the Accessibility grant is JevBar itself — a terminal
/// running the engine sees nothing. This lets a local tool ask JevBar to dump
/// what the engine sees, or to run a command, and read the result from a file.
///
/// ## Why it needs a token
///
/// A `jevbar://` URL can be opened by anything, including a web page. Without a
/// secret, a page could make JevBar fill a form or type into an app. The token
/// is random, created once, and kept in a file only this user can read; a URL
/// without it is ignored, and nothing is logged about it.
enum Debug {
  static var directory: URL {
    let url = supportDirectory().appendingPathComponent("debug", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static var token: String {
    let file = supportDirectory().appendingPathComponent("debug-token")
    if let existing = try? String(contentsOf: file, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines), existing.count >= 32
    {
      return existing
    }
    let fresh = (0..<4).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }
      .joined()
    try? fresh.write(to: file, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return fresh
  }

  static func write(_ name: String, _ text: String) {
    try? text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }
}

extension AppDelegate {
  func registerDebugChannel() {
    _ = Debug.token  // created at launch so a tool can read it
    NSAppleEventManager.shared().setEventHandler(
      self, andSelector: #selector(handleURL(_:withReplyEvent:)),
      forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
  }

  @objc func handleURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
    guard
      let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
      let url = URLComponents(string: text),
      url.scheme == "jevbar"
    else { return }

    let query = Dictionary(
      (url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    guard query["token"] == Debug.token else { return }

    switch url.host {
    case "dump":
      let app = query["app"] ?? "Safari"
      Task { await debugDump(app: app) }
    case "call":
      // One engine tool with JSON arguments, for driving a page during a test.
      guard let tool = query["tool"], !tool.isEmpty else { return }
      let args =
        (try? JSONSerialization.jsonObject(with: Data((query["args"] ?? "{}").utf8)))
        as? [String: Any] ?? [:]
      Task {
        do {
          let out = try await model.engine.call(tool, args)
          Debug.write("call.txt", out)
        } catch {
          Debug.write("call.txt", "ERROR: \(error)")
        }
      }
    case "run":
      guard let command = query["cmd"], !command.isEmpty else { return }
      debugRun(command)
    default:
      return
    }
  }
}

extension AppDelegate {
  /// The raw outline the engine returns for an app, exactly as received.
  func debugDump(app: String) async {
    do {
      let outline = try await model.engine.call(
        "get_app_state", ["app": app, "max_elements": 2_000])
      Debug.write("outline.txt", outline)
    } catch {
      Debug.write("outline.txt", "ERROR: \(error)")
    }
  }

  /// Run a command as if it had been typed into the bar, and record the result.
  @MainActor
  func debugRun(_ command: String) {
    Debug.write("result.txt", "RUNNING: \(command)")
    model.command = command
    model.onFinish = { status, steps in
      Debug.write("result.txt", "DONE: \(status)\n" + steps.joined(separator: "\n"))
    }
    model.run()
  }
}
