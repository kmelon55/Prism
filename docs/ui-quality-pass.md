# Desktop quality pass — 2026-09-09

Prism now has a consistent palette/settings presentation and complete daily workflows for durable text clipboard history, file previews, parameterized quicklinks, snippet variables, and observable script execution. This is a bounded implementation pass, not Raycast/Asyar feature parity.

## Presentation and architecture

- Add shared dark/light surface tokens, subtle borders and shadows, clearer selected rows, recognizable file glyphs, and direct Settings access. Settings navigation separates Preferences, Tools and Privacy.
- Keep root application and built-in command rows to an icon and name. Do not display application paths or restore every provider subtitle globally. File results show short parent-folder context, saved links show the host, and snippets retain their content preview. Preserve full targets for search, copying and execution. Keep the primary action and a labelled Actions shortcut in the bottom bar; Settings uses a gear with a tooltip.
- Rank root file results below applications and commands, including when merging cached or partial results. Debounce file discovery for 300 ms and cancel superseded lookups. For a nonempty query, preserve the visible selected item by ID as asynchronous results arrive; a query edit chooses the best match again. Late file results must not redirect Enter from Clipboard History to a file.
- Extract the live SettingsView and remove its unused legacy predecessor. Share its typed preferences with App. Split file browsing, entry editing, parameter execution, clipboard settings and script sessions into focused modules.
- Search settings in English or Korean, prioritize exact section names over incidental command matches, preserve explicit navigation, and support keyboard controls and composition guards.
- Load AI Chat on first entry and keep it mounted after that entry to preserve its state. Production entry JS is 461.82 kB (140.14 kB gzip); AI Chat is a separate 311.74 kB chunk. The prior entry was approximately 741 kB. This is an artifact-size comparison, not a measured startup-latency claim.
- Keep the existing native render-readiness gate and hidden-WebView fallback. Match native settings backgrounds to the revised theme and enable the main window shadow. Actual white-flash elimination remains a native interaction check.
- Follow composable control/navigation ideas from shadcn without adding Tailwind or replacing Prism's existing keyboard infrastructure. This avoids a second component foundation for the same surfaces.

## Daily workflows

| Area | Implemented behavior | Deliberate limit |
| --- | --- | --- |
| Clipboard | Opt-in SQLite history survives restart; 1/7/30/90-day retention; pin/unpin; full-text Save as Snippet; explicit clear/disable confirmation and operation-specific retry. | Text only; 1,000 entries and 128 KiB per entry. Pinned rows do not expire. Disable and clear delete pins too. Local storage is not encrypted. |
| Clipboard privacy | Check macOS private, concealed, transient and password-manager pasteboard markers before capture; reject torn reads and obvious secrets. | Unmarked sensitive text can still be captured. The 650 ms poll can miss fast changes. |
| Files | Filter by type, keep matching rows during refresh, navigate with arrows, inspect metadata/text and bounded PNG/JPEG/WebP previews, then open/reveal/copy. | Filename search uses existing Spotlight and optional folder indexes. No content indexing, PDF rendering or unrestricted file access. |
| Quicklinks | A URL query containing `{query}` opens an argument form and resolved preview. | HTTP(S) query placeholders only; no arbitrary URL interpolation. |
| Snippets | Expand `{date}`, `{time}`, `{clipboard}` on explicit action, with a preview before copy/paste. | No global abbreviation expansion or keyboard hook. |
| Entry execution | A single-use native token executes the reviewed snapshot and rejects changed entries, stale previews and invalid targets. | Preview must be refreshed after expiry or execution error. |
| Scripts | Up to three validated text/password/dropdown arguments; zero-argument Enter executes once; bounded live stdout/stderr; explicit cancel/retry; result survives leaving the panel. | 10-second timeout, 64 KiB per output stream, four concurrent native runs. Full renderer reload loses the frontend run association. No scheduler or complete Raycast metadata compatibility. |

## Verification

- Workspace type checking passes. Production build passes without the former large-entry-chunk warning.
- Workspace tests: 23 command-core tests plus 219 desktop tests. The final settings/App focused check passes 56 tests after exact-name search and compact script routing changes.
- Native library tests: 125 passed, 3 intentionally ignored. Disposable fixtures cover persistence/restart, retention/pins, failed writes, opaque file IDs, special-file rejection, safe decoding, one-use execution, literal argv, cancellation, timeout and bounded output.
- Browser review uses self-contained `file://` bundles in Orca, built from the actual components with isolated in-memory native IPC. It covers dark/light settings, Korean search, file selection/preview updates without execution, and one explicit script start with visible output. It does not use the user's clipboard, folders, scripts or API keys.
- No development server or user application was started, stopped or restarted. The pre-existing localhost preview tab was preserved. No commit, push, publication or deployment occurred.
- Packaged native first-open/reopen flicker, Spaces/multi-monitor placement, real macOS IME, paste target behavior and actual permission dialogs remain unverified. These must be measured before claiming the launcher quality baseline is complete.

## Reviewed screens

These are browser fixtures of the actual implementation, not native application screenshots. File names, paths, script results and settings counts are fixture data.

- [Dark settings](screenshots/2026-09-09/settings-dark.png)
- [Light settings](screenshots/2026-09-09/settings-light.png)
- [File browser](screenshots/2026-09-09/files.png)
- [Script result](screenshots/2026-09-09/script.png)

## Next priorities

1. Measure packaged cold/warm opening, first Settings opening, focus restoration, multi-monitor placement and idle resource use against the existing [quality gates](quality-gates.md). Fix measured failures before adding more broad surfaces.
2. Add versioned settings/library export and previewed import with validation and failed-write recovery.
3. Add searchable Korean/English emoji and deepen indexing refresh behavior.
4. Expand clipboard formats and AI concurrency/attachments as separate, validated slices. Retain the existing local consent and data ownership boundaries.

## References

- [shadcn composition](https://ui.shadcn.com/docs) and [Sidebar](https://ui.shadcn.com/docs/components/sidebar).
- [Raycast Clipboard History](https://manual.raycast.com/clipboard-history) and [Clipboard API](https://developers.raycast.com/api-reference/clipboard).
- [Raycast script arguments](https://github.com/raycast/script-commands/blob/master/documentation/ARGUMENTS.md).
- [Raycast rendering architecture](https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast).
- Existing [repository research](research.md) records Asyar and other references. Behavioral ideas were independently implemented; no incompatible external implementation was copied.
