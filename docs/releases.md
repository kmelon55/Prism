# Release Prism

Keep `/Applications/Prism.app`, the product name `Prism`, and bundle identifier
`dev.prism.desktop` stable. Do not replace or restart the installed app during a
release build. Preserve running development servers and unrelated worktree changes.

## Prepare a version

1. Update the version in root `package.json`, `apps/desktop/package.json`,
   `apps/desktop/src-tauri/tauri.conf.json`, and `apps/desktop/src-tauri/Cargo.toml`.
   Refresh the Prism package entry in `Cargo.lock`.
2. Update `docs/release-notes.md` in English. Run `pnpm typecheck`, `pnpm test`,
   `pnpm build`, `bash scripts/test-dictation-native.sh`, `node --test scripts/macos-signing.test.mjs scripts/verify-updater.test.mjs`,
   and `cargo test --locked --manifest-path apps/desktop/src-tauri/Cargo.toml`.
3. Build and verify the complete release before publishing. Commit in English,
   push `main`, then push an annotated version tag such as `v0.1.2`.
4. Create a draft GitHub release with `docs/release-notes.md`, upload every file in
   `dist/releases/v0.1.2`, verify the assets, then publish it as latest.
   Published releases are immutable; use a new version to correct mistakes.
5. Verify the public `releases/latest/download/latest.json`, archive signature,
   checksums, and both macOS architecture entries. Artifact checks do not prove an
   actual installation, restart, or permission behavior on a user's Mac.

## Signing and notarization

Automatic updates do not require Apple notarization. They require the existing
Tauri updater private key and its matching public key in `tauri.conf.json`.
The DMG is a manual installer; automatic updates use the `.app.tar.gz`, `.sig`,
and `latest.json` assets. Never replace the updater key or publish it in Git.

Prism also requires a persistent macOS code-signing certificate so updates keep
the app's identity. The updater archive signature and macOS code signature are
separate checks. Packaged builds reject missing identities and ad-hoc signing.
Never regenerate a certificate during a build, reset TCC, or weaken Keychain ACLs.
Keep certificate backups and private keys outside the repository.

### Non-notarized release from the signing Mac

Use the existing `Prism Local Signing` identity. The Tauri wrapper reads the
existing `~/Library/Application Support/Prism Signing/identity.json` configuration
and unlocks only that identity's dedicated keychain. An explicit
`APPLE_SIGNING_IDENTITY` can select an already-provisioned certificate instead.
The packaging step compares both designated requirements against the installed
app across all architectures and rejects an incompatible signer.

Set `TAURI_SIGNING_PRIVATE_KEY` to the existing updater private key path and
`TAURI_SIGNING_PRIVATE_KEY_PASSWORD` to its passphrase (empty for the current key).
Install Rust targets `aarch64-apple-darwin` and `x86_64-apple-darwin`, then run:

```sh
pnpm tauri build --target universal-apple-darwin --bundles app
node scripts/create-release-dmg.mjs
PRISM_RELEASE_MODE=local-signed PRISM_INSTALLED_APP=/Applications/Prism.app node scripts/package-release.mjs
```

This builds without controlling Finder or replacing the installed app. Packaging
verifies the updater signature against the configured public key, produces the
DMG, ZIP, updater archive and signature, feed, and SHA-256 checksums.

Clearly label the release as not notarized. New downloads may require
System Settings → Privacy & Security → Open Anyway. Moving from an older ad-hoc
build to a persistent certificate may require a one-time permission approval.
Switching from the local certificate to Developer ID is a separate identity
migration, not an interchangeable build setting.

### Notarized releases in GitHub Actions

The **Release macOS** job is opt-in through the repository variable
`MACOS_RELEASE_CI_ENABLED=true`. Leave it disabled while the persistent certificate
is held only on the signing Mac; pushing tags still permits local publication.
Do not enable it until the certificate is provisioned and the installed-app
identity migration has been addressed.

