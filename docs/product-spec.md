# Prism desktop product specification

Version: 0.1 · Updated: 2026-09-06 · Status: implementation planning baseline.

This document defines intended behavior, not shipped capabilities. The user requested independent
implementation informed by Asyar and the everyday quality of Raycast. The macOS-first sequence,
feature boundaries, numerical targets, and visual dimensions below are planning decisions proposed
here; they are not recorded user approvals or measured results.

Read with [delivery plan](delivery-plan.md), [quality gates](quality-gates.md), and
[architecture](architecture.md). This specification governs future product behavior. Architecture
describes the current implementation; research records historical decisions and external observations.
When behavior changes, update implementation and current-behavior documentation together.

## 1. Product promise and audience

Prism lets a person find an app, recover something they copied, open a working file or destination,
insert reusable text, and arrange a window from one predictable keyboard entry point.

The initial audience is people who alternate between a browser, editor, documents, and messaging
throughout the day, including Korean/English bilingual users. The adoption hypothesis is that a
readable, dependable, locally controlled launcher can replace their repeated navigation and copying
steps. Validate this with daily use; an open-source label alone does not establish preference.

The first quality reference platform is macOS on Apple Silicon. Keep existing Windows/Linux code;
report each platform's verified capabilities separately. Passing macOS checks does not establish
Windows/Linux support. Intel macOS is also unverified until tested. Android is a later product.

Success means people can complete the defined tasks without reaching for another launcher because
Prism lost focus, ranked the wrong item, forgot settings, or stopped at a copy-only demo.

## 2. Reference policy and interpretation

