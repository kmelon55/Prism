# Desktop foundations implementation

Updated: 2026-09-09. Worktree: `/Users/kimgyeongmo/Documents/Prism`.

This slice improves local launcher foundations and adds a visual emoji picker. It does not establish full Raycast/Asyar/SuperCmd parity or close the packaged-native quality gates.

## Resulting behavior

- Search shares Korean application aliases, Hangul normalization and initial-consonant matching between native retrieval and command ranking. Exact intent answers and selected identities survive delayed provider results.
- File search persists a bounded catalog, watches configured roots incrementally, preserves fast local results, and offers **Search more broadly** with the original query retained. Token and subsequence matching inspect each filename once per query; rank bookkeeping uses at most one byte per bounded catalog row.
- Search **emoji** or **이모지** to open an offline visual grid. Korean/English names, categories, skin tones, keyboard navigation and bounded recents cover 3,781 Unicode sequences. Clicking copies the exact sequence; the macOS picker also offers paste into the captured original app, with explicit retry or copy fallback. Emoji data and picker code load lazily.
- Opt-in clipboard history retains text, supported image originals and local file references. The view offers type filters and selected-image thumbnails. File availability is unknown in search and checked at action time. Originals, pins, retention and explicit deletion remain bounded and local.
- Script identities, run state and bounded output survive renderer reloads and native restarts. Interrupted runs require an explicit rerun, password-bearing scripts omit durable output, and retrying a failed checkpoint never executes the script again. Metadata can set a 1–3,600 second timeout.
- Backup v2 retains optional snippet keywords and separately reviewed path references, while importing v1 remains supported. Safe preference snapshots and explicit recovery preserve malformed original settings instead of silently resetting them.
- Local date arithmetic, date differences and explicit time-zone conversions provide exact copy values. Invalid dates and ambiguous/nonexistent local times report errors.
- Snippet keywords are unique, validated, backed up and searchable for manual copy/paste. **Automatic expansion is unavailable in this build**: native review identified a select-then-write race with concurrent typing. Startup ignores saved opt-ins, creates no input-monitoring thread, rejects activation and does not request permissions. The prototype stays gated until its input-safety design and native acceptance checks are complete.

## Verification and limits

The existing Vite process (PID 99669, `127.0.0.1:1420`) was preserved throughout. Verification used a separate Orca browser tab, fixture-only tests and build commands. No native app or development server was manually started, stopped or restarted. No commit, push, pull request, deployment or publication was performed.

| Evidence | Result | Artifact |
| --- | --- | --- |
| Frontend/core tests | 444 passed: 408 desktop and 36 command-core | [Test output](evidence/foundations-2026-09-09/frontend-tests.txt) |
| TypeScript | Passed | [Typecheck output](evidence/foundations-2026-09-09/typecheck.txt) |
| Production web build | Passed; Vite reports large chunks (main about 529 kB, lazy emoji catalog about 1,176 kB before gzip) | [Build output](evidence/foundations-2026-09-09/web-build.txt) |
| Native Rust unit/fixture tests | 187 passed; four opt-in network/Keychain/performance tests remain ignored in the ordinary suite | [Native test output](evidence/foundations-2026-09-09/native-tests.txt) |
| Final mounted App regression check | 56 passed after the clipboard layout integration fix | [App test output](evidence/foundations-2026-09-09/app-integration-tests.txt) |
| Existing browser | Root-to-picker navigation, rendered grid, Korean heart search and usable layout observed | [Emoji screenshot](evidence/foundations-2026-09-09/emoji-browser.png) |

Mounted tests additionally verify emoji native copy dispatch, failed paste with exact copy fallback, broader file search query/scope retention, local date copy, malformed settings preservation, image filter/thumbnail wiring, and existing currency/language flows. Browser/native IPC mocks do not prove actual clipboard insertion into another app.

Packaged native paste, image/file pasteboard compatibility, real Korean IME, app restart recovery, picker dialogs, focus/permissions and the release performance budgets in [quality-gates.md](quality-gates.md) remain unverified. The visual capture uses the browser preview in English, dark appearance and default text scale. It does not establish native transparency, launch flicker or native window performance.

## Supporting contracts

[Search](search-foundations.md), [file index](file-index-foundations.md), [emoji](emoji-picker.md), [rich clipboard](rich-clipboard.md), [scripts](script-durability.md), [backup](backup-foundations.md), [date/time](date-time-calculation.md), and [gated snippet prototype](snippet-expansion.md) document individual contracts. Their worker validation notes are historical; this report records integrated validation.

## Integration fixes

The integrated checks caught and corrected an emoji picker constrained to the root search-header grid row, currency overview styling affected by the supplemental file action, missing image MIME metadata, and cross-window preference persistence that had stopped updating locale storage. The Rust file fixtures now use unique monotonic suffixes to avoid parallel timestamp collisions. The script timeout fixture allows three seconds of startup headroom under parallel macOS execution while retaining timeout enforcement and exact live/recovered output assertions; the production default remains ten seconds.

Final native review also removed mounted-volume metadata checks from clipboard search and added a pasteboard revision check immediately before posting paste. Automatic snippet expansion remains gated because a listen-only event tap cannot serialize the AX selection/write sequence with concurrent target input. No native quality gate is marked passed merely because those guards compile or unit tests pass.

Source identity: `982500ed2daeea8321c476cc7b99ad12a8d80de61d88ef3e01d1c367db59af54`. The [source manifest](evidence/foundations-2026-09-09/source-manifest.json) includes source, test and build configuration files, and excludes dependencies, generated output, docs, secrets and caches. The earlier full frontend run plus the final mounted App run and build cover the final frontend changes.

## Synthetic file query timing

The explicitly invoked debug-build test measures 100,000 in-memory filename rows, five samples per query, with no filesystem, watcher, IPC or rendering work. Raw median/max values are retained in [file-query-timing.txt](evidence/foundations-2026-09-09/file-query-timing.txt). It passed independently after the ordinary native suite. This is a query-cost diagnostic, not a release p95 measurement or a pass for the painted-result budget.
