# Dynamic alphabet wave and Android 16 verification

Revised on 2026-09-10 after inspecting the user's screenshot and the original
[Pinterest motion reference](https://www.pinterest.com/pin/43699058882914679/), especially its
9.7–10.7 second navigation sequence. Only the interaction was studied; the video and its artwork
are not included in the app.

## Result

The previous implementation shifted three letters by fixed offsets and placed a large preview at
screen center. The revised rail uses the actual pointer x/y coordinates:

- At rest, a quiet handle replaces the static alphabet column.
- Touch unfolds the whole alphabet into a broad curve. Letters near the thumb spread vertically,
  with a selected-letter circle placed to its left. Pulling the finger left increases the curve depth.
- A short spring opens/closes the rail. Pointer motion drives the curve directly rather than queuing
  separate per-letter animations. There is no animation loop while idle.
- Stable, unwarped hit testing prevents visual expansion from changing the selected letter underneath
  a stationary finger. The pointer remains captured through the home-to-app-list transition and can
  move left beyond its original hit area.
- Release collapses the rail while retaining the browsed list. The star returns home. Korean initials
  and Latin letters share the same geometry.

`AlphabetWave.kt` computes the curve in density-independent coordinates. The selected letter aims for
64 dp of horizontal center clearance from the pointer, constrained by the available left margin.
Neighbor expansion is monotonic and normalized into the available height to avoid clipping at either
end. This geometric clearance is verified in tests; actual thumb occlusion still needs physical use.

## Verification

- Debug app and instrumentation APKs build; lint completes with zero errors (warnings remain).
- 13 JVM tests pass, including thumb clearance, horizontal pull, ordered bilingual layout, endpoints,
  stable hit mapping, and the existing Korean search/section cases.
- Five instrumented flows pass on Android 16 / API 36 with the app locale set to Korean. They cover
  continued pointer capture, reverse drag, release/home behavior, horizontal pull with visible-bounds
  assertions, favorites/alias persistence, and swipe-up search.
- Screenshots and a short native emulator recording are in `evidence/alphabet-wave-2026-09-10/`.

The earlier Android 15 test AVD was closed and replaced with `prism-android16-edge` using Google's
Android 16 ARM64 image, 1440 × 3120 at a chosen 560 dpi, host graphics, and gesture navigation. This
is explicitly a Google Android emulator, not Samsung One UI. The desktop development server was untouched.

## Samsung One UI 8.5 path

The live [Samsung Remote Test Lab inventory](https://developer.samsung.com/remotetestlab/devices/)
was filtered for S25 Edge. It listed these real devices in Korea (Gumi) as available at inspection:

| Device | Android | One UI |
| --- | --- | --- |
| SM-S937N_KR8 | 16 | 8.5 |
| SM-S937N_KR9 | 16 | 8.5 |

Attempting to open a device produced: “Please sign in if you want to use the Remote Test Lab service.”
A separate visible browser was opened at Samsung sign-in for user handoff. No device was reserved,
no APK was uploaded, and no One UI runtime result is claimed before login and actual execution.
Availability is transient and must be checked again before reserving.

Samsung's [emulator skin guide](https://developer.samsung.com/galaxy-emulator-skin/guide.html) states
that skins change appearance/controls and do not include One UI. Installing an updated Android image
or matching panel dimensions therefore does not establish Samsung gesture, keyboard, battery, or
One UI compatibility. A connected S25 Edge running 8.5 or a logged-in RTL session is required for that.
