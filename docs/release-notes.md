Prism 0.1.4 improves window shortcuts and background launcher behavior.

- Keep repeated Right Half layouts aligned to the right edge through the half, one-third, and two-thirds cycle. Make room before expanding windows whose apps constrain resizing at screen edges, and track the actual applied frame for subsequent shortcuts.
- Run window, app-launch, and system shortcuts without briefly opening the command palette. Failed commands still show their error.
- Keep Prism running when Cmd+Q is pressed. Use the explicit Quit Prism application-menu action to exit.
- Suppress unsolicited login-Keychain password dialogs and silently reuse already-authorized AI and dictation keys after restart. Settings explain the Always Allow option. Local-signed updates can still require renewed Keychain approval; this release does not remove that macOS signing limitation.

These downloads are for macOS; no Windows, Linux, or Android public release is included.

Download the universal DMG or ZIP for Apple Silicon and Intel Macs running macOS 14 or later. Existing installations can use Settings → General → Check for updates, then install and restart when ready.

The macOS app uses the same persistent Prism Local Signing certificate and updater key. It is not Apple notarized; a first installation may require System Settings → Privacy & Security → Open Anyway.
