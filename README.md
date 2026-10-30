# Prism

[English](README.md) · [한국어](README.ko.md)

A keyboard-first launcher for macOS. Find apps and files, manage your clipboard, run commands, and work with AI
from one compact palette. A native Swift app, free and open source under MIT.

**[Download Prism for macOS](https://github.com/kmelon55/Prism/releases/latest)** ·
[Contributing](CONTRIBUTING.md) · [Release guide](docs/releases.md)

## Install

Requires **macOS 14 or later**. The universal build supports **Apple Silicon and Intel**.

1. Download the `.dmg` or `.zip` from [GitHub Releases](https://github.com/kmelon55/Prism/releases/latest).
2. Open the DMG and drag **Prism.app** into **Applications**, or extract the ZIP and move the app there.
3. Open `/Applications/Prism.app`. Keep this as your one installed copy.
4. Press **⌘⇧Space** to show or hide Prism (change it in **Settings → Launcher**). Use **⌘,** for Settings.

### First launch: Open Anyway

Prism is signed with a **persistent local certificate, without Apple notarization**. macOS may block the first
launch because it cannot verify the developer. After trying to open Prism, go to **System Settings → Privacy &
Security → Open Anyway**, then confirm **Open**. Only do this for a download you trust from this repository.
See [Apple's instructions](https://support.apple.com/en-us/102445).

Prism asks for permissions when a feature needs them. Accessibility enables window management, snippet expansion
and inserting text into other apps; dictation needs microphone access. Updates keep the same signing identity, so
permissions stay granted.

## Everyday use and updates

Prism runs in the background when its palette is hidden. To start it when you sign in, enable
**Settings → General → Launch at login**.

The app checks GitHub for updates at startup and every six hours. A new version appears in **Settings → General**.
Choose **Download and install**, then restart Prism when you have finished your current work. Every update is
verified against Prism's updater key before it replaces the app.

Settings and local history live in `~/Library/Application Support/dev.prism.desktop`; provider keys stay in the
macOS Keychain. Updating the app keeps both.

## Features

- App and file search with aliases, favorites, frecency, keyboard navigation and global shortcuts.
- Clipboard history, snippets with expansion, quicklinks, notes and script commands.
- Window management, calculator with units, currencies and dates, emoji picker, system commands.
- Bring-your-own-key AI chat and voice dictation, with local or provider models.
- Backups and an import from Raycast.
- English and Korean UI, including Korean search.

Prism 0.2 and later are native Swift. Prism 0.1.x was a Tauri app; its source is kept on the
[`legacy/tauri`](https://github.com/kmelon55/Prism/tree/legacy/tauri) branch, and installed 0.1.x copies update to
the native app in place. A separate native [Android launcher](apps/android/README.md) is in development.

## Develop

Use Apple Command Line Tools (Swift 6) and Node.js 22+ for the release scripts.

```sh
cd apps/mac
swift build
swift test
scripts/build-app.sh      # a runnable "Prism Dev.app" with its own data, beside the installed Prism
```

Development builds use the bundle identifier `dev.prism.native-dev` and their own data folder, so they never touch
the installed app. See [`apps/mac/README.md`](apps/mac/README.md) for the module layout and conventions, and the
[release guide](docs/releases.md) to package, sign and publish.

```text
apps/mac/        Native macOS app (Swift package)
apps/android/    Native Android launcher in development
scripts/         Packaging, signing and updater scripts
docs/            Architecture, feature notes and release instructions
```

## License

[MIT](LICENSE). Third-party notices are kept with their source, including
[Whisp-derived dictation](apps/mac/Sources/PrismDictation/Resources/LICENSE-Whisp.txt) and
[Unicode emoji data](apps/mac/Sources/PrismEmoji/Resources/UNICODE-LICENSE.txt).
This project is not affiliated with the Minecraft project Prism Launcher.
