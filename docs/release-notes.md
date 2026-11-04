Prism 0.2.2 fixes shortcut recording and makes English and Korean settings apply consistently across the app.

- Change the interface language immediately without restarting Prism. Settings, menus, command results, notch tools, emoji labels and sync categories now follow the same language preference.
- Translate previously hard-coded device sync controls, status messages, errors, AI provider descriptions and built-in dictation instructions. Custom instructions, notes and other user-written content remain unchanged.
- Add a dedicated Use Command Space action in Launcher settings, with instructions and a shortcut to macOS Keyboard settings when Spotlight or another system shortcut uses the same keys.
- Fix recorded launcher shortcuts reverting to the previous combination. Shortcut registration now resumes before the recorded combination is applied.
- Add regression checks for language switching, translation coverage, shortcut recording and preservation of custom dictation instructions.

Download the universal DMG or ZIP for Apple Silicon and Intel Macs running macOS 14 or later. The existing code-signing identity and updater key are preserved. This release is not Apple notarized; first installations may require System Settings → Privacy & Security → Open Anyway.

Validation covers the native and release-script test suites, English → Korean → English switching across 15 settings panes, and rendered settings screens. Installed-app upgrades and physical keyboard or permission interactions are separate from these automated checks.
