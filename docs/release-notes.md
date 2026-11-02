Prism 0.2.1 adds selective self-hosted synchronization and new native tools.

- Choose notes, snippets, quick links, shortcuts, appearance settings and supported provider API keys for encrypted device backups, one-time imports or automatic synchronization. Connecting alone never changes local settings. API keys are stored in the receiving Mac's Keychain. Conflicting edits require explicit resolution.
- Share clipboard text through the optional TanStack Start/PostgreSQL server. Sending captured text is opt-in; received text is copied explicitly. Official Prism Cloud remains coming soon, and Android synchronization is not available yet.
- Add optional notch tools for quick notes, clipboard, dictation, a countdown timer, Keep Awake and audio controls.
- Add opt-in keyboard remapping, including tap-and-hold keys and per-application shortcut remaps.
- Improve calculator answer cards, Korean number parsing, unit conversions, pointer selection and application icons.
- Add per-app audio and output controls. These require the relevant macOS permissions and do not save or transmit captured audio.

Download the universal DMG or ZIP for Apple Silicon and Intel Macs running macOS 14 or later. The existing code-signing identity and updater key are preserved. This release is not Apple notarized; first installations may require System Settings → Privacy & Security → Open Anyway.

Validation includes the full native test suite, release-script tests, sync API tests and production builds. Physical cross-device synchronization, Android integration and real-device battery measurements are not included in this validation. Custom-provider API keys/endpoints are not transferable yet. Imports select feature categories, not individual notes.
