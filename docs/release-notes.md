Prism 0.1.16 fixes dictation input targeting inside Prism.

- Keep the search or AI Chat input focused when starting dictation with a shortcut in Prism, so recognized text returns to that input.
- Keep launcher commands targeting the previously active application explicitly.
- Preserve foreground-app targeting when using a dictation shortcut in another application, including accessibility-permission and missing-target handling.

Download the universal DMG or ZIP for Apple Silicon and Intel Macs running macOS 14 or later. Existing installations can use Settings → General → Check for updates, then restart Prism to use the new version.

The app uses the existing Prism Local Signing certificate and updater key. It is not Apple notarized; a first installation may require System Settings → Privacy & Security → Open Anyway. Local-signed updates can still require renewed macOS Keychain approval.

Validation covers TypeScript, frontend/core and Rust tests, native dictation and login-item mocks, the production build, universal macOS packaging, installed-signer compatibility, updater signatures, and artifact checksums. These checks do not prove live dictation, an actual update installation, or permission approval on a user's Mac. No Windows, Linux or Android public release is included.
