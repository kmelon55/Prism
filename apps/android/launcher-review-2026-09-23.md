# Launcher interaction review — September 23, 2026

The previous home and all-apps surfaces changed background, row size and icon treatment while
browsing, and alphabet selection moved the target group to the top of the screen. The revised
surfaces share the wallpaper scrim and icon-and-label rows. Both edges open the alphabet, which
places the chosen app group near the finger's height and preserves its position on release.
The right alphabet remains visible at rest; the left gesture mirrors the inward pull. The bottom
search control has reserved space rather than overlapping the scrolling list.

The behavioral reference is Niagara's [both-edge alphabet browsing](https://help.niagaralauncher.app/article/34-tips-and-tricks).
This is a native Compose implementation using installed app icons, not imported Niagara assets or code.

## Verification

- Built the debug app and instrumentation APK with JDK 17 and Android SDK 35.
- All 13 unit tests passed. Lint completed with zero errors and 30 warnings; this is not a warning-free build.
- All six instrumented flows passed on the final APK in an isolated AOSP Android 16 emulator,
  1080×2340 at 420 dpi, Korean app locale, with system gesture navigation enabled.
- The same six flows passed at 160% font size before the final color-only adjustment. The emulator
  was restored to 100% for the final run and review screenshots.
- The new flow holds a pointer through the home/list transition on each edge, verifies the selected
  app stays near its height, and checks that release changes its position by no more than two pixels.
  Existing flows cover continued/reversed dragging, wave pull, search, HOME navigation, and saved favorites/aliases.
- Final home preview uses five real installed system apps as favorites. These were seeded only in
  the task-created emulator after the tests; the test alias was removed. The Android role chooser
  was used to select Prism, and `cmd role get-role-holders android.app.role.HOME` confirmed it.

Local review artifacts (ignored by Git): [home](evidence/launcher-review-2026-09-23/home.png),
[right-edge release](evidence/launcher-review-2026-09-23/browse-right.png),
[left-edge release](evidence/launcher-review-2026-09-23/browse-left.png),
[held wave](evidence/launcher-review-2026-09-23/wave-pulled.png), and
[final instrumentation output](evidence/launcher-review-2026-09-23/instrumentation.txt).

The task emulator remains in the visible Orca terminal `Prism Android 16 · 5554`; its foreground
ADB server is in `Prism Android adb · 5037`. No desktop development server was started or restarted.
This verifies an AOSP emulator, not a physical Samsung phone, One UI gesture behavior, haptic feel,
Samsung/Gboard Korean input, widget providers, or idle battery consumption. Those remain device checks.

## Follow-up: continuous wave and Prism palette

The alphabet now uses the available screen width instead of a 232 dp drawing region. A single,
continuous curve moves its apex 80 dp inward from the pointer until it reaches the screen edge;
the selected letter no longer receives a separate horizontal correction. The narrower wave has
a distinct moving peak. Both edges retain their stationary hit regions.

Alphabet dragging now interpolates list offsets between installed groups, including missing-letter
gaps. Fixed row metrics and a binary search for the target lazy item avoid measuring all preceding
apps during each move. Releasing retains the exact scroll position.

A swipe from the bottom home area opens the Prism palette, as do the existing search button and
favorites overscroll. Its bottom input finds apps and launcher commands: settings, favorite editing,
wallpaper selection, and all apps. AI chat opens a native draft screen with the search query carried
over. Edited drafts survive activity recreation and returning through search. As requested, this
slice implements the conversation UI only: sending remains disabled and there is no provider,
network request, fabricated response, or new Internet permission.

Verification for this follow-up:

- All 18 unit tests passed, including curve continuity, thumb clearance, sparse-section interpolation,
  and direct lazy-item targeting.
- Debug application and instrumentation APKs built; lint reported zero errors and 30 warnings.
- All nine instrumented flows passed in Korean on the existing Android 16 emulator. A separate
  English-locale run verified searching for the full Korean favorite-editing command.
- The final draft-preservation adjustment is covered by a targeted rerun of the bottom-swipe/chat flow.
- Inspected native test captures for the held curve, palette, and chat draft. These establish emulator
  layout and interaction results, not physical-device smoothness, haptics, or Samsung/Gboard IME behavior.

Artifacts are local and ignored by Git: [Korean flow results](evidence/palette-wave-2026-09-23/instrumentation-ko.txt),
[English command result](evidence/palette-wave-2026-09-23/english-command.txt),
[final chat result](evidence/palette-wave-2026-09-23/chat-draft-final.txt),
[wave](evidence/palette-wave-2026-09-23/files/wave-pulled.png),
[palette](evidence/palette-wave-2026-09-23/files/prism-search.png), and
[chat draft](evidence/palette-wave-2026-09-23/files/prism-chat-draft.png).

## Reference-driven ribbon revision

After comparing the supplied Niagara and Prism phone captures, replace the narrow magnified wave
with a long arc of uniformly spaced letters. The ribbon moves as a whole; its ends are not pinned.
Remove the circular selection badge and show the selected letter separately inward from the rail.
Use 17 sp browse/favorite labels, 36 dp icons, and consistent 24 dp icon-to-label spacing. Remove
browse top controls, hide search while dragging, and place the beginning of the selected group above
the finger. Settings remain available from home, search, and a long press on empty browsing space.

