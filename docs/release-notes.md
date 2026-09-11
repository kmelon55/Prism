Prism 0.1.5 makes updates easier and fixes saved-key access and dictation error languages.

- Show available updates in the launcher automatically, with direct install and restart actions. Background checks run after startup and every six hours.
- Add Install updates automatically in Settings → General. It is off by default. When enabled, Prism downloads and verifies new versions in the background; changes take effect on the next restart without interrupting current work.
- Request required Keychain authorization when starting dictation or an AI request, without a detour through Settings. Keep settings checks silent, reuse authorized keys, and distinguish canceled authorization from other failures.
- Make native dictation errors follow the app language, including saved-key failures on the first recording attempt. Language changes apply without editing dictation settings.
- Keep the launcher running when its window is closed. Cmd+Q closes the current window instead of quitting Prism. Add explicit Quit Prism actions in the launcher and settings. Escape closes the settings window.

Download the universal DMG or ZIP for Apple Silicon and Intel Macs running macOS 14 or later. Existing installations can install this release through Settings → General → Check for updates. The new launcher notifications and automatic-install setting become available after upgrading to 0.1.5.

The macOS app uses the existing Prism Local Signing certificate and updater key. It is not Apple notarized; a first installation may require System Settings → Privacy & Security → Open Anyway. Local-signed updates can still require renewed macOS Keychain approval.

No Windows, Linux, or Android public release is included.
