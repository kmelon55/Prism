# Prism Android 0.1.0

The first signed Android distribution for installation and updates through Obtainium.

- Native home launcher with Korean-aware app search and a local command palette.
- Favorites, drag ordering, folders, app shortcuts, and configurable alphabet browsing.
- Android widget stacks with independent sizes and shared home appearance settings.
- Offline operation with no Internet permission in the launcher.

Download `Prism-Android-0.1.0.apk`, or use the Obtainium link below to import the Android-only update configuration.
Android 9 or newer is required. This release does not update the desktop app.

An existing developer/debug installation may use a different signing certificate and cannot be overwritten
by this release. Do not uninstall it without first deciding how to preserve its favorites, folders, and
settings. Subsequent signed releases use the same release key and update in place.

Validation covers unit tests, Android lint, release compilation, application ID/version, and APK signing.
It does not establish physical-device gesture, widget-provider, battery, or Play Store acceptance results.
