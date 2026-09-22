# JevBar — plan

A native macOS menu-bar agent. Hold a key, speak, it acts, anywhere on the
desktop. Its first job is filling internship applications; its second is ordinary
desktop work; its third is doing several things from one sentence.

Swift. One app. One signature.

---

## 1. What we are copying, and what we are writing

### Copied: the hands

**[munim-computer-use](https://github.com/munimtechnologies/munim-computer-use)**,
Apache 2.0, Swift for macOS, already pinned and built by JevDesk's
`scripts/build-cua.mjs`. It is an MCP stdio server exposing 30 tools:

```
list_apps  get_app_state  screenshot  zoom  list_displays
click  right_click  hover  drag  scroll  type_text  set_value
press_key  select_text  activate_app  wait  clipboard_read/write
```

Why this and not our own accessibility layer:

- **Element ids, not coordinates.** `get_app_state` returns the accessibility
  tree with stable ids (`e12`), and every action takes one. That *is* JevBar's
  rule that a model never emits a coordinate — enforced by the engine, not by our
  parsing.
- **Background input.** Actions are delivered without stealing the pointer, so
  the user keeps working and there is no visible cursor crawling the screen.
- **Secure fields refused by default.** Password input requires an environment
  opt-in JevBar will never set.
- **Desktop-wide.** Chrome, Safari, Notes, Mail, System Settings, a PDF — all the
  same accessibility tree. No lane per surface.

**Not used: the `browser_*` tools.** They require the vendor's own Chrome
extension, which is the dependency this rewrite exists to remove. A web form is
reached the same way as anything else: through the accessibility tree of whatever
browser is in front.

### Borrowed as patterns, not code

**[Agent! (macOS26/Agent)](https://github.com/macOS26/Agent)** — pure Swift menu-bar
agent, voice trigger, multi-step with self-correction. Its licence is PolyForm
Noncommercial, so nothing is copied from it; what is worth taking is the shape of
its loop: act, observe, self-correct, stop.

### Written: the head

Everything that decides, authorizes, remembers and explains.

## 2. Architecture

```
JevBar.app                      one binary, one signature
├─ Bar            SwiftUI       menu-bar item + command window
├─ Voice          Speech        SFSpeechRecognizer, streaming partials
├─ Utterance                    stable-prefix commit → clause → admission gate
├─ Plan                         one sentence → an ordered list of steps
├─ Policy                       deterministic authorization, before every effect
├─ Think
│   ├─ Jev        TypeSafe      closed choices, ~180ms — the hot path
│   └─ Gemini     flash-lite    vision + prose, only when the tree is not enough
├─ Hands          MCP stdio     munim-computer-use, launched as a child
├─ Profile        Keychain      facts, encrypted, ask-once/remember-forever
└─ Log            SQLite        every run, every step, diagnosable afterwards
```

One process of ours, one child process we did not write. Nothing else.

## 3. Non-negotiable safety contract

- Job applications are **never submitted**. Terminal state is human review.
- Passwords, passkeys and one-time codes are **never entered or stored**.
- **A submit-shaped control is never pressed in an application task.** Matched on
  the accessible name JevBar read from the tree — never on anything a model said.
- A model proposal is not permission. A pure policy function authorizes every
  effect.
- The model chooses an element id from a list JevBar built. Never a coordinate,
  never a selector, never a name it invented.
- No hidden listening or screen capture.

## 4. Multi-step

One sentence becomes an ordered plan. "Open Notes and write a note saying call
the dentist, then check my email" is three steps, each separately authorized,
executed in order, stopping on failure and reporting what did and did not run.

A dropped clause is never silent. This is the thing JevDesk could not do: its
router matched exactly one intent per utterance and discarded the rest.

## 5. Build order

| # | Stage | Done when |
| --- | --- | --- |
| 1 | Bar, engine, log | ⌘⇧Space opens it; "open Safari" works; the log says what happened |
| 2 | Plan + policy | "open Notes and write X" runs both clauses; a submit control is refused |
| 3 | Form filling | a real Lever form fills in your own Chrome, ends at review |
| 4 | Ask-once profile | second run on the same form asks nothing |
| 5 | Voice | hold-to-talk, transcribe, run |
| 6 | Mid-utterance | "open YouTube and…" acts before the sentence ends |

Stage 3 is the demo. 1–4 are the product.

## 6. Rules

- No path resolved against the working directory — bundle resources only.
- Signed with a stable identity from the first build, so no permission grant is
  ever tied to a hash of the binary.
- Every run writes a step-level log, including runs that fail before they start.
- No guard that depends on an answer the platform may decline to give.
- Values never appear in logs. Labels and keys only.

These six are not style. Each one is a day JevDesk lost.
