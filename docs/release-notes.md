Prism 0.2.0 is a native macOS app. It replaces the Tauri, React and Rust app of 0.1.x with Swift, AppKit and SwiftUI, and keeps your data, settings, shortcuts and permissions.

- Lighter and faster: the app is about 17 MB instead of 56 MB and uses well under 100 MB of memory instead of about 450 MB. Windows open instantly and use the system's glass.
- Everything from 0.1.19 carries over: app and file search, clipboard history, snippets and expansion, notes and quicklinks, emoji, calculator with units, currency and dates, window management, script commands, AI chat, dictation, backups and the Raycast import.
- Your existing data stays where it was and loads unchanged, including clipboard history, library, AI conversations, provider keys, dictation models, global shortcuts and aliases. Appearance settings and aliases from the old app are imported on first launch.
- The empty palette now leads with favorites and your most-used apps and commands. Launch history from 0.1.x counts.
- Type a URL to open it, `web <query>` to search, or fall back to a web search when nothing matches.
- The AI chat model picker and the dictation text model share one searchable catalog.

Download the universal DMG or ZIP for Apple Silicon and Intel Macs running macOS 14 or later. Installed 0.1.x copies update in place through Settings → General → Check for updates.

The app uses the existing Prism Local Signing certificate and updater key, so macOS permissions stay granted. It is not Apple notarized; a first installation may require System Settings → Privacy & Security → Open Anyway.

Validation covers about 580 Swift tests, the release script tests, universal packaging, installed-signer compatibility, updater signatures and checksums, and daily use on the signing Mac. The update from 0.1.x through the old app's updater was not exercised end to end.
