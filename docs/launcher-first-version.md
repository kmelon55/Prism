# First-version launcher improvements

The first version prioritizes everyday launcher interaction. Raycast extension compatibility,
an extension store, a public SDK, and agents are deferred.

## Settings and command configuration

Settings search retains section discovery and adds direct results for appearance, language,
clipboard retention, window options, AI model selection, and built-in command configuration.
Selecting a direct result, or pressing Enter on the search input, clears the filter, opens its
section, scrolls to the target and highlights it. Navigation never changes a setting or executes
the matched command. IME composition remains excluded from Enter handling.

The root action panel offers **Edit alias** and **Edit shortcut** for configurable built-ins and
indexed applications. These editors preserve the root query and use the existing alias conflict
validation, native shortcut registration and modifier recording lease. Registration failures stay
visible in the editor. Browser preview supports alias editing; global registration requires the
native app.

## Capture and Ask AI

**Capture and Ask AI** is a configurable built-in command. On macOS it hides Prism, opens the
system rectangular screen selector, and starts a new AI conversation with the selected image attached.
Escape cancels selection. A capture button in the chat composer also adds or replaces a draft image.
Captures remain unsent until the user enters a question and presses Send; they can be removed first.
The selected server and model must support image input. No full-screen background capture runs.

Captures are compressed to JPEG, bounded to 1600 pixels and approximately 1 MB, and retained with the
local conversation. Temporary capture files use a private directory and are removed after processing.
Drafts, retries, follow-up turns, edited-question forks and Markdown export retain image attachments.
Each conversation accepts up to four images under the existing total history storage budget.
Both OpenAI Responses and Chat Completions image input formats are supported, including custom servers.
If saving the previous conversation fails, the captured draft remains available for an explicit retry.

Plain Tab still takes the root query into an unsent full AI Chat draft; Escape restores root search.
There is no separate textual Quick AI mode. Freeform lasso selection and AI-controlled Prism settings
are deferred; settings control should use validated existing setters and offer undo when introduced.

Image protocol reference: [OpenAI images and vision](https://developers.openai.com/api/docs/guides/images-vision).

## OpenAI-compatible connection

Settings → AI → **OpenAI-compatible** accepts one custom API base URL, an optional API key, and a
model ID. Include the server's required path, for example `/v1`. The app appends `models` for catalog
lookup and `chat/completions` for inference. A missing catalog does not prevent manual model selection.
Both streaming Chat Completions and completed JSON responses use the existing bounded parser and
cancellation path. This connection is for AI chat; dictation provider options remain unchanged.

The base URL is stored in `ai-compatible-v1.json`. Keys live in the OS credential store under a
separate service and the normalized base URL; built-in provider keys are never reused. Blank key input
keeps the active key only when the base URL is unchanged. Changing addresses without entering a key
creates an unauthenticated connection. URLs containing embedded credentials, queries or fragments are
rejected. HTTP redirects are disabled. A running turn snapshots its connection, so later settings
changes do not redirect its tool results to another server.

Reading settings and model discovery do not prompt for Keychain access. **Allow key access** is an
explicit authorization action; inference can also request access when needed. Authorized keys are reused
in process memory. Neither keys nor server response bodies are included in diagnostic messages.

Custom connections do not use the built-in Perplexity web-search route. The Web control is disabled for
them; permitted local-file tools still use existing capability checks. No model price is inferred from
nonstandard catalog fields. Reported response usage is retained, and missing cost remains unknown.
No connection check invokes paid inference or downloads a local model.

Protocol reference: [OpenAI Chat Completions](https://developers.openai.com/api/reference/cli/resources/chat).

## Verification boundary

TypeScript, frontend interaction tests, native Rust tests and the production web build cover the
implementation. Added cases exercise exact setting focus, command alias persistence, shortcut rejection,
screen capture attachments without automatic inference, keyless custom connections, manual model selection after catalog
failure, credential exclusion from browser storage, URL validation and Chat Completions parsing.

Orca's embedded browser uses a self-contained local preview without starting a development server.
Its keypress command acknowledged Tab without delivering a page keydown in this session; DOM-event
verification and automated interaction tests cover keyboard routing. This does not prove a physical
keyboard, installed-app hotkeys, Keychain prompts, or inference against a user's custom server.
The installed application and existing development services were preserved.

The capture UI was inspected with a generated sample image in Orca; removing the attachment preserved
the prompt. Native screenshot selection, Screen Recording permission prompts and paid vision inference
remain unverified. The capture command has no preset global shortcut; configure one through its action
menu or Settings. Text-only models may reject image inputs.
