# Desktop implementation evidence

## 2026-09-09 coordinated workflow improvements

Add immediate cached file search with incremental refresh, reviewed local backup and conservative
recovery, three concurrent conversation-owned AI replies, and script reattachment after renderer
reload. Three Orca sessions completed in the same worktree; coordinator integration and Korean
translations are included. Final checks: 287 frontend/core tests, 145 Rust tests (3 intentionally
ignored), typecheck and production build passed. The final backup native subset also passed after
its last changes. See [integrated behavior, evidence and boundaries](desktop-workflow-improvements.md).
Actual native interaction, packaged performance and paid AI remain unverified.

## 2026-09-09 desktop quality pass

Add shared dark/light surfaces and searchable grouped settings; extract settings and library components;
persist opt-in clipboard history with retention/pins; add file previews, quicklink/snippet variables and
cancellable argument-aware script execution. Split AI Chat from the first-load JavaScript bundle.
See the [implementation and visual evidence](ui-quality-pass.md) for exact bounds, validation and next priorities.
Native first-window smoothness remains unverified; no development server or user app was started or restarted.

## 2026-09-08 language and direct-search follow-up

- Add System/English/Korean preference with immediate UI updates and bilingual command matching.
  Preserve user data, app names, paths and conversation contents.
- Expose Quicklinks and Snippets directly. Always search macOS Spotlight filenames from the root
  palette, merge optional folder indexes, normalize Korean filenames and show result paths.
- Make the AI Files button refresh permissions and guide first-folder selection. A successful folder
  grant enables reading; cancellation and errors stay recoverable. Native writes notify all windows.
- Automated verification: 185 desktop + 23 command-core tests pass; native unit tests pass 104 with
  3 explicitly ignored. Browser fixtures verify language switching and direct file/tool flows; a
  real read-only Spotlight query found a known project file. Type checking and production build pass (737 kB main JS; existing chunk-size warning remains).
- Preserve existing Vite PID 3413. Native chooser behavior and live paid AI file use remain unverified.
  See [behavior and evidence](language-and-search.md).

## 2026-09-08 library and chat basics

- Add a local SQLite library for named links/paths, snippets, selected filename-search roots and
  ordered favorites. Integrate entries and filename results into root search; expose copy, open,
  reveal, editing and favorite management through a compact Library panel and existing action menu.
- Add individual clipboard deletion and target-checked macOS paste. Copy keeps the palette open;
  paste validates Accessibility, the captured application and focused window before injection.
- Stream AI text through request-scoped IPC, reconstruct split tool and reasoning deltas, preserve
  original conversations when editing/regenerating, and add rename, pin, Markdown export and code copy.
- Verification: 23 command-core and 176 desktop tests pass (199 total); type checking passes.
  Native unit tests pass 103 tests with 3 explicitly ignored. Browser fixtures verify snippet save,
  favorite reordering, intermediate/final streamed text and dark/light compact layouts. These use
  isolated in-memory IPC. Production build passes after fixture cleanup, with a 500 kB chunk-size warning (659 kB main JS).
- Actual macOS paste, file/save dialogs and live paid provider responses remain unverified. Existing
  Vite PID 34937 was preserved; no server was manually started, restarted or stopped. The existing
  Tauri watcher can react to native source changes. No commit, publication or deployment was made.
- See [library behavior](local-library.md), [chat behavior](ai-chat.md) and the updated
  [remaining gaps](basic-feature-audit.md). Settings backup, emoji, richer scripts, concurrent chat and
  image/PDF attachments are not included in this follow-up.

## 2026-09-07 search continuity and AI window follow-up

- Reopening an expanded AI Chat preserves its native frame. Compact palette placement still follows
  the cursor's monitor; reopening chat no longer applies the compact palette's vertical placement.
- Query edits immediately rerank existing rows against the new text and aliases. Matching rows stay
  mounted while their providers refresh; completed sources replace their previous rows, including
  empty or failed completions. Query-specific answers are removed when their expression changes.
  Available rows are no longer replaced by an empty loading surface during refresh.
- Regression coverage observes DOM removals while a native application query is pending and verifies
  stable row identity after completion, empty-source removal, aliases, and stale-query rejection.
- Verification: `pnpm test` passes 22 command-core and 157 desktop tests; `pnpm typecheck` passes.
  `cargo test --lib` passes 93 tests with 3 explicitly ignored. No development server or application
  was started, stopped, or restarted. Actual macOS hide/show position and perceived rendering
  smoothness remain unverified in the running native application.

## Earlier implementation record

Updated: 2026-09-06. The record below describes the earlier M1 slice; later currency work is recorded
in [currency conversion](currency-conversion.md). The historical source hash and server observations
below do not describe the current checkout or currently running app.

Earlier scope: M1-A interaction, M1-B root-search improvements, and the searchable-action
portion of M1-C. This is an implementation record, not completion of M1 or the selected-basics baseline.

## Changes in this slice

