# AGENTS.md

The brief for any coding agent (Claude Code, Codex, Cursor, …) working in this repository. Read it before you change
anything. The maintainer, Hyunseop Kim, decides what ships; every outward action (push, tag, release, anything on
GitHub) needs the maintainer's explicit go-ahead in the conversation.

## What this is

Finder Presets is a native macOS 14+ app (Swift 6.2, SwiftUI, SwiftPM — no Xcode project) that saves Finder view
settings as presets and applies them to folders, their subfolders, or Finder's default view. It writes the folders'
`.DS_Store` records directly (through [sindresorhus/DSStore](https://github.com/sindresorhus/DSStore)), backs every
change up first, keeps a history with undo, and has no background process, no network access and no telemetry.

## Layout

| Path | What |
|---|---|
| `Sources/FinderPresetsCore/` | The engine, no UI: `DSStoreLayer/` (records ↔ view settings), `Planning/` (which folders, which records), `Apply/` (write, undo, Finder's global defaults), `Finder/` (quit/launch/windows, global defaults), `Storage/` (presets, history, backups, retention), `Model/`. |
| `Sources/FinderPresets/` | The app: `AppModel` (state and actions), `HistoryModel`, `QuickPreset` (the ⌃⌥⌘P service), `FinderServices`, `PresetEditor`/`PresetPreview`, `Views/` (SwiftUI). `SelfTest.swift` and `LayoutProbe.swift` are debug-only harnesses (`#if DEBUG`). |
| `Sources/finder-presets/` | A dev CLI for integration checks on test folders (not shipped in the DMG). |
| `Tests/` | `FinderPresetsCoreTests`, `FinderPresetsTests` (app models, no window), `FinderPresetsCLITests`. |
| `Resources/` | `Info.plist`, the icon, and `ko.lproj`/`en.lproj` strings. Korean is the source language. |
| `scripts/` | `build-app.sh`, `test.sh`, `make-dmg.sh`, `make-icon.swift`, `toolchain.sh`, `select-xcode.sh` (CI). |
| `.github/workflows/` | `ci.yml` (tests + release build); on `main` it calls `release.yml`. |

## Commands

```sh
./scripts/test.sh                          # all three test targets (~25 s warm)
./scripts/build-app.sh                     # debug app → build/Finder Presets.app
./scripts/build-app.sh release             # release app (what the DMG ships)
OUTPUT_DIR=/tmp/fp-app ./scripts/build-app.sh   # build somewhere else (keep build/ for the maintainer's own copy)
/opt/homebrew/bin/actionlint .github/workflows/*.yml
```

Xcode 26 or later is required (`scripts/toolchain.sh` picks it). Always finish with a green `./scripts/test.sh`.

## Safety rules (non-negotiable)

- **Never touch the maintainer's real data.** Every run that is not a unit test sets `FINDER_PRESETS_DATA_DIR` to a
  throwaway folder. Never write to `~/Library/Application Support/FinderPresets` or the real `com.hyunseop.FinderPresets`
  defaults.
- **Test folders live in `~/FinderPresets-Test` only**, and you delete them (and any test defaults domain or saved window
  state) when you are done. Leave no traces.
- **Do not restart or quit Finder** unless the maintainer said so in this conversation. Unit tests use fake Finder
  lifecycles; the self-test and the layout probe never touch Finder.
- **Never change Finder's global defaults** (`com.apple.finder`) outside the app's own tested code path.
- **Writes stay inside the folders the user chose.** The app refuses `/`, `/Users` and anything above the home folder,
  and skips `/Volumes`; keep it that way.
- **No network code.** The only link out is `ReleaseLink`, which asks macOS to open the releases page.
- Do not commit, push, tag or create releases unless asked. Never put secrets, tokens or personal paths in the repo.

## Invariants worth knowing before you edit

- **Finder restart order:** read the open Finder windows → quit Finder → write → launch → reopen the windows → settle →
  read back. Finder writes its in-memory view state when it quits, so writing before the quit loses the change.
- **History is written before the folders:** `Applier`/`UndoService` record each store's entries and backup and save the
  manifest *before* they rename the new `.DS_Store` into place, so a crash never leaves a change undo cannot reach.
- **List records:** a folder may have `lsvC`, `lsvP` and/or the older `lsvp`; a missing one is derived from the folder's
  other one (`ViewRecordCodec.arrayForm`/`dictForm`), never from global defaults.
- **Quick preset:** reads the front Finder window's current view by Apple Event (Finder writes view changes lazily) and
  restarts Finder only when the view differs or is unknown.
- **Fixed window:** the main window's content is always 720×440 (`UILayout`), nothing can push it; the layout probe
  checks this. The window has no toolbar: History, the guide and the version link are text links in the status bar.

## Conventions

- Match the surrounding code: tabs, small focused types, comments in English that say *why*, about as dense as the file
  you are in.
- **UI text:** write Korean with `String(localized:)`, then add the key with its Korean and English text to
  `Resources/ko.lproj` and `Resources/en.lproj` (`.strings`, or `.stringsdict` for plurals). `LocalizationTests` fail on
  an untranslated key, an unused key or a Korean literal outside `String(localized:)` (mark deliberate ones
  `// l10n-exempt`). Refer to places by name and shortcut — `"기록"(⌘Y)` — not by position.
- New behavior gets a focused test. Models are tested without windows; for UI, extend the layout probe.

## Verifying a change

1. `./scripts/test.sh` — must pass.
2. For UI changes, the layout probe in both languages (debug build, isolated data that already holds presets, folders
   and a few operations — make them with the dev CLI on folders under `~/FinderPresets-Test`):
   `FINDER_PRESETS_DATA_DIR=<data> "<app>/Contents/MacOS/FinderPresets" --layout-probe` → `[layoutprobe] PASS`.
   It opens the window on screen for a minute or two; run it while the maintainer is not using the Mac.
3. For flows (import, apply, undo, editor, services, quick preset): the self-test, with an **empty** data folder,
   `<targetRoot>` holding `B` and `C/C1`, and two source folders that already have different views (apply two presets to
   them with the dev CLI first):
   `FINDER_PRESETS_DATA_DIR=<empty> "<app>/Contents/MacOS/FinderPresets" --selftest <src1> <targetRoot> <src2>` →
   `[selftest] PASS`.
4. `./scripts/build-app.sh release` must build without warnings.
5. Real-Finder checks (an actual restart, the ⌃⌥⌘P shortcut) are done by the maintainer from a checklist you prepare:
   set everything up first, give one list, and verify at the end.

## Releases

Raise `CFBundleShortVersionString` in `Resources/Info.plist`, write `.github/release-notes.md` (first line
`# v<version>`), push to `main`. After the tests pass, CI tags `v<version>`, builds the DMG, publishes the release and
checks the README's `releases/latest/download/FinderPresets.dmg` link. Nobody pushes tags by hand. Changing the app
(`Sources`, `Resources`, `Package.*`, the build scripts) after a release without raising the version fails CI on purpose.

## More context

- [docs/AI_DEVELOPMENT.md](docs/AI_DEVELOPMENT.md) — how this app was built with AI agents, and the decisions behind it.
- [README.md](README.md) — what users see.
