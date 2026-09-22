# JevBar — handover

**Date:** 2026-09-22 · **Repo:** https://github.com/jxzxl07/JevBar · `main`, clean.
**Written from the app's own run log**, not from memory. Every claim below has a
line in `~/Library/Application Support/JevBar/runs.log` behind it.

Read `PLAN.md` for the architecture and why each piece is the way it is. This
file is what someone picking it up needs in order not to repeat a day of work.

---

## 1. What this is

A native macOS menu-bar agent. Hold ⌘⇧Space anywhere, speak, and it acts in
whatever application is in front of you. Its first job is filling internship
applications; its second is ordinary desktop work; its third is doing several
things from one sentence.

It replaced JevDesk (an Electron app) after a day in which every failure turned
out to be an integration seam rather than a logic bug: Electron talking JSON-RPC
to a Swift helper, Electron talking CDP to Chrome, a packaging script, an ad-hoc
signature, a Keychain ACL, a bundled `ws` stub.

```bash
./signing-identity.sh   # once per machine
./package.sh            # builds dist/JevBar.app
open dist/JevBar.app
swift test              # 47 tests
```

### Non-negotiable safety contract

Product commitments, not settings. Each has a test in `PolicyTests.swift`.

- Job applications are **never submitted**; the terminal state is human review.
- Passwords, passkeys and one-time codes are **never entered or stored**.
- **A submit-shaped control is never pressed in an application task**, matched
  on the accessible name JevBar read from the tree — never on what a model said.
- **Nothing is ever committed with Return.** In a text input Return submits the
  form on a large fraction of sites; an autocomplete is committed by clicking
  the suggestion instead. See `FormFill.commitSuggestions`.
- A model chooses an element id from a list JevBar built. Never a coordinate.

---

## 2. Architecture in one screen

```
JevBar.app                      one binary, one signature
├─ App.swift        NSStatusItem + popover, hold-to-talk wiring
├─ Voice.swift      SFSpeechRecognizer (streaming, on-device) + global hotkey
├─ Plan.swift       one sentence → ordered steps (deterministic)
├─ Policy.swift     pure function: may this action happen?
├─ Screen.swift     the engine's outline → typed controls
├─ FormFill.swift   the fast path: lookup, write, verify, ask
├─ Agent.swift      the loop: observe → decide → authorize → act
├─ Think.swift      Gemini over the OpenAI-compatible endpoint
├─ Profile.swift    facts, in a 0600 file
├─ Documents.swift  CV + cover letters, for open questions
└─ RunLog.swift     every run, every step
```

