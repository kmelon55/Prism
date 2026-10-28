Prism 0.1.18 fixes recognition hints and custom vocabulary for local Whisper dictation.

- Pass recognition hints to whisper-cli with `--prompt`. Previously, Prism used `-p`, which selects a processor count and can cause transcription to fail when a hint or vocabulary is present.
- Preserve multilingual examples, line breaks, and preferred vocabulary spellings in the prompt passed to the local engine.
- Keep existing model, language, and optional AI text enhancement settings. Recognition hints guide the model but do not guarantee mixed-language accuracy.

Download the universal DMG or ZIP for Apple Silicon and Intel Macs running macOS 14 or later. Existing installations can use Settings → General → Check for updates, then restart Prism to use the new version.

The app uses the existing Prism Local Signing certificate and updater key. It is not Apple notarized; a first installation may require System Settings → Privacy & Security → Open Anyway. Local-signed updates can still require renewed macOS Keychain approval.

Validation covers TypeScript, frontend/core and Rust tests, native dictation and login-item mocks, the production build, universal macOS packaging, installed-signer compatibility, updater signatures, and artifact checksums. The new subprocess regression test checks multilingual hint and vocabulary delivery without running a speech model. These checks do not establish real speech accuracy, live AI post-processing quality or latency, update installation, or macOS permission behavior. No Windows, Linux or Android public release is included.
