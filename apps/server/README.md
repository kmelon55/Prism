# Prism Sync (self-hosted preview)

TanStack Start/React/TypeScript server with PostgreSQL and a Drizzle schema. The first client is the native macOS app. Android client integration and public account signup are not implemented yet.

## Run on Dokploy

Create a Docker Compose deployment using `apps/server` as its working directory and `compose.yaml` as its file. Connect a HTTPS domain to service `web`, container port 3000. Keep PostgreSQL private.

Set `POSTGRES_PASSWORD` (a URL-safe random password), `PRISM_PAIRING_SECRET` (at least 32 cryptographically random characters), and optionally `PRISM_OWNER_ID` (defaults to `personal`). Generate distinct credentials, for example with `openssl rand -hex 32`. Never commit them. Configure database backups in Dokploy and test restoration.

The database uses a named persistent volume. The SQL files in `migrations/` initialize an **empty** database only, in filename order. For existing databases, review and run pending SQL migrations explicitly; the web process does not automatically modify production schemas. `npm run migrate` applies the idempotent `0001.sql` and `0002.sql` schemas using `DATABASE_URL` from the caller's environment. Existing installations need `0002.sql` before using selective transfers. Changing database credentials in Compose does not change an existing database user's password.

If the host DNS is unreachable from Docker's default build bridge, set `PRISM_BUILD_NETWORK=host` for that deployment. This changes only the build network; runtime services retain their isolated Compose network. Leave it unset on hosts with working bridge DNS.

The container runs as the Node user. The production image includes the built application, not the source tree or environment files. Docker Compose and deployment have not been executed in the author's local validation environment because Docker is unavailable there.

## Connect Macs

Build Prism and open Settings → 기기 동기화 → 내 서버 연결. Prism Cloud is displayed as coming soon and has no login flow. “이 기기에서만 사용” stops synchronization while retaining existing connection credentials for resuming later. Enter the HTTPS origin (without a path), a device name, and the server connection code. On the first Mac, generate an encryption key and keep a private recovery copy. Use that same key on each additional Mac. The key is not recoverable from the server.

Pairing issues a separate random device token. Only its SHA-256 hash is stored on the server. Device tokens and the AES key live in the macOS Keychain, using separate development/release services. The pairing code is cleared after connection and is not saved. Connected devices can list/revoke other devices belonging to their owner. A revoked device cannot make subsequent requests; revocation does not erase content already downloaded. Anyone with the pairing code can register a device and manage that owner's devices: treat it as an administrative secret and rotate it if exposed.

This is a single-owner deployment. Owner-scoped tables and tokens prepare for future accounts, but the server does not offer public signup, login, billing, or a multi-user administration UI.

## Selective transfers

Connecting never imports or publishes settings automatically. In Settings → 기기 동기화, select feature categories and choose one of these actions:

- **Device backup:** Keep selected categories from this Mac in its own encrypted server profile. Each device can write only its own profile. Other devices belonging to the same owner can preview and import it.
- **Import once:** Choose a device profile or the common settings, preview the selected categories, then apply them. Existing local-only notes, snippets, links and command bindings remain; matching IDs are updated. This does not enable ongoing synchronization.
- **Automatic sync:** Explicitly publish selected local categories as common settings, or preview common settings and choose “가져온 뒤 자동 동기화”. Only those categories participate. Automatic synchronization propagates changes and deletions. Per-device backup and automatic sync are independent choices.

Available categories are notes, snippets, quick links, launcher shortcut, command shortcuts, theme, application icons, reduced motion, background opacity, background blur, and individual provider API keys (OpenAI, Vercel AI Gateway, OpenRouter, Groq dictation and xAI dictation). Selection is by feature/provider, not individual note. Custom-provider keys/endpoints, paths, permissions and history archives are excluded. Unsupported or conflicting shortcuts are rejected while retaining the previous bindings.

Provider keys are explicitly opt-in, encrypted before upload, and restored to the existing OS Keychain accounts. Previews show only key presence, never key text. Importing an explicitly previewed missing key removes that provider's local key. Connection tokens and encryption keys are never included in transfers. Local transfer state stores choices, revisions and SHA-256 fingerprints, not decrypted notes or provider keys.

A preview expires after five minutes and checks both source revisions and local changes before applying. Pending note edits/writes postpone transfers, and successful imports refresh the open document. Library updates validate capacity, IDs and snippet-keyword uniqueness before committing a transaction. Separate feature categories are not one global transaction: a failure reports which categories were already applied.

Automatic sync detects conflicting edits at the feature-category level and leaves them for explicit resolution by preview/import or publishing this device's value. It does not merge concurrent edits within a note. Each category is limited to 1 MB of serialized plaintext. Turning off a category stops subsequent transfers but does not erase its server copy. Unselected categories remain local.

