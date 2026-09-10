# Desktop basics audit

Updated: 2026-09-09. This records implemented workflows and remaining gaps. Implementation and
fixture verification do not establish native interaction or live provider compatibility.

See the [workflow improvements](desktop-workflow-improvements.md) for cached search, reviewed backups, concurrent chat and script recovery, and the [desktop quality pass](ui-quality-pass.md) for presentation, clipboard and preview evidence.

## Implemented in the follow-up

Language selection and AI file activation are covered in the later [language and search follow-up](language-and-search.md).

| Workflow | Current behavior |
| --- | --- |
| Clipboard | Durable opt-in text history; retention, pins, full-text save as snippet, explicit clear/disable, copy and target-checked paste. |
| Working files | Query a cached automatic home-folder index and optional folders immediately; use bounded Spotlight fallback on indexed misses. Refresh incrementally while Files is active. Filter types, preview metadata/text/images, navigate with the keyboard, open, reveal, copy path and page results. |
| Favorites | Pin supported commands, applications and saved entries from their action menu; persist ordering and manage it in Library. Exact search matches keep precedence. |
| Saved destinations | Open Quicklinks directly from the palette; create, edit, search and delete named HTTP(S), file and folder links; preview `{query}` quicklink arguments. |
| Reusable text | Create, edit, search, copy and paste snippets; retain failed edits and confirm unsaved changes; preview `{date}`, `{time}` and `{clipboard}` expansion. |
| AI streaming | Stream visible text over a request-scoped native channel; reconstruct provider tool calls and reasoning; reject incomplete transports. |
| Question editing | Preserve the source conversation and create a new conversation from the selected question; regeneration sends only after an explicit action. |
| Backup and recovery | Export/review snippets, HTTP(S) quicklinks and favorites; import additions atomically with existing entries preserved. Restore allowlisted appearance, language and aliases separately. |
| Concurrent work | Run up to three AI replies with conversation-owned state and targeted cancellation. Recover script snapshots after renderer reload without rerunning. |
| Chat organization | Rename, pin and export Markdown; copy individual code blocks. Metadata acknowledges durable writes. |

The earlier follow-up also repaired deletion/retry, numbered conversation switching, message-body
search, composer growth, reading-position preservation, and removed persistent key hints.
See [local library](local-library.md) and [AI chat](ai-chat.md) for behavior and verification limits.

## Remaining work

| Priority | Workflow | Missing depth |
| --- | --- | --- |
| 2 | Attachments | Image and PDF input; current messages and permitted-folder tools support text. |
| 3 | Symbols | Searchable Korean/English emoji picker. |
| 3 | Scripts | Broader metadata/output-mode compatibility and recovery beyond native process lifetime. Arguments, output/error panel and cancellation now exist. |
| 3 | AI tool activity | Per-tool progress beyond the current pending state and final source attribution. |
| 3 | File indexing | Persistent snapshots, filesystem event watching, content search and wider OS coverage. Current index uses directory-mtime reuse, bounded scans and focus-aware active-view refresh; query matching still scans cached rows. |

Daily reference currency and unit conversions already exist. Rich clipboard formats, date/time-zone
calculations, global snippet abbreviation expansion and cloud synchronization remain separate improvements.
Real macOS IME, focus restoration, native file/save dialogs, paste targets and multi-monitor behavior
still require interaction verification even where implementation and unit tests pass.
