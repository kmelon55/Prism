# Keychain authorization and restart behavior

Prism stores AI and dictation credentials in the macOS login keychain. OpenAI
and Vercel share one in-process credential session between chat and dictation.

Settings reads use a scoped `SecKeychainSetUserInteractionAllowed(false)`
guard in addition to the SecItem authentication UI option. The legacy file-based
keychain needs this guard to avoid unsolicited password dialogs. All production
Prism Keychain reads, metadata queries, saves and deletes share one mutex. The
previous interaction policy is restored before the mutex is released, including
on failure. Keychain ACLs and passwords are not changed by this guard.

Settings first attempt a silent read to restore an already authorized key into
the zeroizing process cache. A denied read falls back to metadata and an explicit
Allow key use action. Starting dictation or sending an AI request also authorizes
the required read in place, so users do not have to detour through Settings.
Successful authorization is reused by both chat and dictation; renderer responses
contain only the masked key and status. Silent settings failures do not suppress
the next feature authorization. Canceled interactive requests are still coalesced
to avoid repeated dialogs, and errors distinguish cancellation, denied access,
unavailable interaction, and other macOS status codes.

The native dictation overlay uses the same message catalog as the settings UI.
The app synchronizes its resolved interface language at startup and on language
changes, independently of saved dictation options or successful key access.
Configuration failures are translated before display, including failures on the
first recording attempt. Stale dictation options cannot override the app language.

## Restart versus update

Always Allow can preserve access when the same installed build restarts. Allow
is not a permanent authorization. See [Apple's Keychain guidance](https://support.apple.com/en-euro/guide/mac-help/kychn002/mac).

A persistent local signing certificate is insufficient to guarantee access
across changed binaries. Apple's securityd assigns self-signed clients a CDHash
partition, while Apple developer identities can use a team partition. See
[ClientIdentification::partitionId](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/clientid.cpp).
On September 11, the installed Prism Local Signing build's CDHash differed from
the saved Vercel key's partition. Only a local signing identity was available.
Consequently, an update can still require authorization. Do not promise otherwise
or clear/broaden ACLs as a workaround. Migrating to Developer ID requires a
separate authorized signing transition and validation of the first migration.

## Verification

- Rust tests verify that silent operations disable UI and restore it after both
  success and failure; session tests cover reuse, replacement and canceled access.
- Frontend settings tests cover explicit authorization, cancellation and remounts.
- The native signing fixture was updated to distinguish same-build restart from
  changed-build access, deny unrelated identities, and fail without UI. The
  expanded fixture passes: the same build reads its key after restart; a changed
  build with the same local certificate and install path requires authorization;
  an unrelated identity is denied without UI. No signing passwords, certificates
  or ACLs were reset.
- Installed-app Cmd+Q behavior and real user authorization after restarting or
  updating remain manual checks. Publishing a release does not replace the running installed app.

## Explicit quit

The macOS application menu provides Quit Prism without a keyboard accelerator.
Cmd+Q closes the current window without quitting the background launcher. Explicit Quit and updater restart retain Tauri's normal
exit path and dictation cleanup.
