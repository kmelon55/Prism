Prism 0.1.3 fixes importing current Raycast exports and simplifies successful dictation delivery.

- Recognize Raycast X schema 3 (`RAYCFG3`) exports. Encrypted files now request the export password instead of incorrectly reporting an invalid file. Older export formats remain supported.
- Import current Raycast window-management shortcuts and aliases, including halves, thirds, maximize, sixths, and movement between displays. Existing shortcut conflicts remain visible before applying changes.
- Dismiss the dictation overlay after successful delivery. Refinement failures still show a warning; token and cost details remain available in Settings → AI.

These downloads are for macOS; no Windows, Linux, or Android public release is included.

Download the universal DMG or ZIP for Apple Silicon and Intel Macs running macOS 14 or later. Existing installations can use Settings → General → Check for updates, then install and restart when ready.

The macOS app uses the same persistent Prism Local Signing certificate and updater key. It is not Apple notarized; a first installation may require System Settings → Privacy & Security → Open Anyway.
