Prism 0.1.11 fixes AI model selection and preserves long conversations with reusable context summaries.

- Fix focus and keyboard navigation in the AI Chat model picker so search and arrow-key selection remain usable.
- Preserve the original conversation beyond 40 messages. Show the latest 60 messages initially, with **Show earlier messages** to expand the full transcript.
- Summarize earlier turns with the selected model when the active context exceeds its budget. Save and reuse the summary across restarts while retaining original messages, screenshots, drafts, and exports.
- Retrieve relevant original excerpts from the current conversation for follow-up questions. Recalculate context when switching models and preserve the correct history when forking a conversation.
- Show summarization progress, support cancellation and explicit retry, and record summary usage separately. Summary requests use the selected provider and may incur additional usage charges.

Download the universal DMG or ZIP for Apple Silicon and Intel Macs running macOS 14 or later. Existing installations can update from the first palette row when available, or Settings → General → Check for updates, then restart Prism.

The macOS app uses the existing Prism Local Signing certificate and updater key. It is not Apple notarized; a first installation may require System Settings → Privacy & Security → Open Anyway. Local-signed updates can still require renewed macOS Keychain approval.

Regression tests cover model-picker interaction, long-history preservation, context compaction, retrieval, persistence, and cancellation. Live provider summary quality and installed-app interaction remain unverified. No Windows, Linux, or Android public release is included.
