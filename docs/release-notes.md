Prism 0.1.12 improves clipboard history access, capture controls, and microphone error dismissal.

- Configure the clipboard history shortcut directly in Clipboard settings. Prepare the history view before showing the window when using its shortcut.
- Paste into the previous application with Return or double-click by default, and copy with Cmd+Return. Choose Copy as the default Return action in Clipboard settings to reverse these actions.
- Pause clipboard capture for 5, 15, or 60 minutes, resume early, and exclude selected applications while keeping existing history and pins. Exclusions apply to clipboard changes observed while the selected application is active.
- Keep expired entries out of search without running cleanup transactions for every query. Improve ordering indexes and coalesce rapid search input while preserving Unicode substring matching.
- Load Settings on demand to reduce the main JavaScript bundle, and release hidden dictation overlay views.
- Fix expired microphone error messages reappearing after language settings synchronize.

Download the universal DMG or ZIP for Apple Silicon and Intel Macs running macOS 14 or later. Existing installations can update from the first palette row when available, or Settings → General → Check for updates, then restart Prism.

The macOS app uses the existing Prism Local Signing certificate and updater key. It is not Apple notarized; a first installation may require System Settings → Privacy & Security → Open Anyway. Local-signed updates can still require renewed macOS Keychain approval.

Automated tests cover clipboard settings persistence, capture controls, search, presentation ordering, and error-overlay lifecycle. Actual installed-app hotkeys, external-app insertion, microphone capture, and end-to-end performance remain unverified on this revision. No Windows, Linux, or Android public release is included.
