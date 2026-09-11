Prism 0.1.9 adds a clipboard history preference for dictation.

- Add “Save dictation results to clipboard history” in dictation settings, enabled by default for new and existing installations.
- Honor the preference for copy, paste, send, and copying the last result or original text. Clipboard history must also be enabled globally.
- When disabled, exclude dictated text from both direct history saves and the clipboard monitor while keeping text delivery available.
- Keep recovery files independent of the history preference: failed recordings remain recoverable and transcribed text is saved before delivery.
- Continue dismissing successful dictation immediately without completion notices.

Download the universal DMG or ZIP for Apple Silicon and Intel Macs running macOS 14 or later. Existing installations can update from the first palette row when available, or Settings → General → Check for updates, then restart Prism.

The macOS app uses the existing Prism Local Signing certificate and updater key. It is not Apple notarized; a first installation may require System Settings → Privacy & Security → Open Anyway. Local-signed updates can still require renewed macOS Keychain approval.

No Windows, Linux, or Android public release is included.
