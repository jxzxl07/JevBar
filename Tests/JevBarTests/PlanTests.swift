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

@Suite("Naming a place")
struct DestinationTests {
  @Test("a site is a site, not an application")
  func sitesBeatApps() {
    // "open LinkedIn" names a website, and there is also a LinkedIn app. A
    // table that preferred the app would open the wrong one for most people.
    let step = planSteps(from: "open linkedin")[0]
    #expect(step.site == "https://www.linkedin.com")
    #expect(step.app == nil)
  }

  @Test("an application is still an application")
  func appsStillWork() {
    let step = planSteps(from: "open Notes")[0]
    #expect(step.site == nil)
    #expect(step.app == "Notes")
  }

  @Test("Trackr goes to the board, not the front page")
  func trackrGoesToTheBoard() {
    // The front page is never what is wanted, and a run that lands there has
    // failed at the only thing asked of it. Both spellings, because the site
    // drops the 'e' and people do not.
    let board = "https://app.the-trackr.com/uk-tech/summer-internships"
    #expect(planSteps(from: "go to trackr")[0].site == board)
    #expect(planSteps(from: "can you go to Tracker for me")[0].site == board)
  }

  @Test("a spoken domain is a destination")
  func spokenDomains() {
    // A domain nothing in the table knows about. "bbc.co.uk" would match the
    // table's own `bbc` first, which is right but tests the wrong thing.
    #expect(planSteps(from: "go to monzo.com")[0].site == "https://monzo.com")
  }

  @Test("an ordinary sentence with a full stop is not a domain")
  func doesNotInventDomains() {
    // An open suffix list matches ordinary words: "first.article" looks like a
    // domain to a permissive pattern.
    #expect(planSteps(from: "open Notes. write something")[0].site == nil)
  }
}

@Suite("Opening and closing things")
struct OpenCloseTests {
  @Test("any installed application is found, not just a listed one")
  func findsInstalledApps() {
    // A hardcoded list is wrong the moment anything is installed. macOS knows
    // what is here; asking it is shorter and always right.
    #expect(Apps.resolve("notes")?.name == "Notes")
    #expect(Apps.resolve("safari")?.name == "Safari")
    #expect(Apps.resolve("definitely not installed xyzzy") == nil)
  }

  @Test("the shorter name wins when both merely match")
  func prefersExactNames() {
    // "notes" must find Notes rather than GoodNotes, on a Mac that has both.
    #expect(Apps.resolve("notes")?.name == "Notes")
  }

  @Test("closing is recognised and is not an opening")
  func recognisesClosing() {
    let step = planSteps(from: "close Notes")[0]
    #expect(step.closes)
    #expect(step.app == "Notes")
    #expect(step.site == nil)
  }

  @Test("a folder is a folder, not an app or a site")
  func recognisesFolders() {
    let step = planSteps(from: "open my downloads")[0]
    #expect(step.folder?.hasSuffix("Downloads") == true)
    #expect(step.app == nil)
    #expect(step.site == nil)
  }

  @Test("opening and closing in one sentence is two steps")
  func mixesVerbs() {
    let steps = planSteps(from: "open Notes and then close Safari")
    #expect(steps.count == 2)
    #expect(steps[0].closes == false)
    #expect(steps[1].closes)
    #expect(steps[1].app == "Safari")
  }
}
