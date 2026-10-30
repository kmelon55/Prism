# Prism for macOS (native)

Prism's macOS app since 0.2.0: a pure Swift rewrite of the Tauri app of 0.1.x, whose source is kept on the
[`legacy/tauri`](https://github.com/kmelon55/Prism/tree/legacy/tauri) branch. It is small (a 17 MB bundle instead of
56 MB, well under 100 MB of memory instead of about 456 MB), opens windows instantly and looks native.
macOS 14+, Apple Silicon and Intel.

## Layout

| Target | Owns |
| --- | --- |
| `PrismCore` | Platform-independent search and ranking. No AppKit or SwiftUI. |
| `PrismKit` | Contracts and shared services: `PaletteProvider`, `PaletteItem`, `FeatureContribution`, `SettingsPane`, `PrismContext`, `AppPaths`, `SQLiteDatabase`, `JSONFileStore`, `Keychain`, `PasteService`, `Permissions`, `AppIconCache`, `KeyHint`. |
| `Prism` | The app shell: palette window, settings window, global hotkey, status item, HUD, snapshot renderer, `FeatureRegistry`. |
| `PrismCalculator` | Arithmetic, units, currency, date/time and number formatting answers. |
| `PrismClipboard` | Clipboard history: capture, storage, search, preview, paste. |
| `PrismLibrary` | Quicklinks, snippets, notes, favorites, snippet expansion. |
| `PrismFiles` | Filename search through Spotlight and indexed folders, file previews. |
| `PrismEmoji` | Emoji picker. |
| `PrismSystem` | System and power commands, window management, permissions, launch at login. |
| `PrismScripts` | Script commands (Raycast script command format), arguments, runs. |
| `PrismAI` | AI chat window, providers, streaming, history, usage, tools. |
| `PrismDictation` | Dictation recording, transcription, overlay, text insertion, models. |
| `PrismBackup` | Backup, restore, Raycast import. |
| `PrismUpdates` | Checking for, verifying and installing updates. |

Feature modules depend only on `PrismKit` (and through it `PrismCore`), never on each other or on the app.
Each one exposes `XFeature.make(context:) -> FeatureContribution`, which `FeatureRegistry` already calls, so a
feature appears in the app as soon as its `make` returns providers or panes.

## How a feature plugs in

- **Root search rows:** return `PaletteProvider`s. `results(for:)` runs on every query change, including the
  empty query; the palette ranks `.search` providers with `CommandSearch`, groups rows by
  `SearchCandidate.section`, and drops stale answers. Query-specific answers (a calculation, a web search) set
  `SearchCandidate.matchedQuery` to the query so they rank first. Spotlight-style results use `.appended`.
  Always return command rows for the empty query too (hotkeys and the Shortcuts settings look them up there);
  set `PaletteItem.hiddenWhenQueryIsEmpty` for rows the root list should only show once the user types.
- **Actions:** the first `PaletteAction` runs on Return; the others appear in the ⌘K panel and run directly
  through their `shortcut`. Return `.dismiss`, `.keepOpen`, `.notify("Copied")` or `.push(PaletteScreen)`.
- **Screens:** a `PaletteScreen` replaces the root results with a feature view (clipboard history, emoji
  picker). The screen owns its own search field, focus and arrow keys; Escape returns to the root.
  A global hotkey can open a screen directly with `context.showPalette(screen:)`.
- **Settings:** return `SettingsPane`s. Use `Form { … }.formStyle(.grouped)` to match System Settings.
  Orders: General 0, Clipboard 100, Library 200, Files 300, Scripts 400, Windows/System 500, AI 600,
  Dictation 700, Backup 800, Advanced 900.
