# Snippet abbreviation expansion

**Current build: automatic expansion is unavailable.** Final review found that AX select-then-write can race with typing in the target app and leave or overwrite a live selection. The build gate rejects activation, ignores saved opt-ins at startup, creates no monitoring thread or event tap, and does not prompt for permissions. The settings screen explains the limitation. Saving, validating, backing up, and manually copying/pasting snippet text and optional keywords remain available.

The sections below describe the gated prototype, not a shipped or native-verified expansion feature. Removing the gate requires an input-safe replacement design and native concurrent-input acceptance tests; deterministic matcher tests cannot satisfy that requirement.

Snippet expansion is an optional macOS feature, off by default. A saved snippet may have a case-sensitive keyword of 2–48 ASCII characters: its first character is `;`, `!`, `/`, or `:`, and the remaining characters are letters, numbers, `_`, `-`, `;`, `!`, `/`, or `:`. An empty keyword disables expansion for that entry. Duplicate keywords must be rejected by the library; the runtime also removes every conflicting keyword from its derived registry.

Enable **Snippet expansion** in Settings, explicitly review **Accessibility** and **Input Monitoring** permissions, and type a keyword such as `;email` followed by a space in a compatible text field. The keyword and delimiter are replaced with the saved text and the same delimiter. Return and Tab can also delimit a keyword only if the destination actually inserts their literal text without changing the target or selection. Space is the recommended delimiter.

## Integration contract

Native module: `apps/desktop/src-tauri/src/snippet_expansion.rs`.

- Call `snippet_expansion::setup(&app_handle)` once after library setup. It manages its own `SnippetExpansion` state and starts a supervisor; it does not install an event tap while disabled.
- Expose `library::snippet_entries(&AppHandle) -> Result<Vec<library::Entry>, String>`. Entries use the canonical `keyword: Option<String>`, `id`, `kind`, and `value` fields.
- Call `snippet_expansion::refresh(&app_handle)` after every successful library save, delete, import, or restore **after releasing the library lock**. Reloads are serialized and invalidate in-flight candidates before reading the library. A read failure empties the registry; old text is not retained for expansion.
- Call `snippet_expansion::shutdown(&app_handle)` on exit. It invalidates candidates, disables processing, tears down the event tap/run-loop source, and joins both threads.
- Register `snippet_expansion_status`, `snippet_expansion_configure`, and `snippet_expansion_request_permissions` in the Tauri invoke handler.
- Mount `SnippetExpansionSettings` from `apps/desktop/src/snippets/SnippetExpansionSettings.tsx`; no props are required. Editor UI is in `LibraryEntryEditor.tsx`.

IPC uses camelCase arguments/results:

```ts
snippet_expansion_status() => {
  enabled, supported, active,
  accessibilityGranted, inputMonitoringGranted,
  excludedApps: string[], registeredCount: number, error: string | null
}
snippet_expansion_configure({ enabled: boolean, excludedApps: string[] }) => status
snippet_expansion_request_permissions() => status
```

`enabled` is the user's saved preference, while `active` also requires both permissions and a live tap. Status reads never prompt. Permission requests are an explicit UI action and never enable expansion. Settings refresh on focus, native settings events, and a two-second interval while mounted. Browser preview disables native controls and never reads browser preferences to enable monitoring.

Only the enablement preference and excluded bundle IDs are persisted in `snippet-expansion-v1.json`. Snippet bodies remain canonical in the saved library. The runtime derives a bounded in-memory registry of at most 1,000 entries; it does not create another text database. Snippets containing `{date}`, `{time}`, or `{clipboard}` are skipped and retain the existing manual run flow.

## Input and replacement safety

The session event tap is **listen-only**. Its callback does no AX/AppKit work, blocking I/O, mutex locking, text logging, or keystroke injection. It hands off at most one transient key event via `try_send`. Every event has a sequence and registry generation; dropped, superseded, or stale work resets the match. A slow or unsupported app loses expansion opportunities rather than delaying typing.

The matcher stores registry indexes and a position, never an arbitrary typed string or typing history. It considers only ASCII keywords. Native AX inspection begins only while a candidate is possible. Range reads are bounded to 65 UTF-16 units, never an entire document; temporary range strings are not logged or persisted. Snippet bodies and replacement text may contain Unicode, including Korean, emoji, and line breaks.