- A navigation reducer owns query generations, selected items and parent locations. Root Escape clears
  text before hiding; scoped Escape clears before returning. Back restores query, selected ID and scroll.
  Stale query generations cannot replace current results. Selection follows the best result until the
  user navigates, then stays attached to its ID through result updates; list navigation clamps at ends.
- A shared keyboard hook protects composition events, `isComposing` and legacy IME key code 229 before
  root, settings, recorder and action handlers run. Repeated Enter/Escape cannot repeatedly execute or
  traverse states. Settings confirmations and recorders cancel before Settings closes. Pointer-triggered
  actions and clear/back/retry controls return focus to search. Failed hide preserves the current query.
- Root search publishes available providers independently, with a 500 ms per-provider deadline,
  cooperative abort signals, observed late rejections, partial-failure notices and a Retry control.
  Retry reruns the root search without clearing its query. Already-started native IPC is not forcibly
  canceled by an AbortSignal; native execution/latency evidence remains separate.
- Match tiers give exact user aliases precedence. Calculator/web providers explicitly correlate their
  result with the recognized query so title-based reranking cannot discard a valid intent or reuse it
  for another query. Native application aliases resolve only matching candidates, at most 40 with four
  concurrent lookups; cancellation stops starting additional lookups.
- Action search has its own query and selected result. Actions remain bound to the item that opened
  the panel, even if root results refresh. The panel contains keyboard focus and supports Escape,
  Cmd/Ctrl+K and pointer dismissal. Primary-action labels reflect the actual operation. Loading shimmer
  is delayed by 150 ms instead of appearing on every brief query transition.
- Added a desktop DOM test suite using React and mocked Tauri IPC. `pnpm test` now runs desktop and
  command-core suites. No reference-project code, tests, schema, or assets were imported.

The IME event boundary follows the behavior documented by
[MDN's keydown guidance](https://developer.mozilla.org/en-US/docs/Web/API/Element/keydown_event#keydown_events_with_ime).
The tests mount the real React UI with [React act](https://react.dev/reference/react/act) in a
[Vitest DOM environment](https://vitest.dev/config/environment). A DOM simulation is not a live IME.

## Verification on this source snapshot

| Check | Result | Boundary |
| --- | --- | --- |
| `pnpm test` | Pass: 21 command-core tests and 30 desktop tests, 51 total | Logic and mounted DOM with mocked native calls |
| `pnpm typecheck` | Pass | TypeScript only |
| `pnpm build` | Pass, including the final TypeScript build | Frontend production assets; no new native binary |
| QA-01/02 | DOM focus, Escape/back and parent restoration covered | External app activation and native window focus Not run |
| QA-03 | Composition flags/events and commit-key boundaries covered | Korean IME in actual macOS WebView Not run |
| QA-04 | Tiers, Unicode normalization, stale results, selection, timeout and cancellation covered | Native candidate-ranking equivalence and timing budgets Not run |
| QA-05 | Action filtering, labels, original target binding and key-repeat covered | Full operation lifecycle/double-click protection remains broader M1 work |
| QA-06/07 | Recorder/confirmation priority, Settings input isolation and hide failure covered | OS shortcut conflict/write rollback and real cross-window behavior Not run |
| M0 visual captures | Not run | No connected browser available; no screenshots or visual approval claimed |
| Packaged performance and QA-08–21 | Not run except the specifically listed mocked interactions | No OS feature or release-quality claim |

Environment: Node 24.20.0; frontend build used Vite 7.3.6. Test tooling uses Vitest 4.1.11 and
jsdom 26.1.0. The lower jsdom major preserves compatibility with the project's Node 22 development
baseline instead of requiring the latest Node 22 patch for the test harness.

Frontend source/config SHA-256:
`f4930cda5b4babddef175886f2f094944c912aadde8e3ab7e637b098b5492516`.
Computed over 34 sorted inputs: every file beneath `apps/desktop/src` and `packages/command-core/src`,
plus root package/lock/workspace files, desktop package/tsconfig/Vite/Vitest/index.html, and command-core
package/tsconfig. Each input contributes UTF-8 relative path, NUL, bytes, NUL. Includes tests; excludes
docs, generated output, dependencies, secrets and unchanged native sources. This identifies the tested
frontend inputs in the currently untracked tree; it is not a native-bundle identity.

The existing Prism native process was left running. No listener was found on its configured port 1420
and browser discovery returned no connection. No server was started, stopped or restarted. The running
native application was not rebuilt or relaunched, so it is not evidence of this updated frontend.

## Remaining work

M1-A still needs live IME/focus and visual evidence; current settings draft-loss behavior needs further
work before the broader form contract can be closed. M1-B still needs native ranking/candidate review
and real timing measurements. M1-C still needs favorites, complete command configuration paths, and
broader operation lifecycle feedback. M1-D/E/F (clipboard reuse, native layout proof, script lifecycle)
and M2/M3 additions other than daily currency conversion and [local units/grouping](unit-conversion.md) remain open. See [delivery plan](delivery-plan.md) and
[quality gates](quality-gates.md); none of those full milestones is marked complete by these tests.
