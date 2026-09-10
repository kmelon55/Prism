# BYOK AI chat

Press **Tab** while the root search input has focus to open **AI Chat**. The search text
becomes a new, unsent draft; an empty query resumes the most recent conversation. Shift+Tab keeps
normal focus navigation. Composition keys, settings fields, clipboard search and action menus do
not trigger AI. Escape returns to the original search query and focus. The toolbar and AI command
remain available. Its command also participates in the existing Settings command shortcut controls.
The chat's connection button opens the separate **Settings → AI** window directly. Credentials
and model selection live only in that settings window; the chat never collects API keys.
Browser preview opens a separate settings tab and disables native credential/model operations.

Choose **Vercel AI Gateway**, **OpenAI**, or **OpenRouter**. Save the provider's API key,
open the selector on the right of Current model, search the API-fetched model list by model
name or creator, and click a row to save immediately. The list stays inside a dismissible popup
with provider tabs and price sorting; it no longer occupies the settings page. Successful selection
closes the popup, while failed saves keep it open. Escape returns focus to the selector button.
The current model remains visible above the connection controls, independently of catalog loading.
Model selection can be saved before adding a key.
A key creation link opens the provider's official key page. Keys can be replaced or deleted.
Existing OpenAI/OpenRouter selections are preserved; new installations start with Vercel selected
and require an explicit model choice. Switching connections in Settings does not change the chat
until a model is selected. Completed conversations retain their selected model until it is explicitly changed from the composer.
The composer model picker shows API-fetched prices and supports search, arrow navigation and Escape.
Changing a model keeps the thread and draft, persists before acknowledgement, and applies to the next
request; previous answers retain their model labels. It does not change the global default. New conversations use
the latest default selection; an unfinished empty conversation can adopt updated settings. The active model stays visible in the header and composer. Switching/deleting conversations
is disabled during a request.

Model discovery uses fixed native GET endpoints:

| Connection | Model endpoint | Authentication and filtering |
| --- | --- | --- |
| Vercel AI Gateway | `https://ai-gateway.vercel.sh/v1/models` | Public; language models with text input/output |
| OpenAI | `https://api.openai.com/v1/models` | Saved OpenAI key; text-family candidates, excluding known specialized endpoints |
| OpenRouter | `https://openrouter.ai/api/v1/models` | Public; text input/output, excluding batch variants |

Lists are fetched when opening/changing a connection and on explicit refresh. Search is local.
Each list request has a 20-second HTTP timeout and an 8 MiB body limit. Late results from a
previous connection are ignored. Errors, empty catalogs, no search matches, and saved models
missing from the current catalog are explicit; failed refresh never replaces the saved selection.
OpenAI's endpoint does not include modality or Responses compatibility metadata, so its filter is
heuristic. A listed model does not prove inference access, credits, or credential validity.

HTTP failures show the fixed request endpoint, status, recognized error type, and upstream request ID.
An unclassified 402 does not establish insufficient credit. `quota_for_entity_exceeded` is reported
as a Gateway budget rejection; an upstream `provider_error` reporting insufficient credit is kept
distinct from the Gateway account balance. Unknown error fields and raw response messages are not
displayed because they may echo credentials or conversation content. Failed responses are not
automatically retried, and loading the public model catalog does not validate the saved key.

Selection is stored atomically in the native app data directory (`ai-selection-v1.json`),
with a localStorage cache for initial rendering. Legacy browser preferences migrate once under the
native write lock. Settings changes synchronize through native notifications and a focus recheck.
The renderer only acknowledges model selection after native persistence succeeds.

Gateway input/output and OpenRouter prompt/completion prices are converted from USD per token to
USD per million tokens. Rows show both prices and support ascending input/output price sorting.
Zero remains $0; absent prices display `미제공`. Tiered/provider-variable prices carry an asterisk.
OpenAI's model listing has no prices; its settings provide a direct official pricing link instead.
Displayed rates are catalog base prices, excluding cache and other conditional charges.

