Prism 0.1.15 adds Launch at login in Settings → General.

- Enable or disable automatic startup directly in Prism. It starts in the background when you sign in; the palette stays hidden until you open it.
- Read the actual macOS login-item registration instead of storing a separate preference. Refresh the status when returning to Settings so changes made in macOS are reflected.
- Show when approval is needed, with a direct Open Login Items action. Registration failures remain retryable without showing automatic startup as enabled.
- Keep automatic startup opt-in. Development builds and copies outside /Applications/Prism.app cannot register themselves.

Download the universal DMG or ZIP for Apple Silicon and Intel Macs running macOS 14 or later. Existing installations can use Settings → General → Check for updates, then restart Prism to use the new version.

The app uses the existing Prism Local Signing certificate and updater key. It is not Apple notarized; a first installation may require System Settings → Privacy & Security → Open Anyway. Local-signed updates can still require renewed macOS Keychain approval.

Validation covers TypeScript, frontend/core and Rust tests, native service-state tests with mocked registration, native dictation mocks, the production build, universal macOS packaging, installed-signer compatibility, updater signatures, and artifact checksums. The Korean settings UI and approval-state transitions were also checked in the Orca embedded browser using mocked native IPC. These checks do not prove an actual logout/login, update installation, or permission approval on a user's Mac. No Windows, Linux or Android public release is included.
