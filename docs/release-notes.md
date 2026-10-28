Prism 0.1.19 makes model selection easier to read and scroll in chat, AI settings, and dictation.

- Replace cramped model popovers with a larger centered dialog. Keep search and column headings visible while browsing the model list.
- Prevent scrolling at list boundaries from moving the settings page behind the dialog. Use a single scrolling area for speech models.
- Separate model names, IDs, input prices, and output prices. Sort text models by name or price, with unavailable prices listed last.
- Add five-segment price indicators and dated reference throughput for three Vercel models. Reference speed is provider-specific public data from October 28, 2026, not measured Prism latency. Unknown values remain unavailable rather than receiving an estimated score.
- Preserve model selection, failed-save recovery, keyboard navigation, focus restoration, and light/dark themes.

Download the universal DMG or ZIP for Apple Silicon and Intel Macs running macOS 14 or later. Existing installations can use Settings → General → Check for updates, then restart Prism to use the new version.

The app uses the existing Prism Local Signing certificate and updater key. It is not Apple notarized; a first installation may require System Settings → Privacy & Security → Open Anyway. Local-signed updates can still require renewed macOS Keychain approval.

Validation covers TypeScript, frontend/core and Rust tests, native dictation and login-item mocks, the production build, universal macOS packaging, installed-signer compatibility, updater signatures, and artifact checksums. Browser previews exercise the actual UI components with test IPC and public catalog data, including scroll containment in a 760 × 500 viewport. These checks do not establish native WebView behavior, live inference performance, update installation, or macOS permission behavior. No Windows, Linux or Android public release is included.
