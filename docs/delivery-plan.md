# Deliver the desktop basics baseline

Updated: 2026-09-06 · Status: planned; no milestone completed by this document.

Implementation update: M1-A navigation/keyboard handling, M1-B incremental root search, and M1-C action
search/labels now have code and automated coverage. Their exact scope and remaining native/visual
gates are recorded in [implementation-status.md](implementation-status.md). Full M1 remains open.

Goal: deliver the selected P01–P12 workflows in [product-spec.md](product-spec.md) with the actual
interaction, persistence, and native proof in [quality-gates.md](quality-gates.md). Asyar is behavioral
and architectural research; all implementation remains independently authored. No source or assets
from Asyar are needed to start any work package below.

## 1. Initial gap register

Evidence below records the pre-implementation inspection on 2026-09-06. Some named paths have now
changed; use implementation-status.md for resolved portions and recheck the current symbols before
editing this active tree. Existing code and automated tests do not close a native runtime gate.

| Gap | Evidence in current tree | Consequence | Work package |
| --- | --- | --- | --- |
| Escape behavior differs from README | `App.tsx`, `onKeyDown`, root falls through to `dismissPalette` with a query | Search cannot follow the new clear-then-hide contract | M1-A |
| IME execution guard absent in root handler | `App.tsx`, `onKeyDown`, handles Enter without checking composition | Composition commit may dispatch an action; native reproduction pending | M1-A |
| Every completed search selects index zero | `App.tsx`, search effect calls `setSelectedIndex(0)` | Refresh can replace user selection | M1-B |
| Providers settle as a group | `command-core/src/search.ts`, `searchProviders` uses `Promise.allSettled`; UI also waits for aliased apps | Slow/hung source can delay available results | M1-B |
| Exact alias precedence not contractual | `scoreCommand` weights title above aliases; test expects title/alias/keyword field priority | New explicit-alias rule requires a deliberate test/behavior change | M1-B |
| Calculator and web items pass generic title matching | Calculator title is result; root reranks all returned items | Explicit intent must survive generic ranking; reproduce expression cases before choosing fix | M1-B |
| Actions lack search; root labels every primary action Open | `App.tsx`, `ActionPanel`, result rows and footer | Poor discovery and misleading copy/apply/run feedback | M1-C |
| Favorites absent from current preference/command model | `App.tsx` preferences and command-core types | No user-controlled empty-root ordering | M1-C |
| Clipboard is text/copy/session only | `clipboard_history.rs`; `App.tsx` clipboard action path | Paste, individual delete, rich entry types and persistence remain work | M1-D, M3-A |
| Layout commands have platform limits | `window_management.rs`, documented macOS adapter | Native/multi-display reliability is unproven | M1-E, M3-B |
| File/links/snippets/symbol providers missing | Current provider directory has no such real providers | Important repeat workflows cannot be completed | M2-A to M2-D |
| Calculator covers arithmetic only | `arithmetic.rs`, `calculator.ts` | Conversions and date/time syntax absent | M2-E |
| Script result view/arguments/cancel incomplete | `script_commands.rs`, `scripts.ts`, execution toast in `App.tsx` | Native execution exists without full user-visible lifecycle | M1-F, M3-C |
| Durable settings split across stores | Webview preferences vs native shortcut files | Unified export, migration and recovery need a native authority | M3-D |
| Historical visual direction differs from current UI | `research.md` fixed-preview/spectral language; current root list | Product judgment lacks a current shared reference | M0 |

## 2. Sequence and ownership

Ownership below identifies modules for future implementation; it does not dispatch agents or imply
parallel edits. New paths are proposed, existing paths are relative to the repository root.
Preserve dirty files and the running dev server. Each package starts with inspection of current state.

### M0 — Establish the visible and behavioral baseline

Entry: this specification and source inspection. No feature implementation prerequisite.

1. Inventory an existing browser/native session without starting or restarting a server. Record what
   runtime is actually visible before describing a screenshot as native.
2. Produce original state references from the current UI for the states in product-spec.md section 6.
   Use static component fixtures or the existing preview; missing feature screens may be explicit
   design references, labeled as proposals. Do not imply they are implemented.
3. Review density, hierarchy, actual primary verbs and light/dark readability. Record the user's
   visual decisions when provided. Independent logic/data implementation can proceed while visual
   approval remains pending; do not present unreviewed designs as accepted.
4. Add a compact evidence record with Not run for missing native checks and identify the source tree.

Own: `apps/desktop/src/App.tsx`, `apps/desktop/src/styles.css`,
and new original review artifacts. Do not rewrite the UI solely to create documentation screenshots.
Exit: current behavior and intended states are distinguishable; visual review decisions/gaps recorded.

### M1 — Make the existing daily loop dependable

Entry: product baseline. M0 visual work can continue; visual approval is required before visual sign-off.

| Package | Scope and owned seams | Dependencies | Exit evidence |
| --- | --- | --- | --- |
| M1-A | Extract palette navigation/composition handling from `App.tsx` into proposed `interaction/`; implement state priority, Escape and focus restoration | Specification section 4 | QA-01–03; owned dialogs/settings unaffected |
| M1-B | Incremental bounded search, stable selected IDs, current-generation execution, explicit-intent results, alias tiers; `command-core/src/{types,search}.ts`, `providers/native.ts`, `application_index.rs`, `App.tsx` integration | M1-A state contract | QA-04, arithmetic/URL smoke cases, warm search budget |
| M1-C | Searchable actions, action verbs, favorites and exact-item settings navigation; `App.tsx`, command-core metadata and provider actions | M1-A/B | QA-05–07; root default ordering and persistence |
| M1-D | Text-history individual delete and paste/Copy fallback; `clipboard_history.rs`, `providers/native.ts`, proposed clipboard view | M1-A; shared previous-target identity | QA-08/09 on text, memory-only privacy boundary retained |
| M1-E | Common layout/restore and Settings-page validation; `window_management.rs`, `system_commands.rs`, native provider and permission UI | M1-A target/focus contract | QA-10/11 on macOS; unsupported entries filtered |
| M1-F | Visible script lifecycle/output, prevent repeated runs; `script_commands.rs`, `providers/scripts.ts`, proposed script result view | M1-A/C | QA-20 success/failure/timeout/output subset |

