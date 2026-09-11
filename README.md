# Prism

[English](README.md) · [한국어](README.ko.md)

A keyboard-first launcher for macOS. Find apps and files, manage your clipboard,
run commands, and work with AI from one compact palette. Free and open source under MIT.

**[Download Prism for macOS](https://github.com/kmelon55/Prism/releases/latest)** ·
[Contributing](CONTRIBUTING.md) · [Release guide](docs/releases.md)

## Install

Requires **macOS 14 or later**. The universal build supports **Apple Silicon and Intel**.

1. Download the `.dmg` or `.zip` from [GitHub Releases](https://github.com/kmelon55/Prism/releases/latest).
2. Open the DMG and drag **Prism.app** into **Applications**, or extract the ZIP and move the app there.
3. Open `/Applications/Prism.app`. Keep this as your one installed copy.
4. Press **⌘⇧Space** to show or hide Prism. Use **⌘,** for Settings.

### First launch: Open Anyway

Prism 0.1.1 uses a **persistent local signing certificate, without Apple notarization**.
macOS may block the first launch because it cannot verify the developer.
After trying to open Prism, go to **System Settings → Privacy & Security → Open Anyway**,
then confirm **Open**. Only do this for a download you trust from this repository.
See [Apple's instructions](https://support.apple.com/en-us/102445).

Prism asks for permissions when a feature needs them. Accessibility enables window
management and inserting text into other apps; dictation needs microphone access.
Existing ad-hoc installations may need one-time authorization when moving to the
persistent certificate. Subsequent updates verify the app signing identity before
replacement. Update archive signatures are separate from Apple notarization.

## Updates and everyday use

Prism runs in the background when its palette is hidden. Opening it again brings
back the existing instance. To start it when you sign in, add **Prism.app** in
**System Settings → General → Login Items**.

The installed app checks GitHub for updates at startup and every six hours. A new
version appears in an in-app notice and **Settings → General**. Choose **Download
and install**, then **Restart Prism** when you have finished your current work.
Checks are automatic; installation and restart are explicit. You can also use
**Check for updates** at any time. Network failures leave the current app usable.

Settings and local history live in `~/Library/Application Support/dev.prism.desktop`
and the app's WebKit storage. Provider keys stay in macOS Keychain. Updating the app
keeps these separate from the installed executable.

## Features

- Fast app and file search, aliases, keyboard navigation, and global shortcuts.
- Clipboard history, snippets, script commands, local notes, and library search.
- Window positioning, calculator, unit conversion, and dated currency reference rates.
- Bring-your-own-key AI chat and voice dictation, with provider settings in the app.
- English and Korean UI, including Korean search support.

macOS is the current packaged release. Windows/Linux desktop code and the native
[Android launcher](apps/android/README.md) are in development; this release does not
include installers for those platforms. Individual features may require OS
permissions, local model setup, or your own provider account.

## Develop

Use **Node.js 22+**, **pnpm 10.27.0**, Rust, and Apple Command Line Tools.

```sh
pnpm install --frozen-lockfile
pnpm typecheck
pnpm test
pnpm build
cargo test --locked --manifest-path apps/desktop/src-tauri/Cargo.toml
```

For a browser preview, explicitly run `pnpm --filter @prism/desktop dev`.
For a native development session, explicitly run `pnpm tauri dev` after quitting
the installed app. Do not start another server if one is already running.
Debug builds do not install updates. Do not keep separate “Prism Test” copies.

For daily use, open `/Applications/Prism.app`. Source edits reach the installed app
only after a new GitHub release; they do not modify it live. See the
[release workflow](docs/releases.md) to publish the next version.

```text
apps/desktop/          React + Tauri desktop app
apps/android/          Native Android launcher in development
packages/command-core/ Shared command and search logic
docs/                  Architecture, feature notes, and release instructions
```

## License

[MIT](LICENSE). Third-party notices are kept with their source, including
[Whisp-derived dictation](apps/desktop/src-tauri/native/dictation/LICENSE-Whisp).
This project is not affiliated with the Minecraft project Prism Launcher.