Default the index to installed sections only. Persist two settings: whether to include empty letters,
and Korean display as syllables or initials. Section keys and app search remain unchanged.

The debug app and test APK build, 22 unit tests pass, and lint reports zero errors and 37 warnings.
Instrumentation assertions were updated for the new preview labels and group anchoring, and a
settings persistence flow was added, but this revision has not yet run instrumented device tests.

The requested USB mirror uses official scrcpy 4.1 in the visible Orca terminal
`Prism phone mirror · USB`, with audio and clipboard autosync disabled. The initial connection
identified the Samsung SM-S937N running Android 16. After USB authorization, installing the
revised APK returned `Success`, and launching `app.prism.launcher/.MainActivity` returned
`Status: ok`. Live mirrored review is still blocked by USB transport disconnects during incoming
image/video data. Both the native macOS USB backend and `ADB_LIBUSB=1` reproduced the issue;
a reduced 1600 px / 4 Mbps mirror also disconnected. The ADB bridge remains in its visible Orca
terminal with wireless auto-connect disabled. A direct cable/port check is pending. No valid phone
screenshot or sustained mirrored interaction has been verified, and no personal-phone
instrumentation suite or data reset was performed.


## Final emulator follow-up

Reused `prism-review-20260923` (Android 16, 1080×2340, 420 dpi) in the visible Orca
terminal `Prism Android 16 · 5554`. Orca's embedded device attach returned
`emulator_simctl_unavailable`; native emulator input and screenshots used the explicitly
selected `emulator-5554` ADB target instead. The physical phone was not modified in this pass.

Visual review found that a sparse installed-app alphabet was nearly straight. Scale the curve
radius to the displayed ribbon span, give sparse alphabets slightly more spacing, and clamp
the separate selection preview inside the display during deep pulls. Merge the preview's text
semantics and identify palette commands independently from similarly named installed apps.

- Final debug app/test APK builds and all 23 unit tests pass.
- Lint completes with zero errors and 37 warnings.
- All ten instrumented flows pass on the final emulator APK, including both edges, continued
  and reversed dragging, continuous scrolling within a section, release position, Korean
  index settings persistence and display, search commands, and the unsent AI draft.
- Inspected held sparse/full alphabet and settings screenshots. The settings flow restores
  installed sections only and syllable labels. Removed test aliases and populated five real
  system-app favorites in this isolated review emulator after the suite.
- Native input gestures were recorded for review; this is emulator interaction evidence,
  not a physical-device frame-time or haptic measurement.

Local artifacts: [test output](evidence/ribbon-emulator-2026-09-23/instrumentation.txt),
[held curve](evidence/ribbon-emulator-2026-09-23/files/wave-pulled.png),
[full initials](evidence/ribbon-emulator-2026-09-23/files/full-index-initials.png),
[index settings](evidence/ribbon-emulator-2026-09-23/files/index-settings.png), and
[drag recording](evidence/ribbon-emulator-2026-09-23/drag.mp4).


## Correction: fixed vertical index and complete default alphabet

The moving-ribbon interpretation above was rejected: vertical movement and default letter
filtering were not requested. Supersede those behaviors with fixed vertical slots for every
letter. The pointer changes horizontal displacement only. Use the complete star, Korean, A–Z,
and number index by default, even while app metadata is loading. Hiding empty sections remains
an explicit preference. Size glyphs to fit their fixed slots without crowding the bilingual rail.

A new regression checks every displayed letter before touch, at two different drag heights,
and after release: all 42 letters stay present and their vertical centers stay exactly equal.
The geometry regression also checks fixed vertical coordinates across gesture positions and
opening animation values. This replaces the previous test that incorrectly required vertical
travel.

Final correction verification: 23 unit tests and all 11 instrumented flows pass; lint has
zero errors and 37 warnings. Installed the final APK in the existing review emulator and
left it on the home screen with the full index enabled. Inspected the corrected
[upper drag](evidence/fixed-index-2026-09-23/files/fixed-index-upper.png) and
[lower drag](evidence/fixed-index-2026-09-23/files/fixed-index-lower.png) captures.
[Test output](evidence/fixed-index-2026-09-23/instrumentation.txt) includes the fixed-slot regression.


## September 24: index grouping and browsing options

Narrow the horizontal curve radius slightly again (0.28 of rail height, with a 116 dp minimum),
while preserving fixed vertical positions and the distant-letter pull. Persist independent
settings for separate Korean sections versus English-name grouping, and continuous full-list
browsing versus selected-section-only browsing. English names come from each installed app's
English resources, loaded with catalog metadata on the IO dispatcher; no network translation or
romanization is used. Missing English names remain reachable under #. Display labels and Korean
search stay unchanged. Selected-section mode shows a clear empty state for absent groups.

Build and 27 unit tests pass. Lint reports zero errors and 39 warnings. All 12 instrumented flows
pass in the existing Korean Android 16 review emulator, including persisted controls, the actual
Gallery English resource mapping, excluding unrelated apps, empty sections, and release behavior.
Tests restore the previous index preferences; test aliases were cleared in this isolated emulator.

Artifacts: [test output](evidence/index-options-2026-09-24/instrumentation.txt),
[settings](evidence/index-options-2026-09-24/files/index-options.png), and
[English selected group](evidence/index-options-2026-09-24/files/english-selected-group.png).
