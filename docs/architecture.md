# Desktop MVP architecture

This document describes the current implementation. Intended user behavior and completion criteria
are governed by the [product specification](product-spec.md), [delivery plan](delivery-plan.md), and
[quality gates](quality-gates.md), introduced on 2026-09-06. Planned capabilities are not current
architecture or runtime proof.

```text
apps/desktop React UI
        │
        ├── @prism/command-core ── catalog/provider contract + ranking + failure isolation
        │
        ├── demo provider ───────── explicit browser-preview data
        ├── native provider ─────── bounded query results + bounded icon request queue
        │
        └── typed Tauri invoke
                  │
                  ├── Rust app index ──── SQLite catalog + in-memory search + frecency
                  ├── directory watcher ─ debounced background refresh + UI event
                  ├── guarded actions ─── index identity + path validation + usage record
                  ├── clipboard service ─ opt-in bounded in-memory text history
                  ├── window service ──── allowlisted macOS Accessibility geometry
                  ├── system service ──── platform settings allowlist + Lock Screen
                  ├── arithmetic service  bounded local expression evaluator
                  ├── web service ──────── validated HTTP(S) opener + encoded search
                  ├── script registry ──── opt-in folders + opaque execution identity
                  ├── shortcut manager ─ palette + persisted per-command bindings
                  └── Rust icon service ── resize + memory LRU + persistent cache
```

## Current responsibility boundary

`packages/command-core` is runtime-neutral. It owns the minimum stable vocabulary for a searchable
item, its actions, immutable management metadata, provider execution, cancellation, cross-provider
ranking, and partial failure reporting. A catalog materializes built-in or extension definitions into
a provider without acquiring React, Tauri, storage, or OS dependencies. Providers may attach a bounded
ranking boost, but that boost cannot make a non-matching item appear.

`apps/desktop/src` owns interaction state and presentation: query, keyboard selection,
action panel, preferences, toast feedback, accessibility semantics, and demo data. Browser preview is
an explicit runtime mode; it does not pretend that demo apps came from the operating system.

`src/interaction/navigation.ts` owns query generations, stable selection and scoped parent restoration;
`usePaletteKeyboard.ts` owns composition-aware key routing. Action-panel queries are separate from root
queries and bind actions to the invoking item. Shared provider execution emits incremental snapshots
with independent deadlines and cooperative cancellation. Root aggregation prioritizes explicit aliases
and query-correlated intents; native candidate retrieval remains bounded and needs separate native
ranking/performance evidence. Matching app aliases use an additional provider with four concurrent
lookups and a maximum of 40 candidates. See [implementation evidence](implementation-status.md).

`apps/desktop/src-tauri` owns privileged behavior. At startup it loads the last application catalog
and successful-launch statistics from SQLite into a read-optimized in-memory index. Search IPC sends
only the query and a limit; Rust normalizes and ranks locally, then returns at most 40 matches (24 for
an empty query) instead of transferring the whole catalog for every keystroke. A startup task and a
debounced directory watcher refresh the persisted catalog without making normal searches wait.

Launch/reveal commands require both the opaque catalog identity and target path. Rust checks that pair
against its current index, canonicalizes the path, and verifies it remains beneath a known application
root before spawning an OS utility. Launch frequency and recency are recorded only after that spawn
succeeds, and the next query sees the update immediately. This is a small allowlisted boundary, not a
general shell API.

Application discovery is intentionally metadata-only. It never extracts artwork while a search is
waiting. The React renderer requests an icon only when a result approaches the visible scroll area,
with visible and near-visible rows loading lazily and at most three native requests running concurrently.
Duplicate requests share one promise, in-flight entries are released on completion, and completed
successes or failures stay in a 256-entry renderer LRU so remounting a row does not restart its loading
state. Cache invalidation is broadcast across webviews. Rust then validates the application path, renders one
Retina-ready 128-by-128 PNG on a blocking worker, keeps a 256-entry LRU memory cache, and writes the
result to the application cache directory for future launches. The icon cache key includes the
application path and modification metadata so replaced application bundles do not retain stale art.

The desktop process stays alive while the palette is hidden. Rust owns the persisted cross-platform
global shortcut (`Cmd+Shift+Space` on macOS, `Ctrl+Shift+Space` elsewhere by default), while React owns
recording UI and in-window dismissal through Escape, `Cmd/Ctrl+W`, and the hide control. Replacement is
transactional: Prism registers the candidate before removing the active shortcut, and a conflict keeps
the previous shortcut working. If no startup shortcut can be registered, Prism shows a recovery window,
keeps it visible on focus loss, and exposes it in the taskbar or Dock until a shortcut works. Showing the
palette positions it on the current pointer monitor, centered horizontally with its center at one third of
the monitor work area's height. macOS resolves the pointer and visible frame in AppKit coordinates to avoid
mixed-DPI conversions between cursor and monitor APIs. The launcher shortcut and per-command shortcuts share one native handler
with constant-time id dispatch; registration and persistence updates keep the previous working binding on
conflict or write failure.

