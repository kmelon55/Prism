# Release Prism

## One installed app

Use `/Applications/Prism.app` for daily work. Keep the bundle identifier
`dev.prism.desktop` and product name `Prism` stable. Do not create alternate test
identities or apps pointing to a development server. Quit the installed app before
an explicitly requested native development session; single-instance protection
prevents duplicate native launchers. Browser previews remain separate.

## Publish a version

1. Update the version in root `package.json`, `apps/desktop/package.json`,
   `apps/desktop/src-tauri/tauri.conf.json`, and the package entry in
   `apps/desktop/src-tauri/Cargo.toml`. Refresh the Cargo lockfile with `cargo check`.
2. Update `docs/release-notes.md` in English. Run `pnpm typecheck`, `pnpm test`,
   `pnpm build`, and `cargo test --locked --manifest-path apps/desktop/src-tauri/Cargo.toml`.
3. Review the diff and commit in English. Push `main`, then an annotated version tag:

   ```sh
   git tag -a v0.1.1 -m 'Release Prism 0.1.1'
   git push origin main
   git push origin v0.1.1
   ```

4. The **Release macOS** workflow builds a universal app, verifies its ad-hoc code
   signature, creates DMG and ZIP downloads, signs the updater archive, and publishes
   `latest.json` and SHA-256 checksums. It keeps the release draft until every asset
   is uploaded. A published release is immutable: fix mistakes with a new version.
5. Verify downloads and check for updates from an older installed app. A green build
   alone does not prove the installation/restart path or macOS permissions.

CI selects Xcode 26.3 explicitly to compile the macOS 26 glass APIs while retaining
the macOS 14 deployment target. The runner default Xcode 16 SDK cannot compile them.

The workflow can also be dispatched for an existing tag to retry an unpublished
release. The first release may be packaged locally with the same build and
`node scripts/package-release.mjs`, then uploaded as a complete draft before publishing.

## Signing

GitHub Actions requires the repository secret `TAURI_SIGNING_PRIVATE_KEY`.
The private key must stay outside Git. Back it up securely; losing it prevents
updates for existing installations. The corresponding public key is in the Tauri
configuration. The current key has no passphrase and is protected by file permissions
locally and encrypted GitHub repository secrets in CI.

For a local release build, set `TAURI_SIGNING_PRIVATE_KEY` to your private key path,
set `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` to an empty string, install Rust targets
`aarch64-apple-darwin` and `x86_64-apple-darwin`, and run:

```sh
pnpm tauri build --target universal-apple-darwin
node scripts/package-release.mjs
```

Updater signatures and Apple signing are independent. Current builds use ad-hoc
Apple signing and have no notarization. Do not claim Apple verification. When a
Developer ID certificate becomes available, add signing and notarization credentials
to CI, replace the ad-hoc identity, and test the upgrade and permissions behavior.

## Update behavior

The native process checks GitHub 20 seconds after startup and every six hours.
Settings → General can trigger a manual check. Checks and installations are serialized
across windows. Downloads are signature-verified by the Tauri updater before replacing
the bundle. The user installs explicitly and restarts separately to finish ongoing work.
Errors are shown in Settings and do not restart the app. Debug builds cannot install updates.

## Cleanup

Build artifacts are disposable; application data and signing keys are not.
After quitting a packaged test app, remove obsolete test bundles and release staging
folders. Remove Rust `target` output only when no Cargo/Tauri build or native development
process is using it. Keep dependencies and caches needed by an active development server.
Never delete Application Support, WebKit storage, Keychain items, or user-created scripts
as build cleanup. Back up old test application data before migrating it to the stable identity.