The job requires `APPLE_SIGNING_IDENTITY` (Developer ID Application name),
`APPLE_CERTIFICATE` (base64 PKCS#12), `APPLE_CERTIFICATE_PASSWORD`, `APPLE_ID`,
`APPLE_PASSWORD`, `APPLE_TEAM_ID`, and `TAURI_SIGNING_PRIVATE_KEY` secrets.
It never falls back to ad-hoc signing. `PRISM_RELEASE_MODE=notarized` additionally
requires a Developer ID signature and a valid stapled notarization ticket.
CI selects Xcode 26.3 to compile macOS 26 glass APIs while retaining macOS 14 support.
The workflow can be dispatched for an existing tag to retry an unpublished release.

### Local builds without a Developer ID certificate

Run `pnpm macos:signing:setup` once. It creates a persistent signing identity in
`~/Library/Application Support/Prism Signing`, with an encrypted signing keychain
and PKCS#12 backup. The directory is owner-only and never belongs in Git.
macOS asks the user to approve certificate trust for code signing in their user
account. It does not change system trust, HTTPS trust, Gatekeeper, or app permissions.
Repeated setup reuses the certificate; builds must never generate a replacement.
Keep a secure backup of the entire directory and do not copy its secrets into chat.

The Tauri wrapper automatically uses this local identity when no explicit identity
is set, and unlocks only its dedicated signing keychain. This identity supports non-notarized GitHub releases. Use `PRISM_RELEASE_MODE=local-signed` and `PRISM_INSTALLED_APP=/Applications/Prism.app` when packaging; the installed signer must match. A transition to Developer ID is a separate one-time
migration; local installs reject incompatible public updates instead of losing grants.

Before replacing an existing app with the same signer, run:

```sh
pnpm macos:signing:verify path/to/Prism.app /Applications/Prism.app
pnpm macos:install path/to/Prism.app
```

The verifier checks both apps against each other's designated requirements on every
architecture. For the initial ad-hoc-to-certificate migration, verify the candidate
alone and use `pnpm macos:install path/to/Prism.app --migrate-from-adhoc` after quitting
Prism. The installer backs up the previous app, checks signatures, and preserves app
data; it refuses to stop an app or replace a certificate signer. Obtain the initial macOS grants
in the newly installed app. Test two different builds signed with the same identity
before claiming that future updates preserve permissions.

## Update behavior

The native process checks GitHub 20 seconds after startup and every six hours.
Settings → General provides a manual check. Checks and installs are serialized
across windows. Tauri verifies the download signature, then Prism verifies the
extracted app's code signature and mutual compatibility with the installed app.
An ad-hoc or different signer is rejected before replacement. Available updates
appear as the first command-palette result when the search is empty, above favorites, without opening Settings or manually checking. Enter or clicking that row installs the update. The same row shows installation progress and then Restart Prism; restarting remains explicit. Failed installations keep a retry row. Unrelated searches and clipboard history retain their normal results.
Installation is manual by default. Settings → General → Install updates
automatically opts into background download and verified installation, including
an already-discovered update. This preference persists across restarts. Restarting
remains a separate action, so automatic installation does not interrupt active work.
Errors remain retryable and do not restart the app.
Development builds cannot install updates.

Chat and dictation reuse already-authorized keys and request required macOS
authorization when the user starts the feature. Settings also provide an explicit
**Allow key use** action. Status reads remain silent and fall back to metadata when
access is denied. Successfully opened
keys stay in zeroizing process memory, and no credentials move to plaintext settings.

## Cleanup

Build artifacts are disposable; application data and signing keys are not.
Remove release staging folders only when no build is using them. Never remove
Application Support, WebKit storage, Keychain items, or user scripts as build cleanup.


### Palette update row verification (2026-09-12)

117 focused App, update controls, navigation and localization tests passed, including first-row selection, Enter installation, duplicate-install suppression, explicit restart, retry/search/clipboard behavior and preserving an existing user selection during background arrival. TypeScript and signed macOS app packaging passed. An Orca embedded-browser static preview used real App components with mocked updater IPC to verify first-row display, click-to-install, the restart row and Enter-to-restart. This is renderer verification, not an actual update download or installation.

Release 0.1.7 checks: 616 frontend/core tests, 235 Rust tests (5 opt-in tests ignored), the native dictation mock suite, 5 signing/updater tests, TypeScript, and the production frontend build passed. Universal packaging verifies both macOS architectures, the existing installed signing identity, the updater archive signature, and artifact checksums.
