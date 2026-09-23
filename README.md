# JevBar

**A macOS desktop agent, with Jev.**

JevBar lives in your menu bar. Hold a key, say what you want, and it gets done in whatever application is in front of you. It fills in job applications, opens and closes apps, websites and folders, and handles several tasks from a single sentence.

## Features

- **Voice control.** Hold ⌘⇧Space and speak. A small overlay shows your words live as you talk. Speech recognition runs on your Mac.
- **Application forms, filled completely.** Text fields, search boxes with suggestions, dropdowns, radio buttons, checkboxes and dates are all handled, in page order, scrolling through the whole form.
- **Written answers from your CV.** Open questions and short essays are drafted with Gemini, grounded in your own CV and profile. Nothing is invented.
- **Desktop tasks.** Open or close any app, open websites and folders, and search sites such as YouTube.
- **Multi-step commands.** "Open YouTube and search Jev" or "open my Downloads folder, then close Safari" runs as one request.
- **A clear report.** After filling a form, JevBar lists what it filled and what it left for you to answer.

## Safety

These are product commitments, not settings, and each one is covered by tests.

- **Applications are never submitted.** JevBar fills a form and stops for your review. Any control that looks like a final submit is refused.
- **Passwords, passkeys and one-time codes are never entered or stored.**
- **Nothing is sent on your behalf.** Send, reply, post and publish are refused. JevBar prepares, and you decide.
- **Personal questions stay yours.** Grades, family, salary, demographics and offers from other companies are only answered from your saved profile, never guessed by a model.
- **Every action is authorised in code.** A pure function checks each click and keystroke against the control's real accessible name, not the model's description of it.
- **Models choose, they do not point.** A model picks an element from a list JevBar built by reading the screen. It never supplies coordinates or selectors.

## How it works

JevBar reads the screen through the macOS accessibility tree using [munim-computer-use](https://github.com/munimtechnologies/munim-computer-use) (Apache 2.0), a Swift MCP server that provides element ids and delivers input in the background. Because it works on the accessibility tree, the same approach applies to Safari, Chrome, Notes, Finder and native apps alike, with no browser extension required.

Common commands such as opening apps, searching sites and clicking named links are handled directly and deterministically. Form filling reads the page as a list of questions and uses a tested method for each kind of control. Gemini is used for open-ended answers and for decisions the rules do not cover.

## Setup

Requirements: macOS 14 or later, Xcode Command Line Tools (Swift 6.1) and git.

```bash
git clone https://github.com/jxzxl07/JevBar.git
cd JevBar
make
```

The first build takes a few minutes: it compiles the computer-use engine from its pinned open-source release and creates a local signing certificate. After that, JevBar appears in your menu bar.

Then:

1. **Grant Accessibility access** in System Settings, under Privacy & Security, Accessibility, for `~/Applications/JevBar.app`. Allow the microphone and speech recognition the first time you hold ⌘⇧Space.
2. **Add a Gemini API key.** Click the menu bar icon and paste your key. You can get one free at [aistudio.google.com](https://aistudio.google.com/apikey).
3. **Fill in your profile.** Click **Profile** in the menu bar window and add your details. Set `cvPath` to your CV (a PDF) so written answers can draw on it. Anything a form asks that your profile does not cover, JevBar asks you once and remembers.

Rebuilding keeps your permissions, because the signing identity and install path stay the same. `make run` rebuilds and relaunches in the background, and `make test` runs the test suite.

## Privacy

Your profile, CV and API key stay on your Mac. Only the text needed to answer a question is sent to Gemini. Keys are never committed to this repository.

## Licence

MIT. The computer-use engine JevBar launches is Apache 2.0 and is not vendored here.