Before matching and immediately before replacing, the worker checks permissions, Secure Event Input, input-source type/ID, foreground PID, focused application, focused window, focused element, caret progression, exclusions, current event sequence, and registry generation. It requires a standard nonsecure AX text role, a readable selection/range, writable selected text and selected range, and exact keyword-plus-delimiter text. Unknown data and failed AX calls cancel the candidate. Each AX target uses a 15 ms messaging timeout; candidates older than 200 ms are discarded.

Replacement uses the retained AX element, selects exactly the keyword and delimiter, rechecks that exact selection and focus, then writes `snippet + delimiter` through `AXSelectedText`. It never posts backspace, Cmd+V, or any synthetic keyboard event, and never changes the clipboard. If the selected-text write fails, it attempts to restore the original caret only while the operation is still current. This is not a transaction offered by macOS: native acceptance testing must verify each claimed compatible editor, including concurrent typing and focus changes. No broad editor compatibility claim follows from unit tests alone.

Command/control/option/function keys, backspace/navigation keys, mouse clicks, scrolls, autorepeat, non-ASCII events, process-generated events, sequence gaps, changed focus/caret, and changed registry invalidate candidates. Shift/caps-lock transitions are allowed for uppercase/punctuation keywords only within the supported direct layouts. Keyboard paste is invalidated by Command; mouse/menu paste resets on the click; text inserted by another API fails the expected contiguous caret/range checks. Synthetic events are rejected based on their source PID, and this module generates no keyboard events itself.

Prism, login/security processes, and known 1Password/Bitwarden/Apple Passwords bundle IDs are always excluded. User exclusions add exact bundle IDs, up to 100. Secure input or secure AX subroles always prevent expansion; an application that does not accurately expose its AX state cannot be considered supported.

Permission revocation makes status inactive immediately on its next read, invalidates pending work at its next guard, and removes the tap on the supervisor's next check (50 ms while the tap runs). A disabled/timed-out tap invalidates its candidate and is rebuilt only through the supervisor with permission checks. A tap-creation refusal is latched until an explicit settings update retries it. Turning off expansion invalidates work before saving, even if persistence fails; a save failure must be resolved before relying on that preference across restart.

## IME and compatibility boundary

macOS does not provide a universal, reliable marked-text/composition query for arbitrary applications through this event tap. This implementation therefore only accepts the **ABC** and **U.S.** direct keyboard layout IDs and the keyboard-layout source type. Korean, Japanese, Chinese, other input methods, alternate layouts, unknown sources, and composition-related non-ASCII events are skipped entirely. Switching the source must break caret/text continuity to proceed; a candidate can never be completed using an IME event.

This is a conservative input-source gate, not a claim to observe every application's custom composition engine. Editors with custom composition or incomplete/nonstandard AX support require a separate compatibility decision and should be excluded. No event tap or injected keystroke was tested against the user's documents or running apps during implementation.

## Validation

Deterministic Rust tests cover exact/case-sensitive matching, all keyword prefixes, internal punctuation, delimiters, Unicode resets and replacement offsets, guard failures, focus/paste/reset behavior, length limits, duplicate registry entries, and template/non-snippet filtering. Frontend tests cover default-off behavior, explicit permission requests, opt-in changes, revoked permission status, browser disabling, exclusion drafts, persistence errors, optional keyword editing, invalid keywords, and Unicode body preservation.

A native acceptance pass must use a disposable document explicitly authorized by the user. Verify a supported text field with ASCII and Unicode bodies, delimiter preservation, unrelated surrounding text, focus/caret changes, paste/reset, Secure Event Input, password fields, exclusions, Korean input-source switching, permission revocation, and shutdown. Tests do not demonstrate native event delivery, accurate AX support, or permission grants for a packaged build.

API references: [Apple selected-text attribute](https://developer.apple.com/documentation/applicationservices/kaxselectedtextattribute), [Apple keyboard input source identifiers](https://developer.apple.com/documentation/appkit/nstextinputcontext/keyboardinputsources), and the platform SDK definitions for Core Graphics event taps, Text Input Source Services, and AX range attributes.
