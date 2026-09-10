# Desktop workflow improvements

Implemented on 2026-09-09 in the existing Prism checkout. Three Orca worker sessions owned file
search, local backup, and AI/script lifecycle respectively; the coordinator owned shared registration,
App integration, localization and final validation. All three tasks completed and worker terminals were
released. No extra checkout, commit, push, publication or deployment was created.

## Delivered behavior

| Area | Change | Deliberate boundary |
| --- | --- | --- |
| File search | Return cached filename results immediately, pre-normalize/sort once during refresh, discover the home folder, reuse unchanged directories, reject stale generations and refresh the root query after index events. Direct Files hides folder management behind a disclosure. | Matching still scans cached rows. No persistent snapshot or filesystem event watcher. Focused Files refreshes every five seconds; bounded Spotlight runs only on indexed misses. |
| Backup | Add searchable Settings → Backup & Restore. Export snippets, HTTP(S) quicklinks and favorites; review additions/conflicts/skips before a single-use atomic library import. Offer appearance/language/aliases as a separate explicit restore. | Existing records win; path entries, keys, histories, grants, scripts and hotkeys are excluded. Preferences and SQLite are independent stores. Actual native chooser interaction remains unverified. |
| AI conversations | Allow up to three concurrent replies with independent streaming, errors, target-only cancellation and serialized history. Switching or drafting elsewhere preserves the originating reply. | Stop a running reply before deleting that conversation. Renderer reload cancels requests; partial streams are not durable completed answers. |
| Scripts | Discover native run snapshots after renderer reload, resume observation and show retained output. Require explicit Run again to repeat execution; keep stable registered script identities. | Recovery lasts for the native process lifetime and a bounded registry. Existing four-script concurrency, ten-second timeout and 64 KiB per output stream remain. |

Shared glue registers native backup state/commands and script discovery, subscribes the root query to
file-index changes, persists restored settings before changing local state, and adds 51 missing Korean
translations. Baseline source copies were used to review changes because the checkout was initially
entirely untracked; unrelated existing files were preserved.

## Validation

| Check | Result | Proof boundary |
| --- | --- | --- |
| `pnpm test` | 264 desktop + 23 command-core tests passed, 287 total | Mounted React/logic tests with mocked native IPC |
| `pnpm typecheck` | Passed | TypeScript |
| `pnpm build` | Passed | Production web assets; main JS 481.07 kB, separate AI chunk 312.95 kB, uncompressed |
| `cargo test --manifest-path apps/desktop/src-tauri/Cargo.toml --lib` | 145 passed, 3 explicitly ignored | Native logic, isolated SQLite/files/scripts; no paid inference |
| Final backup native rerun | All 12 passed after the final Korean-alias and file-bound assertions | Transaction rollback, single-use/stale tokens, conflicts and bounded file operations |
| Final backup/settings frontend rerun | All 22 passed | Reviewed import and operation-specific retry |
| Browser fixtures | Files, backup review and restored script output inspected; AI background completion preserved another draft | Actual components with isolated fake IPC/data; not native app/provider proof |

The browser AI scenario started a first reply, opened a second conversation, typed a second draft and
completed the first reply. The second textarea remained enabled and unchanged, the first completed
turn was persisted to the fixture history, and its response did not leak into the second conversation.
Backup review invoked no apply before confirmation; applying library additions invoked apply once
and did not restore preferences. Script opening invoked only discovery and displayed existing output,
with zero script starts. Evidence is in [fixture observations](screenshots/2026-09-09/workflows/fixture-evidence.json).

Screenshots: [Files](screenshots/2026-09-09/workflows/files.png),
[Backup review in Settings](screenshots/2026-09-09/workflows/backup-review.png),
[Recovered script output](screenshots/2026-09-09/workflows/script-recovery.png).
The temporary fixture tab was closed; the user's existing browser tab was preserved.

The existing Vite process (PID 99669) remained present throughout. No server or native application was
manually started, restarted or stopped. The user's existing Tauri watcher can react to source changes
and automatically rebuild/relaunch; no claim is made that its native process identity stayed fixed.

## Remaining depth and measurement

Real macOS IME, focus/paste targets, native chooser/export/import, multiwindow preferences, packaged
launch latency, search latency, memory/energy and live AI remain unverified. This does not establish
Raycast/Asyar feature parity or pass the native performance gates. Persistent indexing, rich clipboard
formats, global snippet abbreviations, image/PDF chat input and wider extension compatibility remain
separate product gaps; see [current audit](basic-feature-audit.md).

A passive observer is available without controlling the app:

```sh
node scripts/measure-desktop-idle.mjs --pid <existing-pid> --seconds 60 --output /tmp/prism-idle.json
```

It observes CPU-time deltas and RSS for the given existing process and its current descendants, aborts
if the process disappears, and never overwrites an output file. Its parser/observer was smoke-tested
against an existing shell process. This is measurement preparation, not a Prism idle benchmark: RSS
is not physical footprint, external WebKit/XPC helpers and short-lived processes can be missed, and
build identity, visibility and idle conditions must be recorded separately.

Detailed contracts: [file search](file-search-improvements.md), [backup](backup-recovery.md),
[AI/script lifecycle](run-lifecycle-improvements.md). Earlier worker reports record their own checks;
the integrated results above supersede their pending coordinator steps.
