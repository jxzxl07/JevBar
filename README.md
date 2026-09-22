# JevBar

A native macOS menu-bar agent. Hold a key, say what you want, and it acts —
in whatever application is in front of you.

Its first job is filling internship applications. Its second is ordinary desktop
work. Its third is doing several things from one sentence.

> **Status:** early. The safety contract and the engine bridge are in place and
> tested; the bar, the planner and voice are being built. `PLAN.md` is the
> current shape and the build order.

## What it will not do

These are product commitments, not settings. They have tests.

- **Job applications are never submitted.** JevBar fills a form in and stops at
  human review. A control whose accessible name looks like final submission is
  refused outright.
- **Passwords, passkeys and one-time codes are never entered or stored.**
- **Nothing is sent to another person.** Send, reply, post, publish and call are
  refused; JevBar prepares and you send.
- **A model proposal is not permission.** A pure function authorizes every
  effect, and it reads the control's name from the accessibility tree — never
  the model's description of it.
- **No model ever emits a coordinate**, a selector, or a name it invented. It
  chooses an element id from a list JevBar built by looking at the screen.

## How it works

JevBar is the head. The hands are
[munim-computer-use](https://github.com/munimtechnologies/munim-computer-use)
(Apache 2.0), a Swift MCP server that exposes the macOS accessibility tree with
stable element ids and delivers input in the background, so the pointer stays
yours.

That choice is why JevBar works everywhere rather than in one browser: Chrome,
Safari, Notes, Mail, System Settings and a PDF are all the same accessibility
tree. There is no browser extension, no pairing, and no debugging port.

Deciding is split between two models, cheapest first: a typed, closed-choice
model answers the common turn in about 180ms, and a multimodal model looks at a
screenshot only when the tree is not descriptive enough.

## Building

```bash
./signing-identity.sh   # once per machine
make                    # build, sign, install to ~/Applications, restart
make test
```

`make` is the whole development loop. A native app has no hot reload, so a code
change means a new binary — but nothing about permissions has to be repeated.
The signing identity and the install path are both stable, and that is what lets
an Accessibility grant survive a rebuild rather than being asked for again every
time.

The bundle is assembled and signed in a temporary directory, not in the
checkout. This repository lives on a synced folder, and the sync daemon attaches
extended attributes to anything that appears there — asynchronously, so clearing
them and then signing is a race. A signature made where nothing is watching
survives the move; one made afterwards is a coin toss.

Requires macOS 14+, Swift 6.1, and Accessibility permission granted to JevBar
(System Settings → Privacy & Security → Accessibility → `~/Applications/JevBar.app`).

## Licence

MIT. The computer-use engine it launches is Apache 2.0 and is not vendored here.
