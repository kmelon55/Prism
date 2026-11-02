# Notch tools

The working tree adds an optional native notch panel. Run **Open Notch** from the launcher, or enable
**Settings → Notch → Show notch**. It is off by default. A launcher shortcut can be assigned to `notch:open`
through the existing command shortcut settings.

Notch settings keep their options on the left and a live preview on the right. The preview renders the real
notch for the first selected display (the main display when it is selected) against the shared model, so
pinned tools, order and a running timer match the screen. Collapsed, hover and expanded states can be switched
below it, and the preview can be clicked to try it. Its presentation is separate: opening it never opens the
on-screen panel, but tool actions in it (starting a timer, copying a clipboard entry) are real.

## Interaction

- The compact outline joins the top display edge with concave shoulders, including on displays without a
  camera cutout. It stays close to the camera width while idle and widens for an active timer or widget.
- A fixed transparent stage holds the final-size content. A Core Animation mask follows a damped spring
  for 560 ms; the window and SwiftUI layout do not resize during motion. Reversing carries current size and
  velocity. Before shrinking, visible content fades out for 60 ms; arriving content waits through the initial growth and fades
  in over 340 ms. Reduce Motion snaps immediately. There is no bottom grab handle.
- First appearance reveals from a one-point strip at the screen edge, at the destination width. Content
  fades in at its actual input coordinates; the hosting layer is never translated independently of hit testing.
  The single-row tool strip shows icons, the selected tool's name, pin and settings. A moving selection
  background and short vertical/fade transition connect pages. All six built-in tools fit without scrolling.
- Hover for 220 ms to preview the pinned tools, then click to expand. Preview departure waits 180 ms.
- Click the header or press Escape while the panel has keyboard focus to collapse. Closing under the
  pointer suppresses hover until it leaves and returns.
- Expanded tools stay open when the pointer leaves. An outside click closes them unless **Keep open** is on.
- Hover never makes the panel key. Explicit clicks in the expanded panel allow text input and editing.
- Buttons accept their full visible bounds, including blank tab and icon padding. Pointer-down cancels
  pending hover transitions, and a press/drag retains mouse input until release. Outgoing animation hosts
  cannot receive clicks; unchanged hover states do not rebuild content during an interaction.
- Check any combination of displays in settings, or choose **All displays** to include newly connected
  screens automatically. The default follows the main display. Explicit choices stay selected while offline;
  the notch never falls back onto an unchecked display. Screen names and UUIDs survive reconnection.
- Each selected display has its own open/closed state, active tab and pin. A launcher command opens the
  selected display under the pointer, falling back to the selected main display or first selected display.
  Timers, notes, clipboard and dictation use the existing shared services; timer completion sounds once.
  Unplugging or unchecking a display disposes its panel, pending hover and animation work. Reconnecting
  restores it compact, without reopening private content. Mirrored desktop frames get only one panel.
- Sleep, screen lock and inactive sessions conceal the panel and its content. Resume restores the compact
  strip, not the previously open notes or clipboard. Only a display with a physical camera cutout opts into
  full-screen auxiliary presentation. Simulated notches on external displays and older notchless MacBooks
  opt out with AppKit's `fullScreenNone`; ordinary desktop Spaces and maximized windows retain the notch.
  The policy belongs to each display and does not stop timers or disable widgets. Actual full-screen Space
  transitions still need installed-app verification; a borderless app that fills an ordinary desktop Space
  is not treated as a native macOS full-screen Space.

## Tools

The expanded panel keeps a 480-point width and a 296-point content height. Compact navigation leaves
more room for the current task. Timer digits and the primary action lead the timer page; app audio uses
three compact rows with real application icons and separate output menus. Clipboard rows show two-line
previews, Notes reserves its center for editing, and Dictation puts its recording action below the status.
Shared `NotchButtonStyle`, `NotchIconButton` and `NotchModePicker` controls keep hover, pressed, disabled
and selected states consistent. Orange marks a primary action or selection; long permission explanations
are available from the audio information button. Save and routing errors remain visible in context.

