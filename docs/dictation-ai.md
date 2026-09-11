# Dictation refinement and AI usage

Dictation settings offer two side-by-side enhancements: **Refine speech** and **Structure prompt**. Enable either, both, or neither. Each retains its own text model and editable processing prompt. Each switch changes only its own enhancement without discarding either profile. Models are independent of AI Chat and reuse the existing provider keys. Legacy shared-model settings migrate once into both profiles.

- Ordinary dictation with both enhancements off transcribes and delivers directly.
- Refinement adds one text-only request automatically after transcription.
- The ordinary shortcut follows the speech refinement setting: cleaned text when enabled, original transcription otherwise. The separate prompt shortcut structures and pastes the result, even when default delivery is copy.
- The prompt shortcut can start a recording or finish an ordinary recording. When both enhancements are enabled, prompt formatting receives the original transcription directly and makes one AI request; cleanup is not chained first. Its second invocation structures the result; finishing with the ordinary shortcut preserves the original. Cleanup never runs first.
- Both ordinary and prompt double-modifier shortcuts retain priority over single-modifier recording actions.
- Local STT model and executable paths are selected inside **Change model → Local**. Settings dropdowns use the same custom keyboard-accessible menu in browser and native WebView.
- Processing is instructed to preserve intent, negation, uncertainty, names and constraints. It must not answer the dictated prompt or add requirements. These are model instructions, not a guarantee of semantic fidelity.
- The native overlay distinguishes transcription from processing and dismisses after successful delivery. Refinement failures still show a brief warning. Tokens and cost are available only in Settings → AI. **Copy original text** retains access to the last unrefined transcript in memory.
- Processing has a 20-second deadline and an independent native recovery timer. Missing configuration, errors, empty/truncated results and timeouts fall back to the original transcript. Cancellation prevents late results from reaching the target app.
- Local STT plus remote processing sends the transcript to the selected text provider; the settings disclose this before enabling refinement. No screen or surrounding document context is collected.

## Usage

Usage is collected at the bottom of AI settings. Monthly cost, token and request totals sit above an interactive daily graph. Switch between cost, tokens and requests, and group breakdown bars by feature, model or provider. Expand details for every feature/model/provider tuple, all-time totals and the latest 12 requests. Both graphs aggregate the full monthly ledger, independent of the recent-request display limit. Month boundaries follow the device's local time. The ledger retains older records; the 12-row limit is only for display.

Usage metadata is saved in `ai-usage-v1.sqlite` under the app data directory. It includes provider, model, feature, timestamp, request status, input/output tokens and USD cost. It does not store prompts, transcripts, audio, API keys or response bodies. The ledger starts with this feature; it does not import earlier provider account usage.

A row is inserted before each text request and at the start of STT. Missing final responses remain **Unconfirmed** with unknown cost, including interrupted requests that may have been billed. Tool/search model calls within AI Chat are recorded individually. Local inference has zero provider cost; remote STT costs remain unknown when not supplied by the response.

Cost precedence:

1. Provider-reported `usage.cost` or Gateway cost metadata.
2. For text requests only, complete input/output usage multiplied by a fresh model catalog's base prices. Marked `≈`; cache pricing, routing, tiering and external tool charges can differ.
3. Otherwise **Cost unavailable**, never zero. Totals with missing costs show `+ ?`.

The request transport asks Chat Completions streams for the final usage chunk. The OpenAI Responses path retains the final response's usage. The display describes locally observed usage, not a reconciled invoice or account balance.

Provider references checked during implementation:

- [OpenRouter usage accounting](https://openrouter.ai/docs/cookbook/administration/usage-accounting)
- [Vercel OpenAI Chat Completions compatibility](https://vercel.com/docs/ai-gateway/sdks-and-apis/openai-chat-completions)

## Verification

Use `bash scripts/test-dictation-native.sh` for mocked provider contracts, refinement modes, fallback, cancellation and delivery spies. It makes no inference requests and does not exercise microphone capture or external-app insertion. Rust tests cover ledger persistence, idempotent completion and reported/estimated/unknown costs. React tests cover switch persistence, usage events, read failures and browser behavior.

Browser verification may use a self-contained build of the current UI inside Orca when no development server is running. It proves layout and browser behavior, not native permissions, paid provider acceptance or delivered text in another app.