## Clipboard and encryption

- Clipboard sending is separately opt-in and reuses the existing history capture pipeline, including excluded applications and private markers. History must be enabled for automatic sending. Explicit text composition works independently of capture.
- A bounded, memory-only queue retains only the **latest** outgoing text (up to 32 KiB). It is sent on the next sync, with the same UUID on retry. Intermediate copies are intentionally coalesced. Quitting, disabling sync, or disconnecting discards unsent text. This is not a clipboard archive or lossless delivery queue.
- Received text appears in the shared list; copying it is explicit and carries a private marker to prevent echo. Remote content never automatically replaces the system clipboard.
- The server returns the latest 50 clips, retains at most 100 per owner, and excludes clips older than 24 hours. Expired ciphertext is removed on the next clipboard read/write, not by an exact-time deletion scheduler. Backups can retain older ciphertext.
- AES-256-GCM uses a random 12-byte nonce with a 16-byte tag. Envelope = standard Base64(nonce || ciphertext || tag), matching CryptoKit's combined representation. Collection authenticated data is UTF-8 `prism-v2:{owner}:collection:{source}:{key}`, where source is `shared` or the device UUID. Collection plaintext is Base64 of the feature payload (JSON for library/shortcuts/keys, UTF-8 scalar for appearance). Clipboard authenticated data remains `prism-v1:{owner}:clip:{lowercase UUID}`. The legacy `/settings` endpoints retain the v1 setting format for compatibility; the current client uses `/collections` only. The server can see owner, device identity, setting key, timestamps, and ciphertext length, but not encrypted values. Key rotation/recovery workflows are not implemented; use one stable key per owner.

## Resource behavior

No browser needs to remain open. The Mac app must be running for automatic capture/sync. The sync module adds no clipboard polling timer: it subscribes to accepted captures. It checks the server every 60 seconds, or every 300 seconds in Low Power Mode; sleep stops the loop. Failures back off up to 15 minutes. Manual synchronization remains available. A clipboard ETag avoids transferring unchanged bodies. The server pool is limited to three database connections, and no permanent client sockets, Redis instance, or background worker is required.

These are implementation limits, not measurements of battery life or production RSS. PostgreSQL and Node both have baseline memory usage even while idle. Measure the actual deployment using Dokploy's container metrics, and evaluate macOS Energy Impact on a physical Mac. Android background clipboard access is restricted; a future client should start with explicit sharing and OS-scheduled synchronization, not an always-on foreground service.

## HTTP contract

All routes are under `/api/v1`, require `Authorization: Bearer <device token>` except health and pairing, and return JSON except an unchanged clipboard response (304). Pairing uses the server connection code as its bearer token. Bodies are limited to 100 KB, or 2.1 MB for collection routes (encrypted collection strings are capped at 2 MB). Endpoints use request-scoped owner authorization and parameterized SQL; no permissive CORS is enabled.

| Method / route | Behavior |
| --- | --- |
| `GET /health` | Database readiness; no authentication |
| `POST /pair` | `{name, platform: "mac" or "android"}` → `{id, token, owner}` |
| `GET /devices` | Active devices for the caller's owner |
| `DELETE /devices/:id` | Revoke a device for that owner |
| `GET /collections?source=shared` | Category metadata and revisions only; source can also be a device UUID |
| `GET /collections/:key?source=shared` | One encrypted category or a null record; scoped to the authenticated owner |
| `POST /collections/:key?source=shared` | `{revision, ciphertext}`; revision 0 creates, matching revision updates; stale revision returns 409; device profiles accept writes from their own device only |
| `GET /settings` | Legacy encrypted shared appearance settings and revisions |
| `POST /settings` | `{key, revision, ciphertext}`; revision 0 creates, matching revision updates; stale revision returns 409 |
| `GET /clips` | Recent encrypted text envelopes; supports `If-None-Match` |
| `POST /clips` | `{id: UUID, ciphertext}`; retries are idempotent |
| `DELETE /clips` | Clear the owner's server clipboard list |

Rate limits are bounded and per-process; configure reverse-proxy limits for an internet-facing deployment. Authentication/registration and resource-abuse policies need another review before opening a public hosted service.

## Validation

`npm ci`, `npm run build`, `npm run check`, `npm test`.

API tests use a disposable, in-memory PGlite PostgreSQL engine, not your real database. Native tests: `swift test --package-path apps/mac --filter 'PrismSyncTests|PrismLibraryTests|PrismClipboardTests'` from the repository root. Physical cross-device delivery, Keychain UI, packaged app installation, Docker deployment and battery measurements require separate verification.