Visual references: [Vorssaint's interactive demo](https://vorssaint.com/) for quick utility navigation and
[Alcove](https://tryalcove.com/) for restrained content hierarchy. Prism keeps a horizontal tool strip and
horizontal app volume controls; no competitor code or artwork is included.

| Tool | Behavior |
| --- | --- |
| Timer | 1–180 minutes, presets, pause, resume, cancel and completion. Deadline and paused time survive restart. Sleep counts toward a running timer. Completion remains visible until dismissed; it sounds once when the enabled notch is in an active session. |
| Pomodoro | Choose Pomodoro in Timer, or search for **Start Pomodoro**. Focus for 25 minutes, rest for 5, and take a 15-minute break after four completed focus sessions. Each next session requires an explicit click. The shared countdown, stage and completed-session count survive restart; canceling clears the cycle. An active timer cannot be overwritten by the launcher command. |
| Keep Awake | Add it in Settings → Notch → Pinned tools, or search for **Keep Awake**. Prevents automatic system sleep for 25, 60 or 120 minutes, with an explicit stop action. The display may sleep; lid closure and explicit Sleep remain available. Closing the panel does not stop it. The process-owned power assertion ends at the deadline or app exit and never resumes automatically after relaunch. |
| Audio | Add it in Settings → Notch → Pinned tools. **Apps** has per-app volume (0–100%), mute and output selection; **System output** changes the default playback device. Search for **App Audio** or **Audio Output** to open the corresponding palette tool. The existing `audio-output` widget ID and pinned position are preserved. |
| Clipboard | Searches existing history and copies text, image or file entries. It respects the existing opt-in; enabling the notch does not enable clipboard capture. The full history remains one click away. |
| Quick Note | Uses the same `NotesModel`, serial autosave and SQLite notes as the main workspace. Switching tools or closing the panel does not discard a draft or a save error. |
| Dictation | Reflects the existing recording/transcription state, starts or finishes dictation, cancels ongoing work, and links to dictation settings. The compact strip shows one microphone and a nine-bar waveform driven by the existing recorder. Opening an active strip selects Dictation. It does not introduce another recorder or microphone permission flow. |

The timer remains active when the panel is hidden or its tab is removed. Cancel it explicitly to stop it.
Existing clipboard collection and dictation shortcut services retain their own settings, independently of
whether their notch widgets are visible.

New system utility tabs are available but are not inserted into an existing user's pinned arrangement.
Keep Awake has a lower compact-status priority than an active timer or recording. A completed timer takes
precedence until acknowledged, so passive utility status cannot hide completion.

## Adding a utility

Keep the service and its model in the owning feature module. `SystemFeature` owns the power assertion and
audio-output service; the notch and palette share those same models. A `FeatureContribution` can publish
searchable `PaletteProvider` commands, optional `NotchWidget` views, and settings panes. The shell collects
the widgets without the feature importing `PrismNotch`.

Give each widget a stable ID, localized title/icon, content closure, and an optional activity summary.
Use negative `activityPriority` for passive background status. Activity must read observable state and must
not start services. Only the visible content should subscribe to live hardware updates; multiple displays
share those subscriptions. Creating a feature, opening settings or rendering previews must not enable a
power assertion or change an audio route. Native modules are compiled into Prism; this is not an arbitrary
code loader or a public extension marketplace.

Orbit can remain a private, optional integration. A future connector should accept an explicitly configured
endpoint and credentials, keep credentials in Keychain, and leave Orbit responsible for task/calendar data.
Do not bundle a personal endpoint or account. A documented connector contract can be public while the Orbit
implementation stays private. Orbit connectivity, notification deduplication and mobile delivery are not
part of these utility changes.

## Per-app audio

App Audio requires macOS 14.2+ and explicit opt-in each Prism launch. Opening the palette, showing a notch,
or loading preferences never starts an audio tap. Adjustments are persisted by app bundle ID and output
device UID in `app-audio-v1.json`; default-volume/default-route apps retain their normal audio path. The
initial implementation groups nested Chromium/Electron helpers by their enclosing app bundle. Separate
system-hosted audio helpers can appear under their own identity; it does not promise tab-level routing.

For each customized app, a private Core Audio process tap feeds a private aggregate with the chosen output.
Prism does not install a driver or change the system default. The tap starts **unmuted**, while the C callback
outputs silence. Only after a real nonzero sample arrives does Prism switch to `mutedWhenTapped` and arm
the gain-controlled output. Thus denied/pending capture permission or silent/protected sources do not mute
normal app playback. The UI distinguishes waiting, applied and failed routes. Stopping capture restores
the original app path; missing devices stop the route and require a retry rather than selecting a fallback.

The callback uses lock-free gain updates and a short gain ramp, with no allocation, Swift/Objective-C calls,
logging or dispatch. Mono/stereo Float32 stream layouts and matching input/output sample rates are checked
before IO starts; extra input channels are rejected so physical microphones cannot enter the mixer. Other
formats, multichannel devices and mismatched rates show an unsupported-format message. No audio files or
network requests are created. The macOS permission description is present in both development and signed
bundles, and packaging validates it. See [Apple's Core Audio taps sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).

The app list/route health is refreshed once per second only while a mixer view is open or saved rules are
actively enabled. Closing the notch leaves explicitly enabled routes running. Disabling the mixer, sleep,
session suspension, app termination and failed setup release routes. Sleep recovery reapplies rules only
within the same enabled Prism session. After relaunch the user must enable App Audio again.

DSP and injected-session tests cover preflight silence, channel layouts, gain/mute, short buffers, device
loss, helper replacement, persistence failure, permission/setup failure and teardown. Fixture snapshots
validate layout without audio capture. Actual permission grants, audible gain/routing on physical outputs,
Bluetooth mode changes, latency and protected media still need installed-app verification.

## Implementation

`PrismNotch` depends only on `PrismKit`. Feature modules provide small views and optional activity summaries
through `NotchWidget`; the shell assembles them. Only the selected widget's view is mounted. Hiding the panel
removes its hosting content, so hidden timeline views stop updating. Countdown completion uses one deadline
timer rather than a permanent polling loop. No global keyboard hook is added.

Widgets can also supply a compact activity view. Audio amplitude is observed inside Dictation's view,
without triggering window reconciliation. Waveform timelines respect Reduce Motion.

While enabled, one set of local/global pointer monitors serves all selected displays and switches each
transparent stage to ignore mouse events outside
the currently drawn silhouette. During motion, a temporary timer refreshes this hit region; it stops when
the spring settles. Disabling the notch removes both pointer monitors and animation work.

`notch-v1.json` in the current app data directory stores display/tool preferences and timer state. The previous
single `screenID` is decoded without losing timer/tool settings, then upgraded to a persistent display UUID
when the display is available. A disconnected legacy choice remains saved until it can be matched. Writes are
atomic; failures keep the previous state and show an error. Development and snapshots use their own app data
directory. The existing backup format does not yet include this new settings file; notes and clipboard keep
their existing storage and backup behavior.

The product reference is [Vorssaint's modular Dynamic Island](https://github.com/vorssaint/vorssaint-utils/tree/a5da7633e09d0ebbf5b5607c0434ded28a239469):
compact/expanded presentation, configurable tools, hover suppression after closing, and a simulated notch on
other displays. Prism's implementation and views are original, with its existing feature contracts and data.
Vorssaint's `NotchDisplay` offers automatic, built-in, main, pointer and all-screen modes. Prism adds direct
checkbox selection, and uses independent per-display presentations instead of moving one expanded surface.

## Important notifications: integration direction

Vorssaint combines controls, music, calendars, notifications, timers, downloads, files, clipboard, notes and
agent activity in its [section model](https://github.com/vorssaint/vorssaint-utils/blob/a5da7633e09d0ebbf5b5607c0434ded28a239469/Sources/Vorssaint/Services/Notch/NotchSupport.swift).
Its [notification service](https://github.com/vorssaint/vorssaint-utils/blob/a5da7633e09d0ebbf5b5607c0434ded28a239469/Sources/Vorssaint/Services/Notch/NotchNotificationService.swift)
observes Notification Center through accessibility, gated by preferences and permission; it is not a
general system-notification subscription API. Its calendar service uses EventKit.

For Prism, use a brief compact summary followed by a detachable, larger card for selected important items.
Keep that card until acknowledgment; ordinary events should not interrupt typing or take focus. Calendar
events are the first suitable source, using explicit EventKit access and selected calendars/lead times.
Mail can use an explicit account integration. Browser and other-app banners would require a separate,
opt-in Notification Center accessibility reader with an app allowlist, deduplication and lock-screen
suppression. Reading or controlling other apps is not part of this UI repair.

These external integrations and detached alert cards are a proposed next step, not implemented behavior.
[UNUserNotificationCenter](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter)
only exposes the receiving app's notifications; calendar reading uses
[EventKit authorization](https://developer.apple.com/documentation/eventkit/ekeventstore/requestfullaccesstoevents(completion:)).

## Verification

```sh
cd apps/mac
swift test --filter 'PrismNotchTests|PrismSystemTests|PrismKitTests|PrismLibraryTests|PrismClipboardTests|PrismDictationTests'
PRISM_DATA_DIR=/tmp/prism-notch/data .build/debug/Prism --render-snapshots /tmp/prism-notch/screens \
  --notch --notch-motion --notch-widget clipboard --notch-widget notes --notch-widget dictation --pane notch
```

Tests cover presentation transitions, hover suppression, pinning, display coordinate calculations, persisted
timer recovery, pause/resume, completion, malformed settings and write failures. Hit-testing regression tests
convert unflipped parent coordinates into the flipped canvas, check compact and expanded controls, reject
transparent margins, and verify first-click acceptance. Offscreen snapshots exercise
the real SwiftUI views without starting the notch panel or its event monitors. An invisible native panel test
samples the actual presentation-layer mask while asserting unchanged window and content frames, reverses
an in-flight opening, and verifies Reduce Motion. Motion PNGs and measurements sample the same canvas,
mask and native content used by the app, over a synthetic background; they do not capture the desktop.
Snapshots cover attached camera and external-display silhouettes.
Utility previews use `--notch-utility keep-awake --notch-utility audio-output` with injected hardware fixtures.
Use `--notch-widget pomodoro --notch-widget pomodoro-finished` for the real timer views in those states.
For design review, `--notch-only <widget-id>` renders one expanded view and exits. It waits for asynchronous
content and symbol rendering to settle before capturing the invisible native view. Toolbar symbols share
AppKit template images. Audio and Keep Awake use deterministic fixtures with no real audio routes or power
assertion. Snapshot tool
navigation shows all available widgets independently of the user's pinned arrangement. Use an isolated
`PRISM_DATA_DIR` for seeded clipboard and note content. Additional single-page fixtures are `audio-system`,
`audio-disabled` and `keep-awake-active`.
AppKit can still omit some unchanged toolbar glyphs from invisible-window captures after an asynchronous
model update. The native button probe verifies their actions, but complete icon visibility needs a visible
installed-app check; the snapshots alone are not proof of that boundary.
The utility tests cover timed assertion release/failures, audio disconnection/write/read-back failures and
shared listener lifetime; pomodoro tests cover the four-session cycle, pause boundaries, persistence and
completion priority. These checks do not prove physical-device switching, actual power behavior or delivery
from an installed app.
Multi-display tests create invisible native panels with different display origins, verify independent
opening/pinning/tabs and a shared timer, then simulate unplug/reconnect, deselection, disable and session
suspension. They also check UUID persistence and migration from the old single-display preference.

`--render-snapshots <directory> --notch-interactions` additionally posts mouse-down/up events through the
running application's event loop to its own invisible test panel. `notch-interactions.json` records header,
blank tab/pin/settings padding, repeated tab switches, timer start/pause/resume/cancel, and mouse sequence
capture results. This exercises real SwiftUI button actions without injecting global input or accessing
other applications. Before the hit-area fix, the unselected tab and pin padding failed this probe.

Actual pointer/IME interaction, multi-display hot-plug, full-screen transitions, lock/unlock, idle energy use
and microphone-to-external-app delivery still need a packaged-app check. Source changes do not replace the
installed app or publish a release.