Use Asyar's documented capability breadth and host/native separation as architectural research.
Use Raycast's documented everyday workflows as a usability benchmark. Sources and a dated reference
snapshot are in [research](research.md#2026-09-06-product-planning-reference-snapshot).

For this project, independently write all implementation, identifiers, schemas, ranking logic, tests,
strings, layouts, icons, and assets. Do not paste, translate, port, or mechanically rewrite Asyar
source, SDK contracts, fixtures, or UI. Do not import its package or copy its benchmark harness.
Keep behavioral notes separate from source code. For OS implementation, research the relevant public
platform APIs and implement against Prism's own capability contracts. This is the user's project
constraint, not a claim that GPL prohibits all reuse or a legal certification of provenance.

Reference features are documented claims, not independently verified performance or reliability.
Competitor timings are not Prism targets or proof. Common interactions such as Enter to execute are
expressed as Prism's own requirements; exact competitor APIs and visual composition are not goals.

## 3. Meaning of basic-feature completeness

M1 is an everyday-use alpha, M2 fills essential workflow gaps, and M3 is the release candidate for
the **selected desktop basics** below. All three milestones are required before claiming that this
baseline is complete. Shipping M1 does not satisfy the user's broader quality objective.

Even M3 is not full Raycast parity. The explicit comparison gaps after the table stay visible in
release documentation. Feature presence, polished interaction, and native verification are separate.

Current state below is a source inspection on 2026-09-06. None of these rows received fresh runtime
verification during this planning task. “Present” means a code path exists, not that a gate passed.

| ID | Capability and reference | Current Prism evidence | Required target and milestone |
| --- | --- | --- | --- |
| P01 | Summon, search, apps; [Raycast search](https://manual.raycast.com/search-bar) | Native app catalog, bounded results, usage ranking, global shortcut | M1: stable selection, IME-safe input, immediate focus, deterministic ranking, app activation, failures and restart recovery |
| P02 | Actions and personalization; [Raycast actions](https://manual.raycast.com/action-panel) | Action list, aliases, visibility, app/command shortcuts | M1: searchable actions, correct action verbs, favorites, per-item configuration and conflict recovery |
| P03 | Clipboard; [Raycast clipboard](https://manual.raycast.com/clipboard-history) | Opt-in memory-only text, copy, clear all; 100 entries | M1: text reuse and deletion; M3: reliable paste, image/file entries, privacy exclusions, bounded encrypted persistence |
| P04 | Window layout; [Raycast windows](https://manual.raycast.com/window-management) | macOS layouts and one-step restore | M1: common layouts/restore/permissions; M3: next/previous display and full matrix verification |
| P05 | Calculator; [Raycast calculator](https://manual.raycast.com/calculator) | Bounded arithmetic parser | M1: expression/result clarity and correct errors; M2: percentages, units, explicit date/time-zone expressions |
| P06 | Destinations; [Raycast quicklinks](https://manual.raycast.com/quicklinks) | Explicit HTTP(S) open and fixed web search | M2: saved web/file/folder destinations, one query argument, edit/delete, aliases and shortcuts |
| P07 | File search; [Raycast files](https://manual.raycast.com/file-search) | Type vocabulary only; no real file provider | M2: chosen-folder filename search, root/scoped results, metadata, open/reveal/copy path, cancelable indexing |
| P08 | Snippets; [Raycast snippets](https://manual.raycast.com/snippets) | No provider or editor found | M2: create/edit/search/copy/paste; M3: opt-in keyword expansion, exclusion and IME behavior |
| P09 | Local scripts; [Raycast scripts](https://manual.raycast.com/script-commands) | Folder registry, opaque execution ID, timeout and bounded output | M1: honest run state and output; M3: arguments, cancellation, changed-script handling and hotkeys |
| P10 | Settings and recovery; [Raycast settings](https://manual.raycast.com/settings) | Separate settings window, appearance, aliases, native shortcuts | M1: consistent navigation/save errors; M3: local export/import and recovery without data loss |
| P11 | System commands | Settings-page allowlist, lock screen | M1: tested entries only, platform filtering, accurate labels and recoverable errors |
| P12 | Emoji and symbols; [Raycast symbols](https://manual.raycast.com/emoji-symbols) | No provider found | M2: local searchable picker, Korean/English terms, recent items, copy/paste |

Known comparison gaps beyond M3: intraday currency quotes, broad natural-language calculation,
rich-text/OCR clipboard transforms, full-text file search and document preview, advanced snippet
placeholders, custom window layouts/Spaces automation, arbitrary URL schemes, and background script
schedules. Notes, calendar/contacts, focus automation, screenshots, translation, and navigation
utilities are separate additions, not silently counted as complete. A macOS BYOK AI chat slice is
now implemented separately; see [AI chat](ai-chat.md) for scope and proof boundaries. MCP, browser integration,
extension compatibility/store/runtime, cloud sync, and mobile remain later milestones.

Daily reference currency conversion is now included in M2-E. Its source selection, attribution,
supported grammar, freshness, and offline policy are defined in [currency conversion](currency-conversion.md).
Exchange rates must never be silently represented by fixed rates.
Do not add accounts, subscriptions, or cloud dependencies to unlock P01–P12.

## 4. Shared interaction contract

### 4.1 Window and navigation states

| State/trigger | Required result |
| --- | --- |
| Hidden → global shortcut | Show on pointer display; position within usable bounds; focus input before typing is possible; capture previous external app/window |
| Visible → global shortcut, close control, or Cmd/Ctrl+W | Hide the palette; clear its transient navigation; keep process alive |
| Root with query → Escape | Clear query and select the first default result; stay visible |
| Empty root → Escape | Hide |
| Scoped view with query → Escape | Clear scoped query |
| Empty scoped view → Escape | Return to parent, restoring its query, selected ID, and scroll position |
| Action panel → Escape | Close panel; restore invoking item's selection and input focus |
| Action panel → text input | Filter actions only; root query stays unchanged |
| Editing form → Escape/back/close | If dirty, offer Save, Discard, or Keep Editing; never silently lose a draft |
| Palette → Settings | Open/focus the single settings window and exact item/section; palette hides |
| Settings loses focus | Stay open; typing in its controls never executes root commands |
| Palette loses focus | Hide unless an owned dialog or shortcut-recovery state requires visibility |
| Successful app/file/link open, paste, or layout | Hide and hand off focus to the intended external app; reset transient palette state |
| Successful copy-only action | Keep view open and show a brief accessible confirmation |
| Failed action | Keep or restore initiating view, query and selection; explain recovery; do not record successful usage |

Priority is active composition → shortcut recorder → confirmation/form → action panel → scoped view
→ root. During IME composition, Enter/Escape/arrows belong to the input method. Committing a Korean
syllable must not execute an item. A separate subsequent Enter can execute. Test the native WebView,
not only synthetic DOM events. A newly opened palette starts at empty root; returning from a nested
view restores its parent within the same visible session.

### 4.2 Search and selection

- Empty root: user-ordered favorites, up to eight recent successful items, then a small getting-started
  set when no usage exists. Do not fill it with every window layout or maintenance action.
- For a nonempty query, explicitly assigned exact aliases win; then exact title, title prefix,
  alias prefix, title subsequence, and keyword/subtitle matches. Frequency/recency and favorites
  break ties within a match tier; they never create a match or outrank an explicit exact alias.
  An explicitly recognized calculator/web query inserts its correlated result immediately after exact
  aliases and before general name matches; that result must not survive into a different query.
- Duplicate aliases are rejected on save with the conflicting item identified. Existing duplicates
  remain reachable with a stable ordering and a conflict indicator until the user resolves them.
- Normalize Unicode consistently in native and shared search. M1 supports complete Korean text and
  user aliases; M2 adds Korean initial-consonant matching. Automatic wrong-keyboard conversion and
  phonetic romanization are deferred and must not be implied by a Korean-support claim.
- Input changes start a new query generation. Stale generations cannot update results or actions.
  Retained old rows are non-executable until validated against the current query.
- Once the user navigates, pin selection by stable ID during updates for that query; late results
  must not replace the selected target. If it disappears, choose the nearest surviving row and
  announce the change. An open action panel binds to its original item ID.
- New query → first current result. Arrow keys clamp at list ends; they do not wrap. Pointer
  selection changes only on actual movement, not because content moved under a stationary pointer.
- Publish each available provider's results without waiting for the slowest. Preserve working
  sources when one fails. Root source deadline: 500 ms; scoped file search: 1,500 ms. Offer Retry
  for a failed source without clearing the query. Bound background work as well as ignoring stale UI.
- Local typing never initiates a network request. Web results run only after an explicit action.
  Root has at most 40 rows, including at most eight files; scoped files use 40-row pagination.
  Larger libraries must remain reachable through scoped search and pagination.
- A settled zero-match state names the current scope and offers Clear Search; root may offer an
  explicit Search Web action. A disabled or permission-blocked source explains how to enable it.
  Do not show No Results while a source is still loading; use a quiet progress label after 150 ms.

### 4.3 Actions and feedback

The selected row uses the actual primary verb: Open, Copy, Paste, Run, or Apply.
The 2026-09-08 UI removes the persistent footer and keyboard hints; secondary actions remain
available through a compact toolbar icon and the existing shortcut. The same
action has the same meaning in the row, action panel, and shortcut. Show secondary actions through
Cmd/Ctrl+K, with a search field, visible selection, and keyboard-accessible configuration. Make
favorites and alias/shortcut editing reachable there; deep-linking to the selected Settings row is
acceptable for M1. Never require the user to find that item again in Settings.

Action lifecycle: ready → running → success, failure, or canceled. Prevent double submission and
key-repeat execution. Show running feedback within 100 ms; after 300 ms show a persistent operation
indicator. Do not display success based solely on optimistic state. OS spawn acceptance is technical
evidence; app activation/paste/window change requires observing the external result in native QA.

An unsupported feature is hidden from root but discoverable with an explanation in Settings.
Permission-required commands remain discoverable and lead to one clear grant/recheck flow.
Clear-all, reset, and cache maintenance belong in scoped settings/actions with explicit confirmation.
Never log raw clipboard bodies, snippet text, query history, or script output by default.

## 5. Feature depth and acceptance contract

### P01 / P02 — Launching and personalization

Find exact names, partial names, aliases, and Korean names. Disambiguate duplicate application names
with a short location subtitle. Activate an existing instance when supported by the platform opener.
Deleted targets produce an actionable unavailable state and refresh; never launch an unrelated path.
Favorites, aliases, visibility, ordering and shortcuts survive restart. Disabling a command also
removes its binding transactionally. Settings stays searchable and cannot be disabled. A failed
shortcut registration or settings write preserves the previous working binding and saved value.

Acceptance: run QA-01 through QA-07 and QA-15. Quality fixture ordering is defined in quality-gates.md.

### P03 — Clipboard reuse

M1 remains explicitly enabled per session and memory-only, with up to 100 text entries. Show a
readable preview, capture time, search, Copy, Paste when permitted, individual delete, and clear all.
M3 remembers explicit opt-in and supports text, image, and file-reference entries. Entry type is
visible; image preview and file-existence errors must not block text search.

M3 defaults: seven-day retention, at most 1,000 unpinned entries, 50 pinned entries, and 100 MiB total
payload. Text item cap 128 KiB; image cap 10 MiB; file entries store references, not file contents.
Pins skip time/count eviction but count against total bytes. Evict oldest unpinned entries first;
if pins alone prevent a write, skip capture and show capacity status. Never silently delete a pin.
Offer Session Only, 1 day, 7 days, or 30 days; switching to Session Only purges persisted history.

Capture honors private/transient OS metadata, known secret patterns, and a configurable excluded-app
list before storage. Source detection limitations must be stated; heuristics are not a guarantee of
finding every secret. Persisted payload and previews are encrypted with an OS-keystore-managed key.
If key access fails, stop persistent capture and expose recovery; do not write plaintext instead.
Opting out stops capture and clears history; explain this beside the toggle and confirm if pins exist.

Paste writes the selected format then returns focus to the captured external target and requests
paste once. If the target vanished, permissions are absent, or the system is locked, do not inject
keys into another app. Offer Copy explicitly and do not claim that paste completed. Do not restore
an old clipboard over a newer user copy. M1 can expose the permission-bound paste path, but M3
requires the privacy and supported-format gates before being called complete.

Acceptance: QA-08, QA-09, QA-16, QA-18; known remaining gap: rich-text preservation and OCR.

### P04 / P11 — Windows and system actions

M1 verifies halves, quarters, thirds, maximize, center, and restore. Keep existing extra layouts only
when they pass the same tests. Geometry uses the target window's display work area, not necessarily
the pointer display used to place the palette. Respect Dock/menu exclusions and app minimum sizes.
Restore means the position immediately before the last successful Prism mutation of that same
window. Failed mutations never overwrite restore state. It lasts for the process session only.

M3 adds next/previous display with predictable relative placement and clamping. No other eligible
display means a no-op explanation. Minimized/full-screen/non-resizable windows and closed targets
must fail safely or use an explicitly specified supported behavior, without changing another window.
System Settings destinations and Lock Screen ship only after native checks on the declared OS.
Power-off, force quit, and other destructive system actions are outside this baseline.

Acceptance: QA-10, QA-11, QA-15.

### P05 — Calculator

M1 displays expression, result, and Copy Result. Incomplete input is neutral; division by zero,
overflow, or unsupported syntax never produces a valid-looking result. Preserve bounded local parsing.
M2 adds percentage-of, fixed unit conversion (length, mass, temperature, duration, decimal/binary
data sizes), ISO-date arithmetic, and IANA-time-zone conversion with explicit date and offset.
Accepted example grammar: `12% of 250`, `3 km to m`, `32 F to C`, `2 GiB to MiB`,
`2026-09-06 + 3 days`, `2026-09-06 09:00 Asia/Seoul to UTC`. These examples are Prism requirements.
Ambiguous local times require choosing an offset; nonexistent daylight-saving times report an error.
Document supported grammar in help; do not promise arbitrary natural language or live rates.

Acceptance: QA-12 and the calculation fixtures in quality-gates.md.

### P06 — Saved destinations

Create/edit a named HTTP(S) URL, local file/folder target, or web search destination. A search
destination has a base URL and an explicitly selected query-parameter name; at execution Prism
URL-encodes one user-entered argument. This avoids importing a reference product's template grammar.
Root finds destinations by name/alias; Enter opens a required argument field when necessary, then
executes once. Show the resolved host/path before opening. Do not silently use selected text or
clipboard contents. Validate in Rust on save and execution; reject executable URL schemes and
missing local targets. Browser-history import, website favicon fetching, and custom schemes are later.

Acceptance: QA-13, QA-15, QA-18. Saved entries have atomic local persistence and confirmed deletion.

### P07 — File search

Explicitly choose roots; no automatic whole-home scan. Filename/path metadata only. Exclude hidden
files, dependency/build/cache directories by default, with visible include/exclude controls. Symlinks
must not escape authorized roots. Revoking a root immediately removes its searchable results and
cancels its work. Handle offline volumes and permission changes without blocking app search.

Root provides bounded matching files. A scoped file view adds path, kind, size, modification time,
and Open, Reveal, Copy Path, and Open With. Open With selects from known native applications rather
than arbitrary executables. Duplicate names show distinct paths. Use native-authorized IDs and
revalidate paths at execution. Show indexing progress and Pause/Resume; partial index results remain
usable. Disk-backed catalog, background updates, cancellation, and quotas precede broad rollout.
The initial support envelope is 100,000 entries across chosen roots; reaching it shows a limit and
retains search of indexed entries instead of silently claiming the entire folder is indexed.

Acceptance: QA-14, QA-16; known remaining gaps: content search and rich document preview.

### P08 / P12 — Reusable text and symbols

Snippets have a name, plain-text body, optional expansion keyword, and optional tags. Support
create, edit, search, preview, copy, paste, duplicate, and confirmed delete. Save before reporting
success; 1,000 snippets and 64 KiB per body define the first support envelope. Keep bodies in the
native data store with encrypted persistence; never in browser localStorage or automatic logs.

M3 auto-expansion is default-off, permission-bound and disabled in secure input/excluded apps.
Use explicit prefixed keywords ending at a word boundary. A completed keyword followed by Space
expands once and retains the delimiter; Enter is not an expansion trigger in this baseline. Never
expand during composition, on pasted text, or recursively inside inserted text. Duplicate keywords
are rejected. If target identity/secure-input status cannot be established, skip expansion. Users
can disable expansion without deleting snippets. Dates/clipboard placeholders and rich text are later.

Emoji/symbol search is a scoped local catalog with Korean/English labels, sequence-safe insertion,
skin-tone selection where supported, and 30 recent choices. Use separately reviewed data provenance;
do not copy the reference product's dataset or art. Render native glyphs. Copy works without paste
permission; Paste follows P03's target contract.

Acceptance: QA-17, QA-18, QA-19.

### P09 — Local scripts

Keep the existing opt-in folder and opaque-ID boundary. Display running, duration, exit status,
bounded output, truncation, timeout, and errors in a scoped result view. M3 adds up to three explicit
text arguments passed as argv, a Cancel action that terminates owned child work, and settings-managed
hotkeys. No shell interpolation of arguments. Maximum one active run per script; no accidental
repeat launch. Default maximum runtime remains ten seconds and background scheduling stays out.

The configured local file can execute with the user's process permissions; present this clearly
when adding the folder. Deleted or identity-changed targets cannot execute through stale IDs.
Changes require a refreshed registry; app UI stays responsive while a script runs. Hiding the palette
does not cancel the run; reopening the script shows its active/result state for the current session.
Terminal output is text, never executable markup. The script-result viewer keeps the most recent
20 session results, capped at 2 MiB aggregate output with oldest-result eviction; quitting clears
these records. Mark truncated output and retain the operation's final status even when output is cut.

Acceptance: QA-20. Script arguments/hotkeys must use the same configuration and failure conventions.

### P10 — Settings, onboarding, and data

First launch needs no account. Show app discovery and one example launch; ask optional permissions
at feature entry. A user who skips every optional permission can still launch apps and calculate.
Offer an explicit launch-at-login toggle; enabling it must be user initiated and survive app updates.

Settings navigation: General, Appearance, Applications & Commands, Clipboard, Files, Links, Snippets,
Windows, Scripts, and Advanced. Hide unimplemented sections until usable. Each capability owns its
aliases/hotkeys and relevant permission explanation. Advanced contains maintenance and export/import.
Always offer a route to launch/recover Settings when no global shortcut registers.

M3 native storage owns durable user configuration. Keep application indexes and caches rebuildable;
they are not the settings authority. Migrate existing webview preferences once with validation and a
backup, preserve previous data on failure, and broadcast native revisions between windows. Define
an independent versioned export format covering preferences, favorites, aliases, shortcuts, links,
snippets, roots and script-folder configuration. Exclude clipboard history, keys and run output.
Warn that exports containing snippet bodies are readable local files; export only on user request.
Import validates size/version/fields, previews changes, defaults to keeping local conflicts, and
applies atomically. Imported paths and shortcuts require local revalidation; import never auto-runs
scripts, starts clipboard capture, enables expansion, or grants OS permissions.

UI language target is English and Korean with a System/English/Korean preference. Keep stable IDs
language-neutral; search built-ins by either language. User-created names remain unchanged. Missing
translations use English fallback. M1 must handle Korean input correctly; M3 requires translated
shipped surfaces. Export and crash diagnostics must not contain user payloads by accident.

Acceptance: QA-06, QA-07, QA-15, QA-18, QA-21.

## 6. Visual and content specification

The root surface is a compact single-column list. A permanent right-hand preview, spectral glow,
decorative dashboard cards, and implementation metadata are not part of this target. Scoped files,
clipboard, snippets, and script output may use a detail pane only when it helps choose or inspect an
item. These decisions supersede the initial shell language in research.md.

Starting layout values, subject to M0 visual review: 760 × 500 logical-pixel root window; 60 px
search area; 44 px result rows; 32 px footer; 16 px horizontal content padding; 20 px app icons;
16 px input, 14 px titles, and at least 12 px supplementary text. A section label may consume list
space; the root must still show at least seven complete result rows at default text size. Clamp the
window to smaller work areas and allow scrolling; do not enforce a minimum larger than the screen.
Scoped detail mode may widen to 960 px when space permits, otherwise show details as a nested view.
Use a system font stack, restrained neutral surfaces, one selection accent, and semantic error color.

Text contrast target: 4.5:1 for ordinary text; focus/selection boundaries: 3:1 against adjacent
surfaces. Keep selection recognizable without color alone. Check both themes over bright and dark
desktop backgrounds; translucency may not sacrifice legibility. Respect reduced motion/transparency
and increased contrast; use an opaque fallback. No looping shimmer on every keystroke. Optional
transitions last 80–140 ms and never delay input or execution. Browser preview shows one clear
preview indicator; native product screens do not expose provider IDs, SQLite, IPC, or index internals.

Required reference states for M0: empty root/new user, query with mixed results, duplicate names,
no match, one failed source, action search, clipboard disabled/empty/populated, calculator result/error,
window permission, settings save/conflict, file indexing, link/snippet editor, and script running/error.
Capture light/dark, long Korean and English labels, keyboard focus, and increased text size.
Visual examples must be original. No screenshot has been approved or native appearance verified
by this document; those are explicit M0 evidence deliverables, not prerequisites to writing this plan.

## 7. Product validation and completion

Use the measurable gates in [quality-gates.md](quality-gates.md). Targets are provisional engineering
budgets, not competitor performance claims. A feature is complete only when its functional cases,
recovery paths, visual states, persistence rules, and native evidence pass on the declared platform.

After M3 gates pass, run five working days of opt-in local dogfooding and at least 100 total successful
launch/reuse/layout/file/link/snippet tasks. Record task category, duration, retries, and reason for
falling back to another tool; recording content is unnecessary. Goal: at least 95% first-attempt
completion on supported tasks, zero wrong-target actions or lost saved data, and zero unresolved
critical/high defects. These are release signals from a small sample, not population-level proof.

The user reviews whether the resulting screens and daily flows meet their taste; numerical checks
do not substitute for that judgment. A release claim must name the milestone, tested platform, and
remaining comparison gaps. Publishing, signing-account changes, and distribution remain separate
explicitly authorized work.
