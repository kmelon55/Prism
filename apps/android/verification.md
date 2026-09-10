# Android launcher verification

Verified on 2026-09-09. This is an initial native launcher slice, not a complete Niagara replacement.

## Build and automated checks

- JDK 17, Gradle 8.11.1, Android Gradle Plugin 8.9.2, Android SDK 35.
- `assembleDebug`, `assembleDebugAndroidTest`, `testDebugUnitTest`, and `lintDebug`: passed on the
  final source. [Build output](evidence/build.txt).
- Seven JVM search tests: passed. Coverage includes Hangul initials, mixed and composing syllables,
  abbreviated initials, Unicode normalization, aliases, ranking, and non-matches.
- Two instrumented Compose flows: passed on an Android 15 / API 35 ARM64 Pixel 7 emulator, including
  a final direct instrumentation run after the locale fix. [Final instrumentation output](evidence/instrumentation.txt).
  These cover installed-app selection, persistent favorites and Korean aliases, activity recreation,
  and HOME-intent search reset.
- Android lint: zero errors and 27 warnings. Warnings concern newer dependency versions, compatibility
  attributes, future app-bundle locale packaging, screen dimensions, backup metadata, unused strings,
  and KTX style suggestions. This is not a warning-free or store-release validation.
- Gradle wrapper JAR SHA-256 matches the official Gradle 8.11.1 checksum:
  `2db75c40782f5e8ba1fc278a5574bab070adccb2d21ca5a6e5ed840888448046`.

## Native emulator checks

- Chose Prism in Android's real default-home dialog. `dumpsys role` confirmed
  `android.app.role.HOME` holder `app.prism.launcher`; Home returned to Prism.
- Swiped up through the home list's empty area and observed app search with the software keyboard.
  Korean app names and the Korean/Latin edge index rendered correctly.
- Long-pressed the installed Settings app, added it to favorites, and launched it. Android's resumed
  activity was `com.android.settings/.Settings`; Home returned to Prism.
- Added the system Digital Clock widget through the Android binding-consent dialog and rendered its
  actual `AppWidgetHostView` on the home screen.
- Canceled replacement at the binding dialog: active widget ID 4 remained, no pending ID remained,
  and `dumpsys appwidget` showed exactly one widget in Prism's host.
- Approved Photo Gallery binding, reached its real provider configuration activity, then canceled:
  the previous Digital Clock widget and ID 4 remained intact.
- Enabled screen locking through Prism's disclosure and the actual Android Accessibility permission
  screens. A clock double tap produced `mWakefulness=Asleep`, `mLastSleepReason=accessibility`.
  The bound service reported `capabilities=0`, no event types, and no notification timeout.
- After the test runner terminated its process, Android marked the service disconnected. The test
  emulator's service setting was reset to restore the previously granted service for the final check.
  This was emulator fixture recovery, not an app permission bypass or an automatic user-device grant.
- With the service bound, returning from Accessibility settings preserved Prism's Korean date and app
  names. Third-party widget copy remains controlled by its provider and can follow the system locale.
- Cleared the test alias through the UI. After a process stop/relaunch, two favorites, the existing
  widget, its height, and the cleared alias remained correct. Double-tap locking was also checked on
  the final installed APK before this restart.
- The APK manifest contains no Internet, broad package-query, usage-stats, storage, notification-listener,
  or screen-reading permission. The accessibility service is optional and has no event subscriptions.

## Artifacts

- Debug APK: `app/build/outputs/apk/debug/app-debug.apk` (approximately 54 MiB, unminified debug build).
- APK SHA-256: `61015dbecba2e4cb46b5c55ef8f9b64bbd51180c9464bdd6fc489af87931a904`.
- [Korean search and keyboard](evidence/search-ko.png).
- [Korean settings](evidence/settings-ko.png).
- [Home with persisted favorites and a native widget](evidence/home-widget-ko.png).

## Remaining verification

No physical phone was connected. Samsung/Gboard Korean composition, manufacturer gesture navigation,
screen locking with configured credentials, large font sizes, landscape/foldables, work/private
profiles, and broad third-party widget compatibility remain unverified. No battery-drain or latency
numbers are claimed. Provider widgets have their own refresh behavior even though Prism adds no network
connection or background polling loop.

Tests ran in an isolated emulator. Existing desktop development servers were not started, stopped,
or restarted. No commit, push, publication, or release signing was performed.