Enter sends; Shift+Enter inserts a newline. Korean composition Enter never sends. Presets fill
an editable prompt for summarization, Korean/English translation, or rewriting; they do not
send automatically. Questions and answers can be copied; copy controls appear on hover or keyboard focus. Escape returns to commands, retaining the conversation
and reopening resumes the AI workspace. The sidebar searches titles, models, drafts, and message bodies locally.
New conversation (Command/Ctrl+N) starts a separate thread and clears the history filter.
Command/Ctrl+1 through 9 selects the corresponding visible sidebar conversation, preserving the
outgoing draft before switching. Composition, repeat keys, modal confirmations, and in-flight
requests cannot trigger accidental switches. Shortcuts remain available without persistent key hints.

Delete from the header or a sidebar row. Header controls are outside the native drag region. A focused
confirmation dialog identifies the target and keeps it fixed while deletion runs. Failed deletion
keeps the thread and offers a deletion-specific retry; it does not retry saving instead. Saves and
deletes share one queue, and deleted IDs cannot be recreated by delayed autosave. A fresh unsaved draft
can also be discarded. Deleting another row preserves the current thread and draft.

The composer grows with its text up to 180 px. Incoming answers preserve the reading position when
the user has scrolled up; a contextual Latest message control returns to the bottom. User messages
align right, and assistant responses keep the full reading column. The launcher status strip,
Actions label, and persistent arrow/Command/Tab hints are removed. Secondary actions remain
available from the toolbar icon and Command/Ctrl+K.
The chat renders Markdown lists, tables and code blocks. Raw HTML is skipped; remote images are
shown as labels; HTTP(S) links open externally only after a click.

The palette animates from 760×500 to up to 1080×760 points with a fast start and soft
settlement: cubic-bezier(.22, 1, .36, 1), 420 ms to expand and 320 ms to collapse. Native
frames are applied on the main thread; a generation counter cancels interrupted transitions and
reversals start from the current frame. Dimensions are clamped to the display work area.
The sidebar, header, messages and composer enter with short staggered fades and translations.
Chat exits for 120 ms before the palette returns. Motion for React crossfades explicit conversation
switches; departing panels are inert and hidden from assistive technology. Initial history/draft
hydration does not create a duplicate outgoing panel. Both system and app reduced-motion
preferences bypass transitions. Browser preview uses the same timing curve for CSS resizing. Expanded chat remains available when focus moves to another app and stops floating
above other windows. Returning to search restores the palette size and floating behavior.

Conversations and drafts are stored in the native app data directory in `ai-conversations.sqlite3`.
This is local SQLite storage, not encrypted conversation storage. The database is owner-readable
and writable on Unix; API keys remain in Keychain and are never part of conversation preferences.
Storage allows 100 conversations and 32 MiB of serialized content. The renderer serializes writes
and saves an unanswered question before sending, so a failed request remains an editable draft.
Completed turns are saved together. Storage failures remain visible and prevent an unsaved question
from being sent; retrying storage or sending is always explicit.

## Authority and data flow

- Keys are saved per provider using macOS Keychain APIs. The renderer supplies a key only for
  saving; no command returns the full value. Save acknowledges successful native Keychain writes without a second password read.
  The settings show a masked suffix (last four characters for keys at least 12 bytes)
  with explicit Change/Delete actions. Catalog refresh never resets credential status or edits.
  Only non-secret provider/model/name preferences enter localStorage and the native settings file.
- The native request uses provider-specific fixed HTTPS endpoints, disables redirects, and reads the selected key
  in Rust. No arbitrary endpoint, clipboard capture, or selected-text capture. Tools are explicitly scoped below.
- OpenAI uses Responses with `store: false`; OpenRouter and Vercel AI Gateway use Chat Completions. The complete
  current conversation is sent to the selected provider on each explicit send. Provider retention
  and billing policies still apply. Saving a key is not a credential verification request.