- **Background work:** put monitors and event taps in `FeatureContribution.start`, which runs after launch.
- **Own windows:** a feature may manage its own `NSWindow`/`NSPanel` (AI chat, dictation overlay, notes).
- **Command IDs and hotkeys:** give every command row the same ID the Tauri app used (`clipboard:open-history`,
  `window:left-half`, …; see `apps/desktop/src/providers` on `legacy/tauri`). The shell owns `command-shortcuts-v1.json`,
  registers those hotkeys and runs the row's first action, so features do not register command hotkeys or
  build their own shortcut recorders. `Shortcut(accelerator:)` reads the Tauri format (`shift+super+KeyV`).
  Features that need a non-command global key (dictation's double-tap) handle it themselves.

## Conventions

- **Swift 6 strict concurrency.** UI and providers are `@MainActor`; move slow work to a detached task.
- **No third-party packages** unless agreed first. Use SQLite3, URLSession, FSEvents, Security, AppKit.
- **Data compatibility.** The release app keeps bundle ID `dev.prism.desktop` and the Tauri data folder
  `~/Library/Application Support/dev.prism.desktop`, so existing data must load unchanged: same SQLite file
  names, tables and columns, same JSON files and keys, same keychain services (`dev.prism.desktop.ai`,
  `dev.prism.desktop.ai.compatible`). The Rust code in `apps/desktop/src-tauri/src` on the `legacy/tauri` branch is the specification.
  Never run a destructive migration on those files; add columns or tables only when needed.
- **Never write to the installed app's data.** Development builds use `dev.prism.native-dev` automatically and
  tests use `PRISM_DATA_DIR` or temporary directories. Reading a live file read-only to learn its schema
  (`sqlite3 -readonly file '.schema'`) is fine; copying personal records into fixtures is not.
- **Memory.** Use `LazyVStack`/`List` for long lists, bounded `NSCache`s for images, and load large clipboard
  images or files only when previewed. Do not use `WKWebView`.
- **Localization.** Write English source strings and add Korean to the module's
  `Resources/ko.lproj/Localizable.strings` (the shell's are in `Sources/Prism/Resources`). Give command rows
  `searchAliases` with both the English and Korean title so either language finds them. In feature modules use `String(localized: "…", bundle: .module)` and
  `Text("…", bundle: .module)`; plain `Text("…")` looks in the main bundle and will not be translated.
  Match the Korean wording of `apps/desktop/src/locales` on `legacy/tauri`.
- **Tests.** Use Swift Testing (`import Testing`).
- **Style.** Match the existing code: small types, doc comments only where intent is not obvious.

## Build, test and look at it

```sh
swift build                                # whole app
swift build --target PrismClipboard        # one module
swift test --filter PrismClipboardTests    # one module's tests

# Render the palette and settings without showing windows (no Computer Use needed).
PRISM_DATA_DIR=/tmp/prism-snap/data .build/debug/Prism --render-snapshots /tmp/prism-snap \
  --appearance dark --query "2+2" --open "clipboard history" --pane clipboard
# Add `-AppleLanguages "(ko)"` to render in Korean. The executable embeds a development Info.plist
# (Support/Info.plist), so this works without packaging.

scripts/build-app.sh                       # a runnable "Prism Dev.app" (bundle ID dev.prism.native-dev)
```

When several people or agents build at once, give each a separate `--scratch-path` (for example
`.build-clipboard`) so they do not wait on the same build lock.

## Status (2026-10-30)

Every feature of the Tauri app is ported, with about 580 Swift tests, and 0.2.0 ships this app. The UI follows the
Tauri app's design (monochrome glass, flat settings rows); shared building blocks live in `Sources/PrismKit/UI`
(`PrismTheme`, `PrismControls`, `SettingsLayout` and the `*Components.swift` files), and feature screens should use
them rather than stock `Form`, bordered or accent-colored controls.

Release packaging, signing and publishing are in [the release guide](../../docs/releases.md).

Known gaps compared with the Tauri app: no persisted file index or FSEvents watch for indexed folders, emoji recents
from WebView storage are not imported, and the updater has no admin-password fallback or download progress. The
update from an installed 0.1.x through its Tauri updater has not been exercised end to end.