Exit: M1-required cases pass on a recorded local native build; visual baseline is reviewed; no open
critical/high defects in shipped M1 scope. Call this an everyday-use alpha, not basic-feature parity.
Split `App.tsx` only along the touched interaction/view seams; a wholesale rewrite is not a milestone.

### M2 — Complete the missing everyday workflows

Entry: M1 interaction and action contracts stable. Reuse the same typed action lifecycle and UI states.
Before the first new durable library, introduce the native versioned storage and atomic-save seam
owned by M3-D; full migration/export follows later. Do not park new user libraries in localStorage.

| Package | Scope and owned seams | Dependencies | Exit evidence |
| --- | --- | --- | --- |
| M2-A | File roots/index/query/watch/limits and scoped file view; proposed `src-tauri/src/file_search/`, `providers/files.ts`, `views/FilesView.tsx`; register narrow IPC in `lib.rs` | M1-B/C, early native-store seam | QA-14/16 file subset; 100k index budget |
| M2-B | Saved destinations and one argument form; proposed native destinations module, provider and editor | M1-C, native store; reuse M2-A authorization for local paths | QA-13/15 and input encoding fixtures |
| M2-C | Snippet CRUD/search/preview/copy/paste; proposed native snippets module/provider/editor | Native encrypted-store seam, M1-D paste contract | QA-17; 1,000-item restart round trip |
| M2-D | Local emoji/symbol dataset with provenance, picker and recent choices | M1-C/D; data-source review | QA-17 symbol subset; English/Korean search |
| M2-E | Daily currency references and [local units/grouping](unit-conversion.md) implemented; percent/date/time grammar remains next. See [currency scope](currency-conversion.md). | M1-B explicit-intent handling | QA-12 supported grammar, unit dimensions/temperature/precision, currency date/source/cache/copy fixtures |

Exit: P06–P08/P12 are usable vertical slices, not mocked catalog rows; all M2 cases and file/query
budgets pass. Snippet auto-expansion, durable clipboard and display movement remain explicit M3 gaps.

### M3 — Reach the selected desktop-basics release candidate

Entry: M1/M2 gates pass. Add depth without weakening the shared selection/focus/privacy contracts.

| Package | Scope and owned seams | Dependencies | Exit evidence |
| --- | --- | --- | --- |
| M3-A | Clipboard capture metadata/exclusions, encrypted retention, pins, image/file entries and paste formats; native clipboard/storage modules and view | M1-D; native encrypted storage | QA-08/09/16/18, quota/keychain failures |
| M3-B | Next/previous display and full window compatibility matrix | M1-E | QA-10/11 including detach, minimum-size/full-screen cases |
| M3-C | Script arguments, owned-process cancellation, changed-target handling and hotkeys | M1-F; common shortcut manager | QA-20 complete; no owned child left running |
| M3-D | Finish native preferences authority, migration, export/import, login toggle and cross-window revision handling | Storage seam introduced before M2 libraries | QA-06/07/15/18; atomic failure/restart recovery |
| M3-E | Opt-in snippet expansion with secure-input/app exclusions and composition handling | M2-C, M1-D target identity; native permission research | QA-19; no wrong-target insertion |
| M3-F | English/Korean strings, accessibility, all required visual states and native performance instrumenting | Shipped views; instrumentation starts during M1 | QA-21, complete budgets, final original screenshots |

Exit: all selected-baseline gates, five-day dogfood, and visual review pass. Publish a support matrix
and comparison-gap list in documentation. Actual signing, packaging distribution, updater work and
publishing are a separately authorized release task; do not equate this exit with public availability.

### M4 — Expand only after the baseline is demonstrated

Evaluate remaining Raycast comparison gaps, then independent extension/AI/mobile/platform expansion.
Each added capability needs its own user flow, permission/data policy and measurable gate. Windows,
Linux and Intel macOS each need native evidence before promoting their status. Do not postpone
M1–M3 repairs to make room for a store, AI panel or larger command catalog.

## 3. Implementation working agreement

For every package: inspect Git status and relevant instructions; preserve unrelated edits; write
the smallest usable slice; run affected logic/contract checks and appropriate existing project
checks; inspect with the existing preview when available; collect native evidence for OS behavior;
update actual-state docs and the gap register. Documentation edits alone do not require compilation.

Existing server-free checks are `pnpm typecheck`, `pnpm test`, `pnpm build`, and Rust validation from
`apps/desktop/src-tauri` (for example `cargo test`). `pnpm test` now covers command-core and the mounted
desktop DOM with mocked IPC; it does not cover actual native behavior. Add meaningful interaction tests for state
changes. Run native bundles only in a way consistent with the user's active session. Never start,
restart, stop, or replace their development server to obtain evidence.

The next work combines remaining M1-C personalization with M1-A/B native/visual verification when the
existing runtime is available. M1-D/E/F remain necessary before M1 can close. Continue preserving the
active application and server; unavailable live evidence does not justify starting a replacement server.
