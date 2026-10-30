# Release Prism

Keep `/Applications/Prism.app`, the product name `Prism`, the bundle identifier `dev.prism.desktop` and the
executable name `prism-desktop` stable: installed copies update in place only while all four match. Do not replace
or restart the installed app during a release build. Preserve running development servers and unrelated worktree
changes.

## Prepare a version

1. Update `version` in the root `package.json`; packaging reads it.
2. Write `docs/release-notes.md` in English.
3. Run `npm test` (Swift tests in `apps/mac` and the release script tests, including the signing integration test
   that needs the local signing identity).
4. Commit in English and push `main`.

## Build and publish

Packaging runs on the signing Mac, which holds the `Prism Local Signing` identity:

```sh
PRISM_INSTALLED_APP=/Applications/Prism.app node scripts/package-native-release.mjs
```

It builds a universal (Apple Silicon and Intel) release bundle, signs it with hardened runtime and
`apps/mac/Resources/Prism.entitlements`, checks its designated requirement against the installed app, and writes
the DMG, ZIP, updater archive (`Prism_<version>_universal.app.tar.gz`) and `SHA256SUMS.txt` to
`dist/native-releases/v<version>`. It never creates a certificate and never touches the installed app.

The updater archive is signed with the existing updater key. When that key is not on the signing Mac:

1. Push an annotated tag such as `v0.2.0` and create a **draft** release with `docs/release-notes.md`, uploading
   every file in `dist/native-releases/v<version>`.
2. Run the **Sign native release** workflow with that tag. It signs the archive with the
   `TAURI_SIGNING_PRIVATE_KEY` repository secret, verifies it against the public key in
   `apps/mac/Sources/PrismUpdates/Signature/Minisign.swift`, and uploads the `.sig`, `latest.json` and refreshed
   checksums to the draft.
3. Check the draft's assets, then publish it as the latest release.

With the key available locally (`TAURI_SIGNING_PRIVATE_KEY` set to the key or its path, and
`TAURI_SIGNING_PRIVATE_KEY_PASSWORD`, empty for the current key), packaging signs the archive and writes
`latest.json` itself. Published releases are immutable; use a new version to correct mistakes.

After publishing, verify the public `releases/latest/download/latest.json`, the archive signature and checksums.
Artifact checks do not prove an installation, restart or permission behavior on a user's Mac.

## Install on the signing Mac

```sh
PRISM_APP_ONLY=1 PRISM_INSTALLED_APP=/Applications/Prism.app node scripts/package-native-release.mjs
node scripts/install-macos-app.mjs    # after quitting Prism
```

The installer checks the signature, refuses an incompatible signer, keeps a backup ZIP of the previous app and
replaces `/Applications/Prism.app` atomically.

## Signing

Updates require two independent signatures:

- **Updater signature.** The Minisign key whose public half is in `Minisign.swift`. Never replace the updater key or
  publish it in Git; installed apps reject archives signed by any other key.
- **Code signature.** A persistent certificate, so updates keep the app's identity and its macOS permissions.
  Packaged builds reject missing identities and ad-hoc signing. Never regenerate the certificate during a build,
  reset TCC, or weaken Keychain access. Keep certificate backups and private keys outside the repository.

`scripts/package-native-release.mjs` reads `~/Library/Application Support/Prism Signing/identity.json` and unlocks
only that identity's dedicated keychain; `APPLE_SIGNING_IDENTITY` can select another provisioned certificate.
`node scripts/setup-local-macos-signing.mjs` creates the identity once on a new signing Mac.

Releases are not Apple notarized. Label them so; new downloads may require System Settings → Privacy & Security →
Open Anyway. Switching to a Developer ID certificate is a separate identity migration (installed copies would need
permissions granted again), not an interchangeable build setting.
