import Testing

@testable import JevBar

/// The safety contract, tested without a screen.
///
/// Every case here is a product commitment rather than a behaviour, which is why
/// they are written as sentences about what JevBar will and will not do.
@Suite("What JevBar refuses")
struct PolicyTests {
  @Test("it never presses the control that submits an application")
  func refusesFinalSubmit() {
    for name in [
      "Submit application", "Submit my application", "Apply now",
      "Send application", "Finish and submit", "Submit",
    ] {
      let decision = authorize(
        Action(verb: .click, controlName: name, value: nil), in: .jobApplication)
      #expect(decision != .allow, "expected '\(name)' to be refused")
    }
  }

  @Test("it still moves between the pages of an application")
  func allowsNavigation() {
    // A multi-page application cannot be filled at all if moving through it is
    // refused. Refusing these would make the agent useless rather than safe.
    for name in ["Continue", "Next", "Save draft", "Back", "Review application"] {
      let decision = authorize(
        Action(verb: .click, controlName: name, value: nil), in: .jobApplication)
      #expect(decision == .allow, "expected '\(name)' to be allowed")
    }
  }

  @Test("it never types into a credential field, in any task")
  func refusesCredentials() {
    for task in [TaskKind.general, .jobApplication] {
      for name in ["Password", "One-time code", "Verification code", "Passkey"] {
        let decision = authorize(
          Action(verb: .typeText, controlName: name, value: "hunter2"), in: task)
        #expect(decision != .allow, "expected '\(name)' refused in \(task.rawValue)")
      }
    }
  }

  @Test("it never presses a control that transmits to another person")
  func refusesSending() {
    for name in ["Send", "Send message", "Reply all", "Post", "Publish", "Start call"] {
      let decision = authorize(Action(verb: .click, controlName: name, value: nil), in: .general)
      #expect(decision != .allow, "expected '\(name)' to be refused")
    }
  }

  @Test("a name that merely contains a refused word is not refused")
  func doesNotMatchSubstrings() {
    // "Resend" contains "send" and "Sender name" contains "send". Substring
    // matching would refuse a text field for the sake of a button.
    for name in ["Sender name", "Recipient", "Password hint label"] {
      let decision = authorize(Action(verb: .click, controlName: name, value: nil), in: .general)
      #expect(decision == .allow, "expected '\(name)' to be allowed")
    }
  }

  @Test("filling an ordinary field is allowed")
  func allowsOrdinaryWrites() {
    let decision = authorize(
      Action(verb: .setValue, controlName: "First Name", value: "Jazil"), in: .jobApplication)
    #expect(decision == .allow)
  }
}
