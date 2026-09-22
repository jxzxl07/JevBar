import Foundation
import Testing

@testable import JevBar

/// What the engine does when the engine goes wrong.
///
/// A real run sat on "Working…" indefinitely and never wrote another line. The
/// cause was blocking I/O inside an actor: one call that never returned held the
/// actor forever, every later call queued behind it, and the app was wedged with
/// nothing to do but quit it. These are the two ways that happens.
@Suite("When the engine misbehaves")
struct EngineTests {
  @Test("a missing engine fails rather than waiting for one")
  func missingEngine() async {
    let engine = Engine(executable: URL(fileURLWithPath: "/nowhere/munim-computer-use"))
    await #expect(throws: Engine.Failure.self) {
      _ = try await engine.callForTesting("list_apps", timeout: .seconds(2))
    }
  }

  @Test("a child that exits fails every call waiting on it")
  func childThatExits() async {
    // `true` starts, says nothing, and exits — which is what a crashed engine
    // looks like from here. The old reader waited on its pipe forever.
    let engine = Engine(executable: URL(fileURLWithPath: "/usr/bin/true"))
    await #expect(throws: Engine.Failure.self) {
      _ = try await engine.callForTesting("list_apps", timeout: .seconds(2))
    }
  }

  @Test("a silent child does not wedge the actor", .timeLimit(.minutes(1)))
  func silentChild() async {
    /*
     A process that holds its pipe open and answers nothing, which is the exact
     shape of the hang: a live child, an open pipe, and no reply.

     Not `cat` — it echoes the request straight back, and the echo parses as a
     reply with a matching id, so the call *succeeds*. A silent child has to be
     genuinely silent.

     The assertion that matters is not the error; it is that this test finishes
     at all, and that a *second* call still gets through afterwards. Under the
     old reader the first call held the actor and the second never started.
    */
    let sleeper = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("jevbar-silent-\(UUID().uuidString).sh")
    try? "#!/bin/sh\nsleep 30\n".write(to: sleeper, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sleeper.path)
    defer { try? FileManager.default.removeItem(at: sleeper) }

    let engine = Engine(executable: sleeper)
    await #expect(throws: Engine.Failure.self) {
      _ = try await engine.callForTesting("list_apps", timeout: .milliseconds(300))
    }
    await #expect(throws: Engine.Failure.self) {
      _ = try await engine.callForTesting("list_apps", timeout: .milliseconds(300))
    }
  }
}
