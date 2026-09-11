Prism 0.1.8 removes unnecessary dictation completion notices.

- Finish dictation with recording → transcribing → text delivery, then dismiss the overlay immediately without a completion message.
- Remove the paste-request and recovery-folder notice after delivery to applications with opaque text inputs, including Orca.
- When refinement falls back to the original text and delivery succeeds, finish silently as well.
- Continue showing actionable recording, transcription, and delivery errors. Recovery files and enabled clipboard history continue saving in the background.

Download the universal DMG or ZIP for Apple Silicon and Intel Macs running macOS 14 or later. Existing installations can update from the first palette row when available, or Settings → General → Check for updates, then restart Prism.

The macOS app uses the existing Prism Local Signing certificate and updater key. It is not Apple notarized; a first installation may require System Settings → Privacy & Security → Open Anyway. Local-signed updates can still require renewed macOS Keychain approval.

No Windows, Linux, or Android public release is included.
