# On-demand desktop connectivity

Updated: 2026-09-13. Status: deferred concept; not implemented.

## Priority

Finish the Android launcher daily experience first: fast home return and app launch, Korean search
and IME handling, predictable favorites and alphabet gestures, reliable widget interaction, and low
idle battery use. Validate these on a physical device; emulator checks do not establish battery or
device interaction quality. Connectivity must not delay this work or add network activity to it.

## Later scope

Let the user explicitly control a paired Mac from Prism:

- Run desktop-approved commands or scripts, including a preset to quit a selected application.
- Send or fetch clipboard text on demand.
- Transfer selected files, including through Android's share menu.
- Attempt to wake a sleeping Mac before an operation, where the hardware and network support it.
- Expose chosen actions through launcher favorites, home widgets, and Quick Settings tiles.

## Proposed connection

Start on the same local network. The desktop app hosts a small asynchronous HTTPS server while
remote access is enabled; Android sends JSON requests only after an explicit action. Pair once with
a QR containing the endpoint, certificate fingerprint, and expiring single-use pairing code. Verify
the desktop identity and issue revocable per-device credentials. Allow only approved actions, bound
requests and execution, and deduplicate command submissions by request ID. Keep protocol types
independent of React and Tauri IPC. Do not expose the listener to the public internet.

The phone keeps no persistent connection, discovery loop, heartbeat, or periodic retry. Discovery
and connection retries are bounded and user-triggered. Long commands run on the desktop; the phone
can fetch their status later. File transfers may continue with a visible progress/cancel notification
only for the duration of the requested transfer.

## Interaction and limits

- A command button can attempt connection, send a Wake-on-LAN packet if unavailable, and retry for
  a bounded interval before reporting failure. A timeout does not prove the Mac is asleep. Waking
  must be tested on the actual Mac/network; support settings alone do not prove the HTTPS service
  becomes reachable. Waking does not unlock the Mac or promise startup from shutdown.
- Clipboard sending from a widget or Quick Settings tile opens a small focused Prism activity to
  respect Android clipboard access restrictions. File sending opens a picker or accepts shared files.
- Widgets and tiles show action results or explicitly dated last-known state; they do not poll for
  live connectivity. Users choose their actions and add tiles themselves.
- The desktop listener waits without a polling loop and does not keep the Mac awake while idle.
  Disabling remote access closes the listener. Measure its incremental resource use after implementation.
- Outside-home access and wake relaying through a router/NAS are later decisions. Continuous clipboard
  sync, notification mirroring, remote screen control, and a general remote shell are outside this slice.

References: [Mac network wake](https://support.apple.com/en-lamr/guide/remote-desktop/apd5535ee19/mac),
[Quick Settings tiles](https://developer.android.com/develop/ui/views/quicksettings-tiles),
[clipboard restrictions](https://developer.android.com/about/versions/10/privacy/changes#clipboard-data),
and [user-initiated transfers](https://developer.android.com/develop/background-work/background-tasks/uidt).
