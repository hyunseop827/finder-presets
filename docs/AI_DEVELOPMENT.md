# How Finder Presets was built

[한국어](AI_DEVELOPMENT.ko.md)

Finder Presets was built by one person working with AI coding agents. I (Hyunseop Kim) decided what the app should do,
how it should feel and what was good enough to ship; the agents — mainly [Claude Code](https://claude.com/claude-code) —
wrote most of the code, the tests and the documents under that direction. This page explains how that worked, because
the process is as much a part of the project as the code.

## Who did what

| Me | The agents |
|---|---|
| Chose the problem: one Finder view setup, applied everywhere, without a background app | Read Finder's `.DS_Store` format and the DSStore library, and built the engine |
| Wrote the requirements, in Korean, one conversation at a time | Turned them into plans, code and tests in small steps |
| Made every product decision (what the shortcut does, how errors read, the icon, the README) | Proposed options with trade-offs, and recommended one |
| Tested on the real Finder from checklists the agent prepared | Prepared test folders and checklists, then verified the results and cleaned up |
| Decided when each change shipped: nothing went out without my go-ahead ("올려", ship it) | Prepared the version and the release notes, shipped only on "올려", and never tagged or published by hand: CI does that |

## The workflow

1. **Ask.** A request in plain Korean ("the shortcut sometimes needs two presses — check it").
2. **Investigate before changing.** The agent reproduces the problem on test folders in `~/FinderPresets-Test` with an
   isolated data folder, so my real presets and history are never touched.
3. **Change in small steps,** each followed by the full test suite.
4. **Verify like a user would.** Unit tests cover the logic; the debug-only *layout probe* drives the real window in both
   languages and both appearances; the *self-test* drives the app's flows end to end; anything that needs the real Finder
   (restarts, the ⌃⌥⌘P shortcut) goes on a checklist I run once, after the agent has set everything up.
5. **Review adversarially.** For larger rounds, several agents review the code in parallel, each from one angle (engine,
   app state, UI and translations, CLI and CI, dead code, tests), and a separate skeptic tries to refute every finding
   before anything is changed. In the latest round 56 findings came back, 55 survived, and they were fixed in five
   sequential groups, each ending with a green test run.
6. **Ship through CI.** For an app change the agent raises the version in `Info.plist` and writes the release notes.
   When I say "올려" (ship it), it commits, opens a pull request and merges it once CI passes; CI on `main` then builds
   the DMG, tags, publishes, and downloads the README's link again to check it. Agents never tag or publish by hand.

[AGENTS.md](../AGENTS.md) is the written version of the rules the agents follow here, so any agent can pick the work up.

## Decisions that came out of this process

- **Finder must quit before the write.** Testing showed that Finder writes its in-memory view state for open windows when
  it quits, overwriting a fresh `.DS_Store`. The order became: read windows → quit → write → launch → reopen windows →
  settle → read back.
- **The quick preset reads what the window shows.** Finder writes view changes lazily, so the file on disk can be stale.
  The shortcut asks the front window for its current view and restarts Finder only when it differs.
- **No background process.** The shortcut is a macOS Service, so nothing runs until it is used. Because the shortcut can
  only be set in System Settings, the app shows a step-by-step guide that moves only when you press 이전/다음 (I asked
  for that after a first version that advanced on its own).
- **Finder windows come back.** After a restart the app reopens the Finder windows you had open, because Finder does not
  restore them after a scripted quit.
- **Safe scope.** The app refuses `/`, `/Users` and anything above your home folder (the system volume is read-only), and
  every change is backed up before it is written. History records a change before the folder is written, so undo can
  always reach it.
- **A quieter window.** The toolbar's three buttons became text links in the status bar (기록 · 사용법 · 업데이트 확인).
- **One icon, many drafts.** Several rounds of icon concepts were drawn in code and compared at Dock and Finder sizes; the
  two-tone folder won, and Apple's Finder face was avoided on purpose.
- **Release by version number,** the same model as my other app [Menu Pulse](https://github.com/hyunseop827/menu-pulse).
- **Updates inside the app (0.3.0).** Sparkle checks the release feed once a day and on 업데이트 확인…, and installs only when you choose; every update is verified with an EdDSA key whose private half only I hold. A local test on this Mac showed an ad-hoc signed copy updating itself and relaunching without Gatekeeper asking again, but with the app's hardened runtime and the daily check turned off; the settings this version ships with are not tested that way yet.

## By the numbers

- 249 unit tests across the engine, the app models and the CLI; CI on every push.
- A layout probe that checks the fixed window, every sheet and the status bar in Korean and English, light and dark.
- A self-test that runs import → apply → undo → editor → services → quick preset without touching Finder.
- Commits made with an agent carry a `Co-Authored-By: Claude` line.

## Why the loop matters

An agent writes code faster than anyone can read it, so the quality of this project rests on the loop around it: precise
requests, small changes, tests after every step, adversarial review, and real-world checks run by a person. Most of the
human time went into deciding and verifying, not typing.
