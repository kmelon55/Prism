# Clipboard workflow improvements

## Behavior

- Clipboard settings expose the existing command shortcut and its conflict checks. A disabled command can be enabled there.
- The clipboard hotkey prepares the clipboard view before revealing the native palette window. Numbered requests reject stale or duplicate acknowledgements; startup replays a pending request. The external paste target is captured before preparing the view.
- Return and double-click paste into the previous app by default. Cmd+Return copies. Choosing Copy as the Return action reverses those actions. Saved preferences load before enabling history actions. Existing native target and clipboard revision checks remain in force.
- Capture can pause for 5, 15, or 60 minutes and resume early. Existing entries and pins remain available. Expiry persists across restarts.
- Excluded applications are selected from installed applications and stored by bundle identifier. The monitor skips changes observed while an excluded app is frontmost, before reading the payload. This is a frontmost-app observation rule, not guaranteed clipboard source attribution. Changes during a pause or privacy-setting transition are baselined instead of imported later.

## Storage and performance

`clipboard_preferences` stores the primary action, pause expiry, and excluded applications. The settings response includes them. Native mutation commands are `set_clipboard_primary_action`, `set_clipboard_capture_pause`, `add_clipboard_excluded_application`, and `remove_clipboard_excluded_application`.

Search no longer runs pruning transactions. Expired unpinned entries are filtered in the read query, ordered indexes support recent and type-filtered reads, and Unicode substring matching remains unchanged. Blocking search workers are bounded to two; each frontend window serializes requests and skips superseded waiting work. Non-empty typing is debounced by 60 ms; initial history opens immediately.

Settings are loaded on demand. The main production JS chunk changed from 816.82 kB to 702.65 kB (gzip 250.77 to 219.81 kB). This is a bundle-size comparison, not a startup timing measurement. Vite still reports a chunk over 500 kB.

## Microphone error overlay

The error timeout hid the panel while leaving the controller in its error phase. A later language synchronization called `show()` for any non-idle phase, reviving the expired toast without a timer. The controller now tracks overlay visibility separately and only refreshes a visible overlay. Hiding also removes the SwiftUI root so hidden TimelineViews are released. Regression fixtures cover expiry, subsequent language changes, and protecting a new recording from an older timeout.

## Validation (2026-09-15)

- `pnpm test`: 609 desktop and 36 command-core tests passed.
- `cargo test --manifest-path apps/desktop/src-tauri/Cargo.toml --lib`: 260 passed, 6 ignored.
- `sh scripts/test-dictation-native.sh`: passed isolated native fixtures; no real microphone capture or external insertion.
- `pnpm build`: TypeScript and Vite passed; chunk warning remains.
- `git diff --check`: passed.
- Orca loaded the actual settings components in a standalone file fixture with mocked Tauri IPC. Return selection, exclusion add/remove controls, pause, and retained history counts were inspected. Recorded IPC confirms Copy, app exclusion, and five-minute pause mutations; no page errors or horizontal overflow. The final screenshot refresh timed out on a non-visible tab; the earlier verified screenshot is retained. The temporary tab was closed.

Synthetic debug SQLite timing uses 1,000 approximately 1 KiB text entries, five warmups, and 100 samples per query:

| Query | p50 (ms) | p95 (ms) | max (ms) |
| --- | ---: | ---: | ---: |
| Empty | 0.171 | 0.405 | 1.661 |
| MixedCase | 0.138 | 0.761 | 3.310 |
| Korean substring | 0.141 | 0.565 | 2.072 |
| No match | 4.380 | 6.480 | 8.213 |

Run with `cargo test --manifest-path apps/desktop/src-tauri/Cargo.toml synthetic_clipboard_search_timing -- --ignored --nocapture`. These are in-memory debug search timings, excluding IPC and painting; they are not a production performance gate or a before/after latency comparison.

The installed application was not replaced or restarted. Real macOS hotkey-to-visible timing, previous-app insertion, microphone capture, native overlay rendering, and whole-process idle/cold-start performance remain unverified on this revision. No commit, push, release, or installation was performed.