**The hands are not ours.**
[munim-computer-use](https://github.com/munimtechnologies/munim-computer-use)
(Apache 2.0, Swift) runs as a child MCP process and exposes 30 tools over the
accessibility tree with stable element ids. Its `browser_*` tools are
deliberately unused — they need a Chrome extension, and doing without one is the
point.

**Config:** `~/Library/Application Support/JevBar/.env` — `REASONING_API_KEY`
(Gemini), `REASONING_BASE_URL`, `REASONING_MODEL`. Never read from the working
directory; that is the filesystem root inside a `.app`.

---

## 3. What is proven to work

From the run log, on real pages:

- **Opening** apps (launching, not just foregrounding), websites, and folders.
- **Closing** apps, by asking them to quit rather than forcing.
- **Multi-step.** `run_2174838364`: "Close YouTube and then close Notes and then
  open YouTube" — three clauses parsed and executed in order.
- **The agent loop.** `run_87177338`: asked "what's my name", it opened WhatsApp,
  clicked through to settings over four turns and answered correctly.
- **Form filling on a real Stripe/Greenhouse application.** Email, Phone,
  Location, LinkedIn, GitHub written and **read back off the page**.
- **Gemini inference.** Graduation year derived from a graduation date; "Yes"
  for right-to-work; a full name composed from first and last.

**Never run:** voice against real speech. The recogniser, the hotkey and the
wiring are all built and the permissions are declared, but no command has been
produced by speaking. This is the headline feature and it is unverified.

---

## 4. Open problems, in the order they hurt

### 4.1 The run can hang forever — fix this first

`run_1595886436` sat on "Working…" indefinitely and never wrote another line.

**Cause, and it is a design flaw not a slip:** `Engine` is an actor, and
`Engine.readLine` does *blocking* I/O (`FileHandle.availableData`) inside it.
One call that never returns holds the actor forever, so every later call queues
behind it and the app is wedged with no way out but quitting. The engine process
was also **already dead** by the time this was inspected, which is the most
likely way the read blocked.

The fix is all three of:

1. A timeout on every `Engine.call`, so nothing waits forever.
2. Non-blocking reads (`readabilityHandler` or `DispatchIO`), so a slow engine
   never holds the actor.
3. Noticing the child died and reporting it, rather than reading a dead pipe.

JevDesk had exactly this bug in a different shape — a model call with no timeout
left runs in `RUNNING` forever — and the lesson written in its handover was
"nothing that can hang is allowed to hang unbounded". It was not applied here.

### 4.2 Off-screen fields are refused

```
skipped Email: error: e71 is not visible in its window —
  scroll it into view and call get_app_state again
```

Five fields on the Stripe form were refused for this. The engine will not act on
an element that is not visible, which is reasonable for a click and unhelpful
for a value write.

The fix is to `scroll` the element into view and re-read before writing, in
batches — not per field, or it costs a round trip each. **Do not** work around it
by clicking blindly at coordinates; element ids are the safety property.

### 4.3 Dropdowns are seen but never set

`School`, `Degree`, `Pronouns` come back as *"the page would not keep this
value"*. They are `PopUpButton`s: a text write cannot set them. They need
`click` to open, then the matching option chosen by name — the same shape as
`commitSuggestions`, which already works for autocompletes.

21 fields were skipped on the last full run; these two causes are most of them.

### 4.4 CV upload is not implemented

`Resume/CV` is a file picker. The path is in the profile (`cvPath`) and
`Documents` already reads the PDF, but nothing attaches it. The engine has no
file-picker tool, so this means driving the open panel through the accessibility
tree.

### 4.5 Voice is unverified

Hold ⌘⇧Space, speak, release. Built, permissions declared in `Info.plist`,
never run. Watch for: whether the global monitor receives events without
Input Monitoring as well as Accessibility, and whether the modifier-release path
(`Hotkey.handle`) fires when ⌘ is released before Space.

### 4.6 Mid-utterance dispatch is not built

The whole point of streaming partials, and the reason for choosing
`SFSpeechRecognizer` over whisper.cpp, which re-transcribes a growing buffer and
gets *slower* the longer you talk. `Voice.onPartial` already fires; nothing acts
on it yet. It needs stable-prefix commitment, a clause boundary, and a closed
allowlist of openers that may act early. **Only Jev can gate this** — a Gemini
round trip is 1–3s and the sentence is over.

---

## 5. Things that will waste a day if nobody says them

- **The engine spells roles without `AX`.** It emits `TextField`; the platform
  calls the same thing `AXTextField`. A set written the second way matched none
  of 300 controls and reported "no fields I can fill" on a full form. Roles are
  normalised in `Screen.normaliseRole`.
- **`set_value` succeeds and the page keeps nothing.** React-controlled inputs
  discard a value that arrives without the events a keystroke produces. Six
  fields were reported filled on a blank form. **Nothing counts as filled until
  it is read back**; the fallback is click + `type_text`, and that is verified
  too.
- **`activate_app` does not launch.** It foregrounds an app that is already
  running. Launching is `NSWorkspace`.
- **SwiftUI's `MenuBarExtra` silently fails** in a SwiftPM executable: a running
  process, no status item, nothing to click and no way to quit. `NSStatusItem`
  by hand works. `launch.log` records whether the button exists, because an
  accessory app is invisible when it works and invisible when it does not.
- **`codesign --deep` does not reach `Resources/`.** The engine is signed
  separately, and it is the process that asks for Accessibility.
- **Signing loses to a synced folder.** This checkout is FileProvider-synced, so
  macOS re-attaches extended attributes between `xattr -cr` and `codesign`.
  `package.sh` retries on exactly that error.
- **The Keychain was the wrong home for the profile.** macOS prompts for the
  login password whenever an app not on an item's access list reads it, and
  getting on that list needs the password too. Every form produced a prompt,
  which trains the habit of typing a login password at whatever asks. The
  profile is a `0600` file; credentials are refused before storage, so the store
  never holds anything that needed the Keychain.
- **`main.swift` is a reserved filename** — `@main` cannot live in it.

---

## 6. Suggested order

1. **§4.1, the hang.** Nothing else can be trusted while a run can wedge.
2. **§4.2, scrolling into view.** Most of the 21 skipped fields.
3. **§4.3, dropdowns.** The rest of them.
4. **§4.5, run voice.** Five minutes, and it is the headline.
5. §4.6 mid-utterance, §4.4 CV upload.

## 7. How to work on this

Verify against the running app and `runs.log`, not against expectations. Three
bugs here were "fixed" twice on reasoning that turned out to be wrong, and the
log is what settled each one — including the missing `AX` prefix, which took one
run to find because the failure reported how many controls it had read and what
they were.

Report honestly. A partial result stated plainly is worth more than a confident
claim that does not survive the user trying it.