Preferences is a dedicated decorated, resizable Tauri window rather than launcher navigation. The main
palette hides when focus moves to Settings, while the Settings window remains open on blur. Appearance,
command visibility, and search aliases are stored locally and broadcast between webviews immediately.
Native shortcut state stays in versioned config files; launcher shortcut changes are broadcast so the
palette hint updates immediately. Disabling a command unregisters its command shortcut before hiding it.

Clipboard history is disabled on every fresh process until the user opts in. It polls text only, keeps at
most 100 deduplicated entries in memory, never sends them over the network, and skips obvious credentials,
tokens, JWTs, and private-key material. This deliberately does not claim the stronger concealed-item and
source-application guarantees that require platform-specific clipboard adapters. Opting out clears the
store while holding its lock, and native search/copy commands reject access while capture is disabled.

Window management is an allowlisted native service. On macOS, Prism remembers the application that was
frontmost before the palette appears, validates Accessibility trust, and changes only its focused window's
position and size through fixed layout identifiers. Before a successful mutation it stores bounded,
process-memory-only prior geometry for that exact accessibility window, allowing a one-step restore.
Other platforms return an explicit unsupported error and keep the palette open until their own adapters
are implemented.

System Settings commands send a stable Prism command ID to Rust. Rust maps that ID through a per-platform
allowlist; the renderer never supplies an executable or settings URI. Web commands similarly allow only
validated HTTP(S) addresses or a query encoded into Prism's fixed HTTPS search endpoint. The calculator
is a pure bounded parser and never evaluates JavaScript or invokes a shell.

Script Commands are opt-in and process-local. The user configures absolute folders, Rust canonicalizes
them and scans one level, and the renderer receives opaque registry IDs rather than paths. Execution uses
a direct argv boundary, a deterministic working directory, bounded output, and a timeout. This is not an
extension runtime: scripts have the user's normal process permissions, and Prism does not offer background
execution, schedules, or an inline trust bypass.

The application index opens only persisted rows on the startup path. An empty database therefore still
renders built-in commands immediately while a single background refresh discovers applications and emits
an update. macOS discovery and watching include nested application folders without descending into app
bundles. Application IDs are collision-free encodings of full path bytes, including non-ASCII paths.

The macOS window currently enables Tauri's private transparent-background API so the rounded CSS
surface has genuinely transparent outer corners. This is suitable for direct distribution but is an
explicit Mac App Store constraint; an App Store target would need a non-transparent native surface.

Daily currency conversion uses a separate intent provider and the no-argument native `get_currency_rates`
command. Rust fetches a fixed ECB table through Frankfurter, validates it, and owns its shared disk/memory
cache. Amounts and query text stay local. The source has a five-second deadline while local providers
retain their 500 ms default. See [currency conversion](currency-conversion.md) for grammar and offline rules.

## Near-term evolution

1. Make interaction state explicit: composition, navigation, stable selected IDs, focus, action lifecycle,
   and per-provider incremental results with bounded deadlines. Measure actual input/paint/native timing.
2. Introduce a native versioned user-data store before adding durable destinations and snippets. Preserve
   existing configuration during migration; keep rebuildable app/file indexes separate from user data.
3. Add authorized file roots and bounded indexing, saved destinations, snippets, symbols, and calculator
   conversions using the existing host/provider/action boundaries.
4. Complete privacy-aware clipboard capture/persistence/paste, secure-input-aware snippet expansion,
   display movement, script arguments/cancellation, and native export/import. Validate the macOS
   baseline before claiming the same quality on other desktop platforms.
5. Gate the selected-basics release candidate on the functional, visual, performance, restart/recovery,
   and daily-use evidence in quality-gates.md. Browser and static passes remain separate evidence.

Extensions and AI follow that baseline. A future catalog needs provenance, versioning, compatibility,
and approval state; installation must not grant arbitrary native access. Extension views/background
workers need restricted runtimes and host-derived identity. The host must broker filesystem, network,
clipboard, notification and streamed/cancelable AI calls without exposing secrets or unrestricted IPC.

Android remains a separate Kotlin + Jetpack Compose app under `apps/android`. Shared protocol types
may be introduced only when a real cross-device feature exists; Tauri IPC is not that protocol.
