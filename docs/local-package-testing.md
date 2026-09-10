# Local macOS package testing

Updated: 2026-09-10.

## Opening light

General > Animations > Opening light animation controls a 1.5-second clockwise
sweep from the bottom of the palette to the pointer. It defaults to enabled for
older preferences. Disabling it preserves ordinary pointer lighting. Prism's
Animations setting and the system Reduce Motion preference suppress movement.
The setting persists across windows and app restarts. Expanded workspaces and
the separate Settings window do not start the palette sweep.

The white core's 45-degree gradient offset is accounted for, so six o'clock is
the visible highlight position. A moving target remains clockwise and direct
pointer tracking resumes after the sweep. Native hidden-window responses and
page visibility cancel work and arm the next arrival; ordinary focus changes
do not replay it. Rendering and input never wait for animation completion.

## Current release workflow

The separate Prism Test package and development-server-backed local app were retired.
Use the single installed `/Applications/Prism.app` and the [release workflow](releases.md).
The verification below records the earlier test package and is historical evidence,
not acceptance evidence for the current release.

## Verification

- Frontend/core suite: 462 desktop and 36 command-core tests pass.
- Opening-light/settings subset: 11 tests pass, including clockwise travel,
  moving targets, duration, cleanup, reduced motion, hide/show and persistence.
- Native presentation state: three Rust tests pass.
- TypeScript and production web bundle build pass. The existing large-chunk
  warning remains.
- The packaged app visibly loads `tauri://localhost`; Settings uses
  `tauri://localhost/index.html?window=settings`.
- Native UI checks: launch, search input, `12 * 3` displaying `36`, Escape clearing
  the query, Settings navigation, opening-light switch off, quit/relaunch,
  persisted off state, and restoring the switch to on.
- The app's ad-hoc signature verifies with `codesign --verify --deep --strict`.
- Existing Vite PID 61915 is preserved. Native source edits can trigger the
  existing Tauri watcher; no development server was started, stopped or restarted.

The 1.5-second trajectory is proven with deterministic frame tests, not a native
high-frame-rate recording. Physical Korean IME, external-app paste, microphone
permissions, notarization and release performance are outside this smoke test.
