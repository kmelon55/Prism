Prism 0.1.7 fixes the dictation paste regression, preserves recoverable results, and puts available updates first in the command palette.

- Restore paste delivery to Orca and other applications that do not expose an Accessibility text element. Use the target application's paste handler and distinguish unobservable input from confirmed insertion.
- Save original and processed dictation text on this Mac before delivery. Keep failed recordings, including microphone interruptions and recording-limit failures, in Settings → Dictation → Open recovery folder. The last saved result remains available after restarting Prism.
- Include completed dictation in enabled clipboard history without depending on clipboard polling. Existing history privacy filters and storage limits still apply.
- Show available updates as the first command-palette result above favorites. Press Enter to install; the same row shows progress, retry, or an explicit restart action. Installation does not restart Prism automatically.

Recovery begins with this version; it cannot restore recordings or results deleted by earlier versions. Recovery files remain on this Mac until deleted from the recovery folder. Explicitly canceling an unfinished recording discards that take.

Download the universal DMG or ZIP for Apple Silicon and Intel Macs running macOS 14 or later. Existing installations can update through their launcher notification or Settings → General → Check for updates. The new first-row update experience takes effect after installing this version.

The macOS app uses the existing Prism Local Signing certificate and updater key. It is not Apple notarized; a first installation may require System Settings → Privacy & Security → Open Anyway. Local-signed updates can still require renewed macOS Keychain approval.

No Windows, Linux, or Android public release is included.
