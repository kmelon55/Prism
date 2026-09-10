# Durable file search foundations

Files now serves a bounded local filename catalog, restores a validated disk snapshot after restart, and reconciles filesystem events instead of rescanning on a timer. A separate, explicit broader search merges bounded macOS Spotlight results with local matches, including when the local index already has results.

## Persistence and root authority

- Cache: Tauri application cache directory, `file-index-v1.json`; schema version 1, maximum 32 MiB on both read and write. Writes use a private temporary file, flush and sync before rename; Unix cache files use mode `0600`. A failed write keeps the in-memory index usable.
- Cached listings carry the exact sorted root IDs and canonical paths plus filesystem identities (device/inode on Unix; creation identity elsewhere). A removed, renamed, replaced, or newly configured root invalidates the entire disk snapshot. Unknown versions, malformed JSON, oversized files, duplicate directory keys, malformed source IDs, and paths outside their recorded root are rejected.
- The cache contains filenames and paths, not file contents or persisted opaque execution tokens. Loading checks exclusions, parent/name relationships, path size, depth, and row bounds. It does not claim cached files still exist.
- `invalidate_file_index(app, state)` must run under the library mutation lock whenever configured roots change. Root add/remove already use it. It increments the generation, hides old rows, drops the old watcher, and removes the cache; the same lock fences disk publication so an old worker cannot recreate a revoked snapshot.
- Startup publishes a matching cached snapshot before performing one bounded reconciliation, accounting for changes while Prism was closed. Cache failures trigger a fresh initial scan. Normal queries perform no disk traversal.
- Existing opaque ID issuance, current-root lookup, path-component/symlink checks, and descriptor-based preview/execution remain authoritative. A cached or Spotlight path never grants access by itself.

## Event refresh and resource bounds

`notify` starts lazily on the first file-search demand and remains active for the current roots. Its callback rejects excluded paths before storing them or waking a worker. Exclusions include hidden components, dependency/build/cache directories (`node_modules`, `target`, `dist`, `build`, `Library`, `vendor`, `venv`, `__pycache__`, `Pods`), and application-bundle contents. Explicitly configured roots retain their own scope, even when a parent automatic root excludes that subtree.

A single-slot wake channel and a maximum of 512 pending paths bound event bursts. Events debounce for 250 ms of quiet with a hard one-second maximum; continuous writes cannot postpone reconciliation indefinitely. Overflow or a native lost-event signal requests a bounded recovery scan. It is event-driven, not periodic. Healthy roots remain watched when another root cannot be registered; the response exposes a warning and manual refresh retries watcher registration.

Only one disk worker runs at a time. Events arriving during a scan coalesce into the next batch. For ordinary changes, the index rereads affected parent listings and discovers newly created subtrees; unchanged directories reuse their listings without a metadata read. Directory removal/rename invalidates descendants, including replacement with the same name. Ordering is rebuilt in memory after each batch. Initial, explicit, and overflow scans remain capped at 100,000 entries, depth 16, and a five-second traversal budget. Partial catalogs retain their `limited` indication; an incremental event cannot prove that a previously capped scan was complete.

The Files hook subscribes to index events, catches up once the asynchronous subscription is installed, and refreshes on focus/visibility restoration. It does not poll. Events received while hidden, unfocused, or after unmount do not trigger a query. Closing Files releases the frontend listener; there are no idle full rescans in the backend.

## Matching and broader search

Names and queries use NFKC normalization and lowercase folding, including decomposed Korean filenames. Stable rank buckets are exact name, whole-query prefix, whole-query substring, all whitespace tokens, then bounded subsequence. Queries allow up to eight tokens and 512 bytes; subsequence tokens require 3–64 characters, inspect at most 1,024 filename characters, and cap their matching span. Short fuzzy tokens do not turn most filenames into matches. Each rank uses normalized filename then path order, so pagination is deterministic for a fixed snapshot. File-type filtering happens before totals and pagination. Rank matching runs once per file; a bounded one-byte-per-row scratch vector avoids repeating Unicode/token work across five rank buckets. Results retain the same stable ordering and exact totals.

`library_search_files(includeSystem: true)` always permits supplemental search for a nonempty query. It merges by path, applies the same local matcher/filter, sorts the union, and then paginates. Local IDs win duplicate paths. Spotlight keeps its existing 200 ms subprocess limit, bounded output/hit processing, and authoritative action validation; broader results are marked limited. Spotlight still has its own filename retrieval semantics, so fuzzy local matching does not imply exhaustive fuzzy system retrieval. On platforms without Spotlight, broader search currently has no additional source.

Files exposes a scope button even when local matches exist. Switching scope keeps the last page visible while the request is pending and disables actions on that stale page. A changed query or file type resets the broader scope; stale broader responses cannot overwrite a newer local request. Root changes clear rows and preview immediately through the existing roots key.

The root file provider returns local results immediately and a supplemental action:

```text
item.id = files:search-broader
item.actions[0].id = files-search-broader
item.data.query = trimmed query
```

The provider does not automatically wait for a system fallback after a local miss.

## Integration contract

The coordinator owns these shared integration points:

1. Handle `files-search-broader` in `App.tsx`, open Files with the supplied query, and pass `initialIncludeSystem: true` through `LibraryPanel` to `FileBrowser`. The coordinator reports this navigation and prop plumbing integrated; `FileBrowser` accepts the optional prop and the existing controlled `query`.
2. Treat the supplemental action appropriately in palette default selection so an early file-provider response does not capture selection ahead of delayed intent results.
3. Route root-changing imports through `invalidate_file_index` while holding the library mutation lock. An import that only changes entries/favorites does not need to invalidate file roots.
4. Add shared bilingual strings for the scope button, scope description, and watcher warnings. No startup wiring in `lib.rs` or new dependency is needed; watcher startup is lazy.

## Verification

The worker ran:

```sh
pnpm --filter @prism/desktop exec vitest run src/providers/library.test.ts src/LibraryPanel.test.tsx
```

All 19 tests passed. They cover fast local results plus the explicit action, no automatic fallback, scope/filter/page IPC, stale queries and previews, stale action blocking, root revocation, event-driven refresh and listener cleanup, IME Enter, and broader-search response races. Existing preview/execution tests were preserved.

Native source tests use isolated temporary fixture directories only. The ignored `synthetic_100k_query_timing` test builds 100,000 rows entirely in memory and prints median/max query latency when explicitly invoked with `--ignored --nocapture`; it makes no filesystem calls and is not native or packaged performance proof. Coverage includes cache restart load, revoked/changed/replaced roots, corrupt/versioned/oversized cache rejection, invalid cached paths, bounded writes, exclusions before queuing, queue overflow, unchanged-mtime event updates, directory rename, Korean/token/subsequence matching, pagination, cancellation, symlink replacement, and scan budgets. `rustfmt` parsed the native index source. The coordinator owns serialized Cargo execution after integration; this document does not claim those tests or native application behavior were verified by the worker.

The full frontend suite was inadvertently run by an initial script argument form; the file suites passed, while palette currency selection and a shared locale test failed during concurrent integration. A separate typecheck reported two `App.tsx` preference-result accesses outside worker ownership. The coordinator has the exact failures for integration follow-up.

No development server or application was started, restarted, or stopped. No real user root was scanned for tests, and no commit, push, pull request, or deployment was performed.
