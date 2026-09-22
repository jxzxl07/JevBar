import Testing

@testable import JevBar

@Suite("Turning one sentence into a plan")
struct PlanTests {
  @Test("two instructions become two steps")
  func splitsInstructions() {
    let steps = planSteps(from: "open Notes and write a note saying call the dentist")
    #expect(steps.count == 2)
    #expect(steps[0].goal == "open Notes")
    #expect(steps[1].goal == "write a note saying call the dentist")
  }

  @Test("the app carries into later clauses")
  func carriesApp() {
    // A reader just told which app is in play does not expect to be told again.
    let steps = planSteps(from: "open Notes and write a note saying hello")
    #expect(steps[0].app == "Notes")
    #expect(steps[1].app == "Notes")
  }

  @Test("an 'and' joining two nouns is not a second instruction")
  func doesNotSplitNouns() {
    // "fill in my first and last name" is one thing to do. Splitting on every
    // `and` would make this two steps, the second of which is "last name".
    let steps = planSteps(from: "fill in my first and last name")
    #expect(steps.count == 1)
  }

  @Test("three instructions become three steps, in order")
  func keepsOrder() {
    let steps = planSteps(
      from: "open Safari, go to bbc.co.uk and then take a screenshot")
    #expect(steps.count == 3)
    #expect(steps[0].goal.contains("Safari"))
    #expect(steps[2].goal.contains("screenshot"))
  }

  @Test("a clause about an application is marked as one")
  func marksApplications() {
    let steps = planSteps(from: "fill in this internship application")
    #expect(steps[0].kind == .jobApplication)
    // Which is what makes the submit refusal apply to it.
    #expect(
      authorize(Action(verb: .click, controlName: "Submit application", value: nil), in: steps[0].kind)
        != .allow)
  }

  @Test("an ordinary command is not treated as an application")
  func marksGeneral() {
    #expect(planSteps(from: "open youtube")[0].kind == .general)
  }

  @Test("one instruction is one step, and nothing is one nothing")
  func degenerateCases() {
    #expect(planSteps(from: "open Safari").count == 1)
    #expect(planSteps(from: "   ").isEmpty)
  }

  @Test("the clause that killed JevDesk's router is two steps here")
  func theRegression() {
    // "Open my desktop folder and delete the screenshots" ran the folder open
    // and silently dropped the rest. It was safe by accident; the same
    // mechanism loses the second half of anything legitimate.
    let steps = planSteps(from: "open my desktop folder and delete the screenshots")
    #expect(steps.count == 2)
    #expect(steps[1].goal.contains("delete"))
  }
}
