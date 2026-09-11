# Minimal home and alphabet navigation

This records the initial iteration. See [the subsequent dynamic wave revision](alphabet-wave.md)
for the current gesture and Android 16 test environment.

Implemented on 2026-09-10. This iteration replaces the dashboard-like home with a quiet, list-based
launcher and a continuous right-edge alphabet gesture. It remains Kotlin/Compose with native Android
launcher and widget APIs. No network service, timer, or persistent animation was added.

## Interaction and presentation

- A small clock/date, left-aligned text favorites, restrained neutral colors, and open space form the home.
- The persistent brand header, edit toolbar, large search control, and gesture instructions are removed.
- A bound custom widget replaces the built-in clock; its binding and preferences remain intact.
- Touch any right-side letter from home, hold, and move vertically to change sections without opening
  the keyboard. The pointer handler stays mounted when home changes to the app list. Releasing keeps
  the selected section available to tap. The star returns to favorites.
- Only the relevant alphabets appear. A mixed catalog includes Korean initials and A–Z, plus a number
  section when needed. Empty letters resolve to the next available section, or the final section.
- A small search button opens the existing Korean-aware text search. Long-press an app for favorites,
  aliases, or app details. Long-press empty home space for settings. Edit home is available from settings
  and by long-pressing the built-in clock.
- The rail offers semantic click actions for assistive navigation. Its compact letter size and line
  height remain fixed when system text is enlarged; app rows and the rest of the interface still scale.
  Actual TalkBack and Samsung gesture-conflict behavior remain device checks.

## Visual references and independent implementation

Public references inspected:

- [Pinterest: Clean and Elegant Minimal Android Home Screen](https://in.pinterest.com/pin/clean-and-elegant-minimal-android-home-screen-setup-with-niagara-launcher--414401603233325694/)
- [Pinterest: Minimalism using Niagara Launcher](https://in.pinterest.com/pin/633459503842912135/)
- [Niagara official site: list-based home and wave alphabet](https://niagaralauncher.com/)

The references informed the whitespace, small clock, vertical favorites, and direct alphabet navigation.
Reference images, wallpaper, icon packs, font files, Niagara branding, and Niagara source code are not
included in the APK. The new behavior is implemented independently in `HomeSurface.kt` using Compose.
The existing device wallpaper is displayed through a neutral scrim; fonts come from the platform.

## Rights review boundaries

This is a limited public-source review, not an infringement clearance or legal opinion.

- Niagara's [Terms of Services, section 3](https://niagaralauncher.com/terms-of-services/) grant use of
  its app and restrict copying, modification, redistribution, and reverse engineering (subject to
  mandatory-law exceptions). They do not grant a license to reuse its app or artwork in Prism.
- The Korean Copyright Commission explains the distinction between ideas and protected expression in
  its [copyright guidance](https://www.copyright.or.kr/information-materials/common-sense/knowledge-for-netizen/index.do).
  General interaction ideas can be implemented independently, while original artwork, code, and a
  sufficiently creative selection/arrangement can raise separate issues. See its
  [format and arrangement discussion](https://www.copyright.or.kr/business/counsel/auto-advice-service/practice/detail.do?categorySeq=0&categoryType=&counselSeq=3558&parCategorySeq=).
- Accordingly, this work follows the general home/gesture concept with Prism's own implementation and
  presentation. It does not claim that a pixel-identical clone would be cleared merely because its
  source was rewritten.
- A general web search did not establish a relevant Niagara patent. This is not evidence that no
  patent, registered design, trademark, or unfair-competition claim exists. Jurisdiction-specific
  searches and a review of the final presentation remain necessary for a commercial clearance.

## Device verification

The only connected device was the existing isolated `prism-launcher-test` AOSP Android 15 emulator.
Its viewport was changed to 1440 × 3120, matching the
[Galaxy S25 Edge panel resolution](https://www.samsung.com/us/smartphones/galaxy-s/galaxy-s25-edge-silver-256gb-sm-s937uzsaxaa/).
The emulator density was configured to 560 dpi for a roughly 411 dp logical width. That density is a
chosen test setting, not a measured Samsung default. This does not emulate One UI or the physical S25 Edge.

Verification passed on the final source:

- Debug APK and instrumentation APK build; Android lint (warnings remain).
- 10 JVM tests, including empty, sparse Latin, and mixed Korean/Latin alphabet coverage.
- Four installed-app interaction tests at default text size, then at 160% text size in English and
  Korean: continuous rail drag across the home/list transition, reverse drag and release, star return,
  swipe-up search, persistent favorite/Korean alias editing, and HOME-intent query reset.
- Visual review caught clipped rail letters in the mixed-alphabet case. Explicit compact line height
  and font-padding control fixed it; the final Korean/160% screenshot confirms the correction.

Build, lint, unit-test, interaction, and screenshot evidence is stored in
`evidence/minimal-home-2026-09-10/`. The standard `connectedDebugAndroidTest` runner installs/uninstalls
the target app, so it must only target an isolated test device. The final APK was installed again for
manual preview, with a small set of real system apps selected as favorites and the app locale set to
Korean. Those are emulator fixture settings; there are no synthetic apps in the shipped catalog.

Physical S25 Edge testing remains open: Samsung keyboard composition, One UI edge/back/home gestures,
120 Hz frame timing, cold/warm startup, long-label behavior with the user's apps, actual TalkBack,
widget providers, and unplugged idle battery use. Emulator/debug-build timing is not a performance or
battery claim. The desktop development server was not started, stopped, or restarted.
