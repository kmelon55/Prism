# Architecture

Prism for macOS is a Swift package in [`apps/mac`](../apps/mac/README.md): an AppKit shell with SwiftUI views and
one module per feature. It uses no WebView and no third-party packages.

```text
Prism (app shell) ─ palette panel, settings window, hotkeys, status item, usage ranking, legacy import
   │
   ├── PrismCalculator  PrismClipboard  PrismLibrary  PrismFiles  PrismEmoji  PrismSystem
   ├── PrismScripts     PrismAI         PrismDictation  PrismBackup  PrismUpdates
   │        each returns providers, settings panes and background work as a FeatureContribution
   │
   └── PrismKit ─ contracts (PaletteProvider, SettingsPane, PrismContext), storage (AppPaths, SQLiteDatabase,
          │       JSONFileStore, Keychain), shared UI (glass, controls, settings layout)
          └── PrismCore ─ platform-independent search, ranking, frecency and web intents
```

Feature modules depend only on `PrismKit` and `PrismCore`, never on each other. See
[`apps/mac/README.md`](../apps/mac/README.md) for how a feature plugs in, conventions and build commands.

## Data

The app keeps the bundle identifier `dev.prism.desktop` and the data folder
`~/Library/Application Support/dev.prism.desktop`, with the file names, SQLite schemas and keychain services of the
earlier Tauri app, so data from it loads unchanged. Settings the Tauri app kept in WebView storage (appearance,
aliases, disabled commands, script folders) are imported once on first launch. Development builds use
`dev.prism.native-dev` and never touch the installed app's data.

## History

Prism 0.1.x was a Tauri, React and Rust app. Its source, kept on the
[`legacy/tauri`](https://github.com/kmelon55/Prism/tree/legacy/tauri) branch, remains the reference for data formats.
Feature documents in this folder describe intended behavior; some still name the Tauri implementation.
