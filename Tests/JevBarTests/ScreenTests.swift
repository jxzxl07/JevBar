import Testing

@testable import JevBar

@Suite("Reading the screen")
struct ScreenTests {
  let outline = """
    AXWindow "Forward Deployed Software Engineer"
      AXGroup
        [e3] AXTextField "First Name" value="Jazil"
        [e4] AXTextField "Email"
        [e5] AXButton "Submit application"
      AXStaticText "indicates a required field"
    """

  @Test("it keeps only what can be acted on")
  func keepsActionable() {
    // Lines without an id are structure. They cannot be targeted, so carrying
    // them would only make the list longer for the model to choose from.
    let screen = parseScreen(app: "Google Chrome", outline: outline)
    #expect(screen.controls.map(\.id) == ["e3", "e4", "e5"])
  }

  @Test("it reads the name the policy will judge")
  func readsNames() {
    let screen = parseScreen(app: "Google Chrome", outline: outline)
    #expect(screen.control(id: "e5")?.name == "Submit application")
    #expect(screen.control(id: "e3")?.role == "AXTextField")
  }

  @Test("it reads a field's current text, and tolerates its absence")
  func readsValues() {
    let screen = parseScreen(app: "Google Chrome", outline: outline)
    #expect(screen.control(id: "e3")?.value == "Jazil")
    #expect(screen.control(id: "e4")?.value == nil)
  }

  @Test("an outline it cannot make sense of yields nothing, not a crash")
  func toleratesNonsense() {
    #expect(parseScreen(app: "X", outline: "").controls.isEmpty)
    #expect(parseScreen(app: "X", outline: "no ids here at all").controls.isEmpty)
  }

  @Test("the name a model supplies is never what gets judged")
  func nameComesFromTheTree() {
    // The point of parsing: JevBar holds its own description of e5. A model
    // calling it "Continue" cannot make it anything other than a submit button.
    let screen = parseScreen(app: "Google Chrome", outline: outline)
    let named = screen.control(id: "e5")?.name ?? ""
    #expect(authorize(Action(verb: .click, controlName: named, value: nil), in: .jobApplication) != .allow)
  }
}
