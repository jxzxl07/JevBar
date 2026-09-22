import Testing

@testable import JevBar

@Suite("Matching a form field to what JevBar knows")
struct FactKeyTests {
  @Test("the same question asked differently reaches the same fact")
  func synonymsConverge() {
    // A key derived from the page would make the same question new on every
    // site, which is the difference between a profile and a cache.
    #expect(factKey(forLabel: "Current location") == "location")
    #expect(factKey(forLabel: "Where are you based?") == "location")
    #expect(factKey(forLabel: "City") == "location")
  }

  @Test("first, last and full name stay apart")
  func nameFieldsAreDistinct() {
    // All three contain "name". Collapsing them would put a surname in the
    // box asking for a full one.
    #expect(factKey(forLabel: "First Name") == "firstName")
    #expect(factKey(forLabel: "Last Name") == "lastName")
    #expect(factKey(forLabel: "Full name") == "fullName")
  }

  @Test("a label nothing knows matches nothing, rather than guessing")
  func unknownLabels() {
    #expect(factKey(forLabel: "Favourite biscuit") == nil)
    #expect(factKey(forLabel: "") == nil)
  }

  @Test("a credential is never a key JevBar will keep")
  func credentialsRefused() {
    for label in ["Password", "Passcode", "One-time PIN", "Passkey"] {
      #expect(credentialLabel(label), "expected '\(label)' recognised as a credential")
    }
    #expect(isCredentialKey("password"))
    #expect(isCredentialKey("otpSecret"))
    #expect(!isCredentialKey("firstName"))
  }

  @Test("the model can only choose from keys this code owns")
  func catalogueIsClosed() {
    // A key it invented would be a new place to keep someone's personal data,
    // named by something that is not the person whose data it is.
    #expect(knownFactKeys.contains("location"))
    #expect(!knownFactKeys.contains(where: isCredentialKey))
  }
}

@Suite("The profile remembers, and refuses")
struct ProfileTests {
  @Test("it will not store a credential even when told to")
  func refusesToStoreCredentials() async {
    let profile = Profile()
    #expect(await profile.learn(key: "password", value: "hunter2") == false)
    #expect(await profile.value(for: "password") == nil)
  }

  @Test("what it learns once it knows afterwards")
  func remembers() async {
    let profile = Profile()
    let key = "testOnly_\(Int.random(in: 0..<1_000_000))"
    #expect(await profile.learn(key: key, value: "Cambridge"))
    #expect(await profile.value(for: key) == "Cambridge")
    await profile.forget(key: key)
    #expect(await profile.value(for: key) == nil)
  }
}