- One native request runs at a time. Requests have a 10-second connection timeout and 120-second
  HTTP timeout and a four-minute total turn deadline, with a 1 MiB response bound. Inputs are limited to 40 messages, 32,000 UTF-8 bytes
  per message, and 128,000 bytes total; output/ reasoning is configurable at 4,096, 16,384 (default), or 32,768 tokens.
  Cached public catalog metadata caps output to the advertised model maximum when available.
  Catalog metadata also rejects known non-tool models before an inference request with tools enabled.
- Stop cancels the local HTTP future. A provider may charge for work already performed.
  Failed/canceled requests restore the draft and remove the pending turn so retry remains explicit.
- HTTP failures are classified from bounded provider metadata into credential, credit, rate-limit,
  context-length, unavailable-model, request-format, timeout and upstream-server failures. The UI
  shows a recovery action and expandable provider/model/HTTP status/request ID diagnostics. Raw
  provider messages, keys and echoed prompts are not exposed. There is no automatic paid retry
  or model fallback.

## Current limits and verification

Browser preview shows setup but disables credential saving and requests. Secure credential storage
is currently macOS-only. There is no image/PDF input,
or direct Anthropic/Gemini integration in this slice. Model access depends on the selected connection and account.

Frontend interaction tests mock native IPC and cover separate-window navigation, model search and
selection and restore from native state after clearing the browser cache, cross-window changes,
key-save recovery, failed persistence, price display/sorting, and stale model responses. Rust tests
cover request validation, provider routing, model filtering/prices, native file persistence, and
response parsing. An isolated Keychain fixture test covers save/read/replace/delete without using
user credentials. An explicit read-only
network test has verified Vercel and OpenRouter model discovery; it does not access keys or generate
messages. The current public catalogs returned 251 Gateway text models (248 with both prices)
and 361 OpenRouter text models (356 with both prices). The isolated Keychain roundtrip passed.
Authenticated OpenAI discovery and live provider responses remain unverified. Orca browser UI
checks used real public catalog data with mocked credential/persistence IPC; they do not prove
packaged native interaction. Native UI automation was unavailable due to macOS Accessibility access.
The workspace changes passed 150 frontend tests and native tests covering HTTP classification,
SQLite persistence, display bounds, easing and interrupted-frame interpolation. Frontend tests
also cover canceled close timers, reduced motion, outgoing-panel inertness and composer focus. Orca UI fixtures covered Markdown, two-session history,
failed-request draft recovery and a compact 760×520 layout. These checks do not prove a live
provider response or native frame-by-frame animation. The previous generic provider error did
not record enough detail to establish its exact cause; the selected Qwen model was present in
the public Gateway catalog and supported the request's `max_tokens` parameter. No paid inference
was run automatically. The existing development server was preserved.

