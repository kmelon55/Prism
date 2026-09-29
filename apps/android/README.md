# Prism Android

A native, offline Android home launcher built with Kotlin and Jetpack Compose. Its first slice is a
quiet favorites list, fast Korean-aware app search, an Android widget stack, and optional double-tap
screen locking. It is independent of the desktop development server and does not use a WebView.

For phone installation and ongoing updates, use the signed APK and Obtainium import link in the
[Android releases](https://github.com/kmelon55/Prism/releases?q=android-v).
See [installation and distribution](distribution.md) for setup and the initial debug-to-release transition.

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

- Settings offer independent Flat, Matte, and Liquid Glass surface modes, plus explicit Original icons
  and Themed icons choices that persist independently of the surface material.
  Matte uses opaque charcoal surfaces with cached upper-left highlights and lower-right shadows;
  panels and icon tiles appear raised, while the battery strip is recessed.
- Liquid Glass requires Android 13+ and uses an AGSL shader to refract actual background pixels
  through curved edges, with background-derived Fresnel reflections and subtle dispersion.
  A faint fixed rim defines thickness. Touch and device tilt do not change the material;
  no sensor listener, camera, or continuous animation loop is used.
  Android restricts reading the system wallpaper, so glass uses a built-in background or a photo
  copied into private app storage. The system wallpaper remains unchanged. Glass background dimming
  is stored separately from the other modes, and older Android versions fall back to Matte.
- The clock and actual battery level refresh only while home is visible. Settings also offer four
  accent colors, wallpaper dimming, and clock visibility.
- The icon theme frames real app symbols in the selected material with restrained accent colors.
  Android 13+ monochrome assets are preferred, followed by adaptive foregrounds and legacy artwork.
  Neutral uses stable per-app accents; selecting an accent color applies it to the themed symbols.
  Turning the theme off restores full-color app icons. No external icon-pack support is implied.
- Home widgets share the Prism frame, while third-party widget contents and gestures remain under
  their provider's control. Search, app/folder sheets, and settings use the same colors and shapes.
- Native HOME activity, existing wallpaper backdrop, system insets, and a clock updated only while
  visible. Korean and English copy follow the app/device locale.
- Swipe right on an app, or long-press a search/browse result, to open its actions and Android app shortcuts. Shortcut
  access requires Prism to be the default home; unavailable shortcuts show a clear empty/error state.
  Shortcut metadata loads on demand, and package shortcut changes refresh the visible catalog.
- Edit home includes Create folder. Folders open as pop-ups; long-press a folder to rename it,
  select apps, or delete it after confirmation. Folder membership and order persist on device;
  deleting a folder never removes installed apps or favorites.
- Manage favorites combines app selection, removal, and ordering in one screen. Selected apps appear
  first and have move-up/down controls; tapping a row or star never launches an app. Empty homes show
  Add apps; home editing and the search palette open the same manager. Home editing is labeled
  separately for arranging the home and its folders. Selections and order persist immediately.
- Settings → Side index chooses alphabetical or category browsing in the same edge gesture.
  Categories replace letters on the rail; there is no separate grid or drawer button. While held,
  a category's first app starts at 35% of safe content height; releasing restores the complete grouped
  list at the same position. Both edges support the gesture, and All apps opens this same list.
  Android-declared categories and conservative local hints supply the grouping; unknown apps remain
  in Other. Long-press an app and choose Change category to override its group or return to Automatic.
  Overrides and the browsing mode persist without changing favorites or home folders.
- Category browsing supports food, maps/transit, travel, shopping, finance, productivity, utilities,
  browsers, photos, video, music, health, education, reading, news, games, communication, legacy media,
  and Other. Only populated groups appear. Localized/English app names and conservative package hints
  refine Android's broad metadata; explicit game declarations remain games. Unrecognized apps fall
  back to Other, and manual choices always win. The local rules are not exhaustive store metadata.
  Recently used is a separate, automatically ordered group of up to 12 apps opened from Prism,
  including app shortcuts. These apps also remain in their normal categories. No usage-access
  permission, background usage polling, or network lookup is required.
  Food identity rules include the publisher-listed packages for
  [Baemin](https://play.google.com/store/apps/details?id=com.sampleapp) and
  [Coupang Eats](https://play.google.com/store/apps/details?id=com.coupang.mobile.eats).
- Returning to favorites brings the home surface down from above with a short eased transition.
  The edge rail remains mounted during navigation so a held browsing gesture stays continuous.
  Compose respects the Android animation duration setting; there is no permanent animation loop.
- Long-press and drag a favorite to reorder it, with a lifted surface and edge auto-scrolling.
  Order persists immediately; accessibility actions also support moving up/down and opening app actions.
- The home screen uses a plain clock panel, icon-and-label favorites, and a dark wallpaper scrim.
  There are no permanent search or app-drawer buttons on home. Long-press empty home space to enter
  editing; Done returns to the normal home screen. Settings remain available from the clock or search palette.
- Touch and hold either edge directly from home, then slide vertically to browse apps
  without opening the keyboard. Every letter keeps its vertical position throughout the gesture. Only horizontal displacement
  forms a broad curve around the finger; distant letters join the inward pull. The selected letter appears
  as a separate, unboxed preview inward from the alphabet. Pulling inward moves the arc away from
  the thumb, and release folds it back while preserving the list position. Haptics fire once per letter.
- Browsing uses smaller app labels, consistent icon spacing, and no top toolbar. The search control
  hides during index dragging. In full-list mode, the chosen group begins above the thumb so several rows are visible
  around it. Long-press empty space for settings; Back or the star returns home.
- The complete `★`, Korean, `A–Z`, and `#` index appears by default, including empty sections.
  Settings → Alphabet index can hide empty letters and switch Korean display between `가 · 나 · 다` and `ㄱ · ㄴ · ㄷ`.
  Korean apps can also merge into A–Z using the English labels bundled by their publishers; apps
  without an English label remain reachable under `#`. Displayed app names and Korean search stay
  unchanged. All index preferences persist locally.
- Index browsing can scroll the complete list or show only the selected letter’s apps. The latter
  isolates the group only while the rail is held and starts its first app at 35% of safe content
  height, independent of finger position. Releasing restores neighboring groups while preserving
  the selected app's position, then permits normal scrolling in either direction. Empty letters show
  an empty state while held and resolve to the next available group on release.
  In the full-alphabet mode, the list interpolates through gaps between installed groups.
- Swipe upward from the bottom home area or past the end of the favorites list to open
  the Prism palette. Its top input sits beside the back arrow and searches apps and local commands
  (settings, favorites editing, wallpaper, and all apps). App results appear before commands in a
  scrollable list above the keyboard. Pull downward at the top of search results or on the search header to return home and dismiss
  the keyboard. Per-letter accessibility actions remain available. Search text survives activity recreation; unmatched queries stay on the search screen.
- Installed personal-profile apps appear in a Korean-first alphabetical list with an edge index.
  Search supports case/space normalization, Hangul initials, mixed Hangul and initials, composing
  syllables, user aliases, and lower-ranked abbreviated initials such as `ㅋㅌ` for `카카오톡`.
- Search stays on device. Recently launched apps appear when search opens; no usage-access permission
  is needed. Launch history is updated only after the Android launch request succeeds.
- Package callbacks refresh metadata after app installation/removal/update. Icons load lazily into a
  bounded cache. There is no background network connection, app-list polling timer, or Internet permission.
- Settings or the Add widget search command opens a searchable picker of installed home-screen
  widget providers with their preview images (or app icons). Selecting one uses native binding and
  configuration, then adds it to a real Android widget stack, replacing the built-in clock. Existing single
  widgets migrate without rebinding. Binding uses Android consent and provider configuration; a new
  widget joins the stack only after both succeed. Cancellation keeps the entire previous stack.
  Swipe across widget pages or use the page indicators and arrows to switch. Widget taps and vertical
  scrolling stay native; the control strip is also swipeable for providers that own horizontal gestures.
  Selection and each widget's height survive restarts. Removal asks for confirmation
  and deletes only the selected widget; removing the last restores the clock. The host listens only while the activity is started.
- Optional double-tap locking applies to the clock and empty footer. A disclosure precedes opening
  Accessibility settings; the user must enable the service there. The service requests no window content,
  subscribes to no accessibility events, and invokes only the system lock action on an explicit gesture.
  Turning the feature off disables the service. Search and widgets do not depend on this permission.

## Boundaries and next slices

This is an initial launcher, not a complete Niagara replacement. Work/private profiles and Android
Private Space are deliberately excluded until profile locking, visibility and lifecycle can be
implemented together. Other follow-ups include icon packs,
notification previews, and finer appearance controls.

Android owns the secure lock screen and system recent-apps gestures. This app does not replace the
lock screen, unlock the device, or claim the same gesture animations as an OEM system launcher.
Widget behavior depends on the installed provider; unusually large widgets and foldables still need
device testing. App search correctness is separate from real Samsung/Gboard Korean IME verification.

Desktop/Android connectivity, clipboard/file transfer, notification forwarding, hosted sync, and
continuous discovery are deferred. Future protocol types must be independent of React and Tauri IPC.

Current priority is launcher quality: fast home return and app launch, Korean input/search, favorites,
alphabet gestures, widget reliability, and measured physical-device idle battery use. The deferred
[on-demand connectivity concept](connectivity-plan.md) records manual commands, clipboard/file transfer,
conditional Mac wake, and widget/Quick Settings entry points; it is not an implementation milestone yet.

## Verification

```sh
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
# Use an isolated emulator: the flow tests change this app's favorites and aliases.
ANDROID_SERIAL=EMULATOR_SERIAL ./gradlew :app:connectedDebugAndroidTest
```

Unit tests cover Korean matching, canonical Unicode, ranking, aliases, negative matches, and widget
stack selection/removal/per-widget sizing. Instrumented Compose tests exercise real installed-app
metadata, favorite/alias editing, activity recreation, HOME-intent navigation, top search placement,
app swipe actions, folder CRUD, and widget preference migration/pending-ID cancellation. Widget
binding/configuration with third-party providers and launching their shortcuts still require device checks. See [verification notes](verification.md) for the current results
and remaining device checks.

Platform references: [widget hosting](https://developer.android.com/develop/ui/views/appwidgets/host),
[home role](https://developer.android.com/reference/android/app/role/RoleManager), and
[system lock action](https://developer.android.com/reference/android/accessibilityservice/AccessibilityService#GLOBAL_ACTION_LOCK_SCREEN).

See [minimal home implementation and review](minimal-home.md) for design references, rights boundaries,
S25 Edge viewport checks, and the remaining physical-device verification.

The subsequent [dynamic alphabet wave and Android 16 verification](alphabet-wave.md) supersedes
the first static-rail presentation.

See the [September 23 launcher review](launcher-review-2026-09-23.md) for the shared home/list design,
both-edge browsing, thumb anchoring, and latest emulator checks.
