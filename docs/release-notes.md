Prism 0.1.13 adds automatic web search and image attachments to AI chat, and restores Finder in application search.

- Let supported AI models use web search when needed without a separate search toggle. Local file access still requires explicit permission. Actual searches may incur provider usage charges.
- Drop a PNG, JPEG, or WebP image into AI chat. Preview or remove the attachment before sending; preserve it with drafts and conversation history. Known text-only models reject image attachments.
- Include Finder in the native application catalog so it can be found and opened from the palette.

Download the universal DMG or ZIP for Apple Silicon and Intel Macs running macOS 14 or later. Existing installations can use Settings → General → Check for updates. Automatic installation downloads the update in the background when enabled; restart Prism to use the new version.

The macOS app uses the existing Prism Local Signing certificate and updater key. It is not Apple notarized; a first installation may require System Settings → Privacy & Security → Open Anyway. Local-signed updates can still require renewed macOS Keychain approval.

Release validation covers TypeScript, frontend/core and Rust tests, native dictation mocks, the production build, universal macOS packaging, installed-signer compatibility, updater signatures, and artifact checksums. Actual installed-app image drops, paid provider responses, and update installation/restart require separate runtime verification. No Windows, Linux, or Android public release is included.