API contracts checked against [OpenAI text generation](https://developers.openai.com/api/docs/guides/text),
[OpenRouter API reference](https://openrouter.ai/docs/api_reference/overview), and
[Security Framework password APIs](https://docs.rs/security-framework/3.7.0/security_framework/passwords/index.html).

Additional API contracts: [Vercel model discovery](https://vercel.com/docs/ai-gateway/models-and-providers),
[Vercel Chat Completions](https://vercel.com/docs/ai-gateway/sdks-and-apis/openai-chat-completions),
and [OpenAI model listing](https://developers.openai.com/api/reference/resources/models/methods/list).


Interaction research used [Asyar's official feature overview](https://asyar.org/) and
[its public AI-agent documentation](https://github.com/Xoshbin/asyar#ai-agents) for behavioral
reference only: quick context entry and persistent threads. Prism's layout, contracts and code
were implemented independently. Native frame updates use
[Apple's window-frame API](https://developer.apple.com/documentation/appkit/nswindow/setframe(_:display:)).
Conversation presence follows [Motion's React lifecycle](https://motion.dev/docs/react-animate-presence).


## Composer tools and local access

Settings → AI now includes Web search, Local file reading, permitted folders, and the output/reasoning
budget. Both tool permissions start off. After granting a capability, enable the corresponding Web or
Files control in the composer for requests that should use it. Tool switches remain visibly enabled
until switched off; disabling a permission in Settings disables its composer control as well.
Model selection and the send/stop control replace the persistent saved-status text; storage failures
remain visible and continue to block sending.

The native host implements a bounded tool loop: at most five model rounds and six local/custom tool
calls per question. Vercel and OpenRouter expose a `web_search` function backed by a separate
`perplexity/sonar` call using the same connection key (at most two searches per question). This is a
search-model request, not the Gateway AI SDK's Perplexity Search tool. Only the generated search
query enters that request; the model is instructed not to include private content. Queries are sent
to the search service and search/inference fees are additional. OpenAI uses its provider-executed
Responses web-search tool. Models decide when to call offered tools; enabling a tool does not prove
that it ran. Web citation URLs and successfully read local file names are appended to final answers.

Folder grants originate only in a native folder chooser; renderer requests cannot submit paths to
create grants. The renderer may revoke a grant or change tool permission flags. Permissions and
folder grants persist separately in `ai-tools-v1.json` and are rechecked during each native turn.
Changing/revoking grants stops subsequent model requests for an active file-enabled turn.
The model sees granted folder IDs/names, can list immediate children and read UTF-8 text/code files
up to 32 KB. Lists are bounded to 100 results and 1,000 inspected entries. Hidden paths, credential/key
file formats, generated/dependency folders, parent traversal, symlinks, hard links, and nonregular
files are excluded. Unix file reads walk descriptors with `O_NOFOLLOW` on every component; directory
listing uses descriptor-based enumeration. These are read-only tools with no shell or file mutation.
Ordinary text files can still contain sensitive content; granting a folder permits relevant text to be
sent to the selected AI provider. This is not an offline model or a universal secret detector.

A GLM 5.3 Flash public catalog check identified `zai/glm-5.3-flash` with tool support and reasoning.
The old client offered no tools and fixed output at 4,096 tokens. Chat Completions `finish_reason:length`
now preserves partial text with a truncation notice, or explains reasoning-budget exhaustion when
there is no final text. This does not establish the cause of an earlier unrecorded provider failure.

New fixture coverage includes composer model persistence/failure, tool toggles and native folder
picker settings, local-file boundary enforcement, permission revocation, and the full read/search/
follow-up tool loop using mock provider responses and real isolated temporary files. No paid model
or search request was executed during verification. Native folder-chooser interaction and live GLM
responses remain unverified. Orca browser fixtures verified the composer picker and send controls;
these fixtures do not read the user's files or credentials.

Contracts: [Gateway function calling](https://vercel.com/docs/ai-gateway/sdks-and-apis/openai-chat-completions/tool-calling),
[Sonar search model](https://vercel.com/ai-gateway/models/sonar),
[OpenAI web search](https://developers.openai.com/api/docs/guides/tools-web-search),
and [GLM 5.3 Flash](https://vercel.com/ai-gateway/models/glm-5.3-flash/api).


## Keychain authorization during local development

The local app currently uses ad-hoc signing. Its designated identity changes with native rebuilds,
so macOS may request approval for a newly built executable even after an older build was allowed.
The Vite development server and React hot reload do not themselves change that native signature.
A stable signing certificate is required to retain identity across builds; no valid local code-signing
identity was available during this check. Keychain access controls remain unchanged.

Status and focus checks now query attributes only, with password data disabled and authenticated
items skipped. They never call the interactive password reader. Saved but not yet opened keys are
shown as stored in Keychain; a masked suffix is shown once available in the native session. An explicit
"Allow key use" action, or the first explicit chat request, may request macOS approval. OpenAI catalog
loading uses only a key already opened in the current native session and cannot prompt by itself.
Successful reads are serialized and retained in process memory with zeroizing buffers, shared across
settings, chat rounds, and search calls. Replacement/deletion updates or clears that session value;
app exit releases it. Canceled access is briefly coalesced so queued callers do not open another dialog.
Successful saves cache the submitted key after the OS write succeeds, avoiding a second read prompt.
Nothing writes plaintext credentials to browser storage or a preferences file.

Tests cover repeated cached reads, key replacement/deletion, cancellation coalescing, and the absence
of automatic unlock/catalog calls on initial render and focus. Actual macOS authorization-dialog
behavior remains unverified by automation. See Apple's
[code signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).


## 2026-09-08 conversation interaction verification

The current frontend passes 165 desktop and 22 command-core tests (187 total), type checking, and
production build. Added regression scenarios cover numbered switching/draft preservation, body
search, composition/repeat/modal boundaries, deletion failure/retry, noncurrent deletion, unsaved
draft deletion, in-flight autosave/deletion ordering, and reading-position preservation.

Orca browser checks used the existing port 1420 server and an isolated in-memory IPC fixture.
They verified pointer deletion and sidebar removal, Markdown and composer layout in dark and light
views including a 760×520 shell, and numbered switching with a synthetic DOM keyboard event.
The browser automation's Meta+2 command emitted no page keydown event, so it is not native shortcut
proof. The running macOS app's pointer/keyboard behavior and actual SQLite deletion remain unverified
in this follow-up; no app/server restart, user-conversation deletion, or paid inference was performed.


## Streaming and conversation editing follow-up

Answers now arrive through a request-scoped Tauri channel. The native SSE parser handles split UTF-8,
CRLF and provider terminal events. OpenAI uses Responses text deltas and the completed response;
Gateway/OpenRouter reconstruct Chat Completions content, split tool arguments and reasoning blocks.
Tool-loop requests preserve these fields; secondary search-model calls remain JSON. A successful
JSON response is accepted as fallback. Wire/event/answer sizes remain bounded, and an interrupted
transport cannot be saved as a completed answer. Stop and stale callbacks cannot overwrite a new
request. Partial text remains visible in the current mounted conversation after failure; only the
question draft is durable until completion. Reopening does not restore an interrupted partial answer.

Question editing and regeneration fork the conversation at the selected user turn, preserving the
original and later messages there. Edit opens an unsent draft. Regenerate explicitly sends that draft
in the new conversation. The source and fork must be persisted before switching or invoking a model.
Concurrent conversation requests remain unsupported.

The header can rename, pin and export a conversation. Pinning sorts before recency and therefore
changes numbered sidebar navigation order. Rename/pin acknowledge only after native persistence;
failed rename leaves the input editable. Markdown export uses a native save dialog on desktop and a
browser download in preview. It includes messages and an unsent draft, without credentials. Individual
code blocks have a copy button. Persistent keyboard hints remain removed.

Fixture tests cover incremental text/final persistence, stale channel delivery, source-preserving edits
and regeneration, pin/rename across remount, failed rename and export without inference. A browser
fixture verified an intermediate text state and the completed answer. Native provider requests, save
dialogs and actual paste were not exercised. The prior test counts above describe earlier checkpoints;
see [implementation evidence](implementation-status.md) for this follow-up's full check results.

Contracts: [OpenAI streaming](https://developers.openai.com/api/docs/guides/streaming-responses),
[Gateway Chat Completions](https://vercel.com/docs/ai-gateway/sdks-and-apis/openai-chat-completions),
[OpenRouter streaming](https://openrouter.ai/docs/api_reference/streaming), and
[OpenRouter reasoning details](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens).


## Language and local file activation

Settings → General controls English, Korean or system language across the palette and AI workspace.
Conversation content and user names remain unchanged. The Files composer control refreshes permissions
and opens a folder picker when needed; a successful grant also enables reading. Canceling preserves
the off state. Settings and the composer receive native permission-change notifications. See
[language and search](language-and-search.md) for the full behavior and verification boundaries.
