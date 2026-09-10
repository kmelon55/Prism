# File search improvements — Session 1

Filename search now returns the cached page immediately, without the former 300 ms provider delay or waiting for Spotlight. The direct Files panel prioritizes results and preview, with Library tabs available through an explicit Library button and additional search folders inside a closed disclosure.

## Implemented behavior

- Keep home-folder discovery automatic using the existing `spotlight` source ID; optional configured roots extend that scope. Existing opaque IDs, root lookup, canonical-path validation and action/preview capability checks remain authoritative.
- Build one in-memory filename catalog outside its mutex. Normalize filenames once and sort once per refresh using normalized name plus full path as a deterministic tie-breaker. Query in two passes for prefix-first ranking, count matches without materializing a match array, and clone only the requested page (maximum 100 rows).
- Reconcile directory mtimes and reuse unchanged directory listings through shared references. Detect added, renamed and deleted files on the next active refresh, including changes in nested directories. Revalidate each directory before reuse and reject symlink replacements.
- Bound traversal to 100,000 visited entries/catalog rows, depth 16 and a five-second cooperative budget. Check the deadline inside directory enumeration. Retain useful partial rows when a flat directory exceeds its budget, and retry incomplete directory caches instead of treating them as complete.
- Exclude hidden names, `node_modules`, `target`, `dist`, `build`, `Library`, `vendor`, `venv`, `__pycache__`, and `Pods`; do not descend into application bundles. No content indexing or recursive dependency-tree watching.
- Permit one background refresh at a time, fence publication by root generation, and hide snapshots from revoked generations immediately. Queries do not hold the scan lock while waiting for disk I/O. Root list changes clear stale visible rows and previews while replacement results are pending.
- Return `indexing`, `limited`, and optional `error` in `FileResults`. The Files view subscribes to `prism:file-index-changed` and requests freshness every five seconds while active. Polling pauses on window blur/document hidden, resumes on focus, and stops on unmount. Native freshness is demand-driven; there is no permanent watcher or idle scan loop.
- Only an indexed miss requests explicit `includeSystem: true` via the existing `library_search_files` command. Indexed matches never await Spotlight. The OS fallback has a 200 ms subprocess budget, one MiB output cap, at most 800 inspected paths/400 hits, and a 50 ms cooperative processing budget; fallback results are conservatively partial. Fallback errors are visible in Files instead of being reported as an authoritative empty catalog.
- Preserve row selection across refreshes and ignore superseded search/preview responses. Retain composition guards and exclude controls inside closed disclosures from the dialog focus trap.
- Add the coordinator-requested `#[path = "library_backup.rs"] pub mod backup;` child-module declaration. No backup implementation or database/lock/validator API changes.

## Coordinator integration

`watchFileIndex(callback)` is exported from `src/providers/library.ts`. Subscribe in App and invalidate the root catalog revision on `prism:file-index-changed`; the coordinator has already reported this hook and the corresponding immediate-lookup App test adjustment as integrated. No new Tauri command registration is required.

Add these three Korean/English pairs through the existing `locales/messages.json` format; that file belongs to the coordinator:

| Korean source | English translation |
| --- | --- |
| 추가 검색 폴더 | Additional search folders |
| 홈 폴더를 자동으로 검색합니다. 필요한 폴더만 추가하세요. | Your home folder is searched automatically. Add other folders as needed. |
| 파일 목록을 갱신하고 있습니다. 검색 결과가 추가될 수 있습니다. | Updating the file index. More results may appear. |

`폴더 추가` already exists in the translation catalog. Until the three new pairs are integrated, their English-locale fallback remains Korean.

## Validation

- `pnpm --filter @prism/desktop exec vitest run src/LibraryPanel.test.tsx src/providers/library.test.ts`: **16 tests passed**. New coverage includes immediate local lookup without timers, explicit fallback only on misses, cancellation before fallback, no lookup for empty/cancelled queries, automatic new-file refresh, polling cleanup and focus pause/resume, revoked-root row/preview clearing, compact Files navigation, and IME Enter safety.
- `pnpm --filter @prism/desktop typecheck`: passed after frontend changes.
- `rustfmt --edition 2021 --config skip_children=true ...`: applied only to the two owned Rust files, preserving the backup child module.
- Coordinator reported `cargo test --lib library::` passing **28 tests** before the final cap/deadline fixes. Please rerun that serialized command after the final changes; two new tests raise the expected library subset to 30. The six file-index tests cover generation fencing/revocation, new/deleted-file refresh and cache reuse, normalized ranked pagination/filtering/exclusions, root symlink replacement/cancellation, flat-folder partial-cache retry, and expired budget behavior.
- An initial `pnpm ... test -- ...` invocation unexpectedly ran the entire desktop suite: 222 passed / 6 failed at that concurrent snapshot. One App failure asserted the removed debounce, and the remaining failures were in active script integration scope; the coordinator was notified. The later correctly scoped file/library run passes.

## Exact changed files

- `apps/desktop/src-tauri/src/library.rs`
- `apps/desktop/src-tauri/src/library/file_index.rs` (new)
- `apps/desktop/src/providers/library.ts`
- `apps/desktop/src/providers/library.test.ts` (new)
- `apps/desktop/src/LibraryPanel.tsx`
- `apps/desktop/src/LibraryPanel.test.tsx`
- `apps/desktop/src/library/FileBrowser.tsx`
- `apps/desktop/src/library/useFileBrowser.ts`
- `apps/desktop/src/library/file-search.css` (new)
- `docs/file-search-improvements.md` (new)

## Boundaries and remaining verification

The cache is in memory and rebuilds after process restart. Incremental refresh uses mtimes and active polling, not a permanent filesystem watcher; filesystems with coarse or unreliable directory mtimes may require explicit refresh, which bypasses cached directory listings. Large or inaccessible trees remain explicitly partial. Cooperative deadlines cannot interrupt a single blocked filesystem syscall. The catalog is filename-only, and partial OS fallback intentionally runs only on local misses.

No development server, running application, worktree, Git publication, paid AI call, or external service was started or changed. All work stayed in the shared checkout. Real macOS hidden-window visibility events, large-home latency/resource measurements, native picker behavior and packaged-app interactions remain native checks; fixture tests do not prove them. Coordinator owns final native/full-suite checks and translation integration.
