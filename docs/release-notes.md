Prism 0.1.10 adds screen capture conversations, custom AI connections, and faster settings access.

- Add **Capture and Ask AI**: select a rectangular screen region on macOS and open a new conversation with the image attached. Assign a shortcut from the command actions or Settings. Images are sent only when you submit a question; choose a model that supports image input.
- Add a capture button inside AI Chat. Retain images in drafts, retries, follow-up questions, edited conversations, and Markdown exports. Preserve a pending captured draft when saving the previous conversation fails.
- Add OpenAI-compatible connections with a custom API base URL, optional Keychain-stored key, and manual model ID. Model discovery is optional; provider keys remain isolated by server address.
- Search individual settings and jump directly to the matching control. Edit command aliases and shortcuts from the launcher action panel.
- Open full AI Chat with an unsent search query using Tab, and return to the original query with Escape.
- Keep native glass and tint synchronized during window transitions to address flicker.

Raycast extension compatibility, an extension store, a public SDK, agents, AI-controlled settings, and freeform lasso selection are not included.

Download the universal DMG or ZIP for Apple Silicon and Intel Macs running macOS 14 or later. Existing installations can update from the first palette row when available, or Settings → General → Check for updates, then restart Prism.

The macOS app uses the existing Prism Local Signing certificate and updater key. It is not Apple notarized; a first installation may require System Settings → Privacy & Security → Open Anyway. Local-signed updates can still require renewed macOS Keychain approval. Screen capture requires the relevant macOS Screen Recording permission.

Automated tests and a sample-image Orca preview cover attachment handling. Native region selection, permission prompts, and live vision inference remain unverified. No Windows, Linux, or Android public release is included.
