# Android distribution

Android releases share the source repository with desktop but have independent versions, tags,
signing, and assets. They never replace the GitHub `Latest` release used by the desktop updater.

## Install and update

1. Install [Obtainium](https://obtainium.imranr.dev/).
2. Open an Android release from [Releases](https://github.com/kmelon55/Prism/releases?q=android-v).
3. Tap **Add Prism Android to Obtainium** in the release notes and confirm the import.
4. Install Prism. If Android asks, allow Obtainium to install apps, then return and confirm installation.

The import contains the release-title and APK filters, so desktop versions do not appear as Android updates.
The standalone `obtainium.json` asset can also be imported through Obtainium's Import/Export page.
The source repository is currently public; no GitHub token is required. A private source needs a token
with read access, entered directly in Obtainium rather than in chat or in a public import file.

Manual registration uses `https://github.com/kmelon55/Prism`, release-title filter `^Prism Android `,
APK filter `^Prism-Android-.*\.apk$`, and **Verify latest tag** disabled. The GitHub Latest marker belongs
to desktop. The import link can be regenerated with `node scripts/android-release.mjs obtainium-link`.

## Signing and the initial debug transition

Production APKs use `app.prism.launcher` and the certificate pinned in `release-signing.json`.
Builds never generate a key or fall back to the Android debug key. Keep the original private key for
the entire lifetime of this app; losing it prevents ordinary updates outside Google Play.

The one-time `node scripts/android-release.mjs setup-signing` command stores the keystore and password
configuration in `~/.local/share/prism-android-signing/`, with directory mode 700 and file mode 600.
Back up this directory to encrypted storage outside the repository. The script refuses to replace
an existing identity or partially initialized signing directory. It reuses a complete existing setup.

`node scripts/android-release.mjs configure-github` copies signing material through stdin into four
encrypted repository secrets: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`,
and `ANDROID_KEY_PASSWORD`. It never prints their values. CI restores the keystore only in the temporary
runner directory and removes it after the job. The certificate fingerprint in Git is public, not a secret.

An earlier debug APK normally has a different signer. Android rejects an in-place update from that
APK to the production APK. Do not automatically uninstall or clear app data: first preserve or record
favorites, aliases, folders, and settings on the device. This initial migration is separate from future
production updates, which retain the package ID and signer. Device migration is not performed by CI.

## Publish a version

1. Increase both fields in `apps/android/version.properties` and update `apps/android/release-notes.md`.
2. Run `node --test scripts/android-release.test.mjs`.
3. With JDK 17 and Android SDK 35 configured, run `node scripts/android-release.mjs build`.
   The local command reads the persistent signing configuration. CI supplies the four signing environment
   variables instead. `ANDROID_KEYSTORE_PATH` must be an absolute path; partial configurations fail.
4. Commit the Android changes and push them. Tag that commit with `android-v<versionName>` and push the tag.
5. Wait for **Release Android** to succeed and check the uploaded APK and checksum manifest.

The workflow also supports manually rerunning an existing Android tag through `workflow_dispatch`.
Published releases are immutable. Retries may finish an unpublished draft; use a new version after publication.
The workflow rejects a tag/version mismatch or a version code that does not exceed all published Android
codes. APK verification checks signature, certificate fingerprint, application ID, version, and non-debuggable
status before any release is published. Release metadata records the exact source commit.

Only `android-v*` tags trigger Android releases; desktop `v*` tags keep their existing workflow.
Android publication always uses `--latest=false`, preserving the desktop updater's `latest.json` endpoint.

## Later Google Play distribution

Keep the application ID and monotonically increasing version code. When enrolling in Play App Signing,
provide this existing app signing key rather than asking Google to generate an unrelated one. Use a
separate upload key for subsequent Play uploads. This keeps the installed app signature compatible across
Obtainium and Play. Play account setup, current target SDK/policy requirements, app bundles, and testing
requirements must be completed separately before store publication.

References: [Android signing](https://developer.android.com/studio/publish/app-signing),
[Obtainium import links](https://wiki.obtainium.imranr.dev/deep_links/), and
[Obtainium GitHub filtering](https://wiki.obtainium.imranr.dev/sources/#github).
