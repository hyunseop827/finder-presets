# Finder Presets

<p align="center">
  <img src="docs/images/app-icon.png" alt="Finder Presets icon" width="96">
</p>

[한국어 README](README.ko.md)

Save a Finder view as a preset and apply it to any folder, to all its subfolders, or to Finder's default view in one click.

<p align="center">
  <img src="docs/images/screenshot-en-dark.png" alt="Finder Presets main window with presets, target folders and the system-wide bar" width="720">
</p>

## Download

**[Download the latest DMG](https://github.com/hyunseop827/finder-presets/releases/latest/download/FinderPresets.dmg)** · Free · Apple Silicon · macOS 14 or later

- **Install:** open the DMG and drag **Finder Presets** to **Applications**.
- **Update:** from 0.3.0 on, the app updates itself. Choose **Finder Presets → Check for Updates…** (or **Check for Updates** at the bottom right of the window) to check right away; while it is running, the app also checks once a day on its own. When there is a newer version, it shows what changed and asks. Only when you choose **Install Update** does it download the new version, verify its signature, replace the app and reopen it. Keep the app in **Applications**. An app opened inside the DMG cannot update itself. Versions before 0.3.0 have no updater: replace the app with the one from the new DMG once.
- **First launch:** the app is ad-hoc signed and not notarized by Apple. If macOS blocks it, try opening it once, then choose **System Settings → Privacy & Security → Open Anyway** ([Apple's instructions](https://support.apple.com/guide/mac-help/mh40616/mac)).
- **Finder permission:** when the app first restarts Finder, macOS asks to let it control Finder. Allow it. After an update, macOS may ask again, for Finder and for folders it protects: the app is ad-hoc signed, so each version counts as a new app to macOS.
- **What's new:** see the [release notes](https://github.com/hyunseop827/finder-presets/releases).

<details>
<summary>Verify the download checksum</summary>

```zsh
curl -LO https://github.com/hyunseop827/finder-presets/releases/latest/download/FinderPresets.dmg
curl -LO https://github.com/hyunseop827/finder-presets/releases/latest/download/FinderPresets.dmg.sha256
shasum -a 256 -c FinderPresets.dmg.sha256
```

</details>

## Features

<table>
  <tr>
    <td width="50%"><img src="docs/images/editor-en.png" alt="Preset editor" width="420"></td>
    <td width="50%"><b>Presets from real folders</b><br><br>Drag in a folder you already arranged, or build a preset in the editor. Set any view option: icon, list, column or gallery view, icon and text size, sorting, grouping and more. Options left on "Keep" stay as they are.</td>
  </tr>
  <tr>
    <td width="50%"><b>Live preview</b><br><br>While you edit, a sample folder is drawn with the preset, so you see the result before you apply it.</td>
    <td width="50%"><img src="docs/images/preview-en.png" alt="Live preview window" width="420"></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/images/guide-en.png" alt="Shortcut setup guide" width="420"></td>
    <td width="50%"><b>Quick preset shortcut</b><br><br>Star a preset and press a shortcut such as ⌃⌥⌘P to apply it to the front Finder window's folder. A step-by-step guide shows where to set the shortcut.</td>
  </tr>
  <tr>
    <td width="50%"><b>History and undo</b><br><br>Every change is backed up first. Pick any operation in History (⌘Y) and undo it.</td>
    <td width="50%"><img src="docs/images/history-en.png" alt="History with undo" width="420"></td>
  </tr>
</table>

- **Per-folder presets:** give each folder its own preset and apply to the selected folders or all of them, with or without subfolders.
- **System-wide:** change Finder's default view and, optionally, your home folder in one step.
- **Finder restarts for you:** the app restarts Finder when needed and reopens your Finder windows.
- **Finder right-click menu:** add folders, make presets or apply from Finder's Services menu.
- **English and Korean**

## Privacy

- No accounts and no usage tracking.
- The only thing the app uses the internet for is the update check. Once a day while it is running, and when you choose **Check for Updates…**, it reads the latest release's list of updates (`appcast.xml`) from GitHub. Nothing about your files is sent.
- The new version is downloaded from GitHub only when you choose to install it, and it is checked against the signing key (EdDSA) inside the app before it is opened. Updates are handled by [Sparkle](https://sparkle-project.org).
- Sparkle keeps a little state in the app's preferences (when it last checked, a skipped version, window positions).
- **Native:** Swift/SwiftUI; no background process, menu bar agent or login item.
- **Careful writes:** changes only the Finder view settings (`.DS_Store`) of the folders you apply to, after backing them up, never through Finder scripting.
- **Local data:** presets, the folder list and the history with its backups stay in `~/Library/Application Support/FinderPresets`.

## Removal

- Quit the app and move `/Applications/Finder Presets.app` to Trash.
- To remove its data too, delete `~/Library/Application Support/FinderPresets`, `~/Library/Caches/com.hyunseop.FinderPresets` and `~/Library/HTTPStorages/com.hyunseop.FinderPresets` and run `defaults delete com.hyunseop.FinderPresets`.
- Folders keep the views you applied. To get the old views back, undo them in **History** first.

## Development

```sh
./scripts/build-app.sh [debug|release]   # build/Finder Presets.app
./scripts/test.sh                        # unit tests
./scripts/make-dmg.sh [version]          # build/FinderPresets-<version>.dmg
FINDER_PRESETS_DATA_DIR=/tmp/fp swift run finder-presets   # dev CLI (plan, apply, undo on test folders)
```

- **Requires** Xcode 26 or later (Swift 6.2).
- **Releases:** CI publishes each new version from `main`; [AGENTS.md](AGENTS.md) explains how changes get there.
- **Test data:** set `FINDER_PRESETS_DATA_DIR` to another folder so development runs don't touch your real presets and history.
- **UI checks:** debug builds can run `--layout-probe` (fixed layout, both languages, light and dark) and `--selftest` (the app's flows end to end); [AGENTS.md](AGENTS.md) explains how.

## Built with AI

Designed and directed by me, implemented with AI coding agents (Claude Code), and checked by 249 unit tests, CI, an in-app layout probe and hands-on tests with the real Finder. [How it was built](docs/AI_DEVELOPMENT.md) describes the workflow and the decisions; the agents follow [AGENTS.md](AGENTS.md), the rules for any coding agent working here.

## License

- [MIT](LICENSE): use, modify, and distribute freely; provided as-is without warranty.
- Reads and writes `.DS_Store` files with [sindresorhus/DSStore](https://github.com/sindresorhus/DSStore) (MIT).
- Updates itself with [Sparkle](https://github.com/sparkle-project/Sparkle) (MIT).
