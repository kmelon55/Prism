Prism 0.1.6 fixes dictation completion and makes failed text delivery recoverable.

- Dismiss the dictation overlay before text delivery begins, preventing the waveform from briefly reappearing after transcription.
- Copy each completed transcript to the clipboard before attempting insertion, and verify that the clipboard contains the text. Dictated text remains excluded from clipboard history.
- Use the current focused element for insertion and check the resulting text before treating delivery as confirmed. Sending a paste shortcut alone no longer counts as confirmed insertion.
- Show the reason and clipboard status when the insertion point is missing, Accessibility permission is unavailable, insertion cannot be confirmed, or automatic sending fails. Show a separate message if clipboard copying fails. Failure notices remain visible for three seconds.

Download the universal DMG or ZIP for Apple Silicon and Intel Macs running macOS 14 or later. Existing installations can update through the launcher notification or Settings → General → Check for updates.

The macOS app uses the existing Prism Local Signing certificate and updater key. It is not Apple notarized; a first installation may require System Settings → Privacy & Security → Open Anyway. Local-signed updates can still require renewed macOS Keychain approval.

No Windows, Linux, or Android public release is included.
