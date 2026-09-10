# Prism Android

A native, offline Android home launcher built with Kotlin and Jetpack Compose. Its first slice is a
quiet favorites list, fast Korean-aware app search, one Android home widget, and optional double-tap
screen locking. It is independent of the desktop development server and does not use a WebView.

## Run

Open this directory in Android Studio, or use JDK 17 and an Android SDK with platform 35 and build
tools 35.0.0. Set `ANDROID_HOME` to your SDK directory, or put `sdk.dir=/absolute/sdk/path` in an
untracked `local.properties` file.

```sh
./gradlew :app:assembleDebug :app:testDebugUnitTest :app:lintDebug
adb -s DEVICE_SERIAL install -r app/build/outputs/apk/debug/app-debug.apk
```

Launch Prism and choose **Settings → Default home app** to opt in as the system home screen.
The app never changes the default launcher automatically. Android 9 (API 28) or newer is required.
The debug APK is for local evaluation; store publication and release signing are separate work.

The Gradle 8.11.1 wrapper is taken from the official Gradle repository. Its distribution checksum is
pinned in `gradle/wrapper/gradle-wrapper.properties`. Dependencies are pinned to a compatible baseline.

## First-version behavior

- Native HOME activity, existing wallpaper backdrop, system insets, and a clock updated only while
  visible. Korean and English copy follow the app/device locale.
- Favorites stay in the order chosen by the user. Long-press an app to add/remove a favorite or edit
  a search alias. The home edit button exposes move-up/move-down controls.
- Swipe up from the clock or bottom area to focus search. Swiping past the end of the favorites list
  also opens search. The search button provides an accessible equivalent.
- Installed personal-profile apps appear in a Korean-first alphabetical list with an edge index.
  Search supports case/space normalization, Hangul initials, mixed Hangul and initials, composing
  syllables, user aliases, and lower-ranked abbreviated initials such as `ㅋㅌ` for `카카오톡`.
- Search stays on device. Recently launched apps appear when search opens; no usage-access permission
  is needed. Launch history is updated only after the Android launch request succeeds.
- Package callbacks refresh metadata after app installation/removal/update. Icons load lazily into a
  bounded cache. There is no background network connection, app-list polling timer, or Internet permission.
- Settings can host one real Android widget. Binding uses Android consent, provider configuration is
  honored, cancellation keeps the old widget, and removal asks for confirmation. Widget ID and height
  survive restarts. The host listens only while the activity is started.
- Optional double-tap locking applies to the clock and empty footer. A disclosure precedes opening
  Accessibility settings; the user must enable the service there. The service requests no window content,
  subscribes to no accessibility events, and invokes only the system lock action on an explicit gesture.
  Turning the feature off disables the service. Search and widgets do not depend on this permission.

## Boundaries and next slices

This is an initial launcher, not a complete Niagara replacement. Work/private profiles and Android
Private Space are deliberately excluded until profile locking, visibility and lifecycle can be
implemented together. Other follow-ups include icon packs, folders, app shortcuts, widget stacks,
notification previews, finer appearance controls, and a draggable alphabet rail.

Android owns the secure lock screen and system recent-apps gestures. This app does not replace the
lock screen, unlock the device, or claim the same gesture animations as an OEM system launcher.
Widget behavior depends on the installed provider; unusually large widgets and foldables still need
device testing. App search correctness is separate from real Samsung/Gboard Korean IME verification.

Desktop/Android connectivity, clipboard/file transfer, notification forwarding, hosted sync, and
continuous discovery are deferred. Future protocol types must be independent of React and Tauri IPC.

## Verification

```sh
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
# Use an isolated emulator: the flow tests change this app's favorites and aliases.
ANDROID_SERIAL=EMULATOR_SERIAL ./gradlew :app:connectedDebugAndroidTest
```

Unit tests cover Korean matching, canonical Unicode, ranking, aliases, and negative matches.
Instrumented Compose tests exercise real installed-app metadata, favorite/alias editing, activity
recreation, and HOME-intent navigation. See [verification notes](verification.md) for the current results
and remaining device checks.

Platform references: [widget hosting](https://developer.android.com/develop/ui/views/appwidgets/host),
[home role](https://developer.android.com/reference/android/app/role/RoleManager), and
[system lock action](https://developer.android.com/reference/android/accessibilityservice/AccessibilityService#GLOBAL_ACTION_LOCK_SCREEN).
