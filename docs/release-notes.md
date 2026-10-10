Prism 0.1.14 adds a simple Markdown notes workspace with automatic saving.

- Open Notes or New note from the launcher. Write in a single document beside a searchable note list; the first nonempty line becomes the title.
- Save edits automatically to the local library. Switching notes or closing the editor waits for the latest write, and failed saves keep the draft available for retry.
- Preview Markdown headings, lists, task lists, tables and code blocks without changing the source.
- Find notes by their full contents from launcher search, copy their Markdown, and include them in backup and recovery. Backups containing notes use format version 3; older backups remain supported.

Download the universal DMG or ZIP for Apple Silicon and Intel Macs running macOS 14 or later. Existing installations can use Settings → General → Check for updates. Automatic installation downloads the update in the background when enabled; restart Prism to use the new version.

The macOS app uses the existing Prism Local Signing certificate and updater key. It is not Apple notarized; a first installation may require System Settings → Privacy & Security → Open Anyway. Local-signed updates can still require renewed macOS Keychain approval.

Release validation covers TypeScript, frontend/core and Rust tests, native dictation mocks, the production build, universal macOS packaging, installed-signer compatibility, updater signatures, and artifact checksums. Notes UI and refresh persistence were checked in the Orca browser using isolated preview storage and mocked native IPC. Actual update installation, restart and installed-app interaction require separate runtime verification. No Windows, Linux or Android public release is included.
