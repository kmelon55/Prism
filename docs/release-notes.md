Prism 0.1.17 adds downloadable local speech recognition models in Settings → Dictation.

- Choose Whisper Large v3, Large v3 Turbo, Turbo Q5, Small, or Medium from a model list with download sizes and installed status.
- Download, verify, and select models without entering file paths. Follow download progress, cancel a download, or retry after a failure. Downloads continue when the picker closes; reopen it to select the completed model.
- Detect an existing whisper-cli engine or explicitly install whisper.cpp and its dependencies through an existing Homebrew installation. Advanced settings still accept existing model and executable files.
- Keep the current configuration when downloading fails, recording starts, or local file selections change while a download is running. Merely browsing the model list does not download models or install software.

Local recognition does not upload audio or charge an STT API fee. Separately enabled AI text enhancements still use their configured provider. Model download sizes are not runtime memory requirements; performance and memory use depend on the model and Mac. This release does not add automatic memory-pressure protection or establish speed/accuracy parity with cloud transcription.

Download the universal DMG or ZIP for Apple Silicon and Intel Macs running macOS 14 or later. Existing installations can use Settings → General → Check for updates, then restart Prism to use the new version.

The app uses the existing Prism Local Signing certificate and updater key. It is not Apple notarized; a first installation may require System Settings → Privacy & Security → Open Anyway. Local-signed updates can still require renewed macOS Keychain approval.

Validation covers TypeScript, frontend/core and Rust tests, native dictation and login-item mocks, the production build, universal macOS packaging, installed-signer compatibility, updater signatures, and artifact checksums. These checks do not prove a real model download, Homebrew installation, live dictation, an actual update installation, or permission approval on a user's Mac. No Windows, Linux or Android public release is included.
