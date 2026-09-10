# Emoji picker

`apps/desktop/src/emoji/EmojiPicker.tsx` exports a compact, independent picker with large native color emoji glyphs, Korean/English search, category browsing, exact-sequence recent history, and copy/paste modes. All data is bundled; opening or searching the picker makes no external service request.

## Integration

```tsx
const EmojiPicker = lazy(() => import('./emoji/EmojiPicker'));

<EmojiPicker
  onClose={() => setSurface('launcher')}
  onCopy={async emoji => { await copyText(emoji); }}
  onPaste={async emoji => { await pasteIntoCapturedTarget(emoji); }}
  initialMode="copy"
/>
```

The callback names in this example are placeholders for the host's existing adapters. Register a command searchable through `emoji`, `이모지`, and optionally `emoticon`/`이모티콘` that opens this component. It owns its search header, category navigation, scroll area, and footer; render it in a full-height `min-height: 0` container and suppress the launcher search/results/footer while it is open. The component imports its own scoped CSS. Optional `initialQuery` seeds its internal search. A Suspense fallback is needed if the component itself is lazy-loaded; its large catalog already uses a separate dynamic import.

- `onCopy(emoji): Promise<void>` must reject on failure and resolve only after the clipboard write succeeds.
- Optional `onPaste(emoji): Promise<void>` must use the host's existing captured-original-app and target-checked native paste flow. Do not retarget a retry to whichever app is now foreground. Omit the callback when that operation is unavailable; the picker then exposes copy only.
- `onClose(): void` returns to the launcher. The component keeps itself open after successful copy/paste; the host may close/hide after a successful native paste if its established flow requires that.
- `initialMode` is `copy` by default. Mode buttons select what the next cell click or Enter does. A failed operation freezes its exact emoji and mode for its own retry button, even if search or mode subsequently changes. Dismiss explicitly abandons that failed operation; Copy instead explicitly copies the exact failed paste string. Safe Error/string callback details are displayed as bounded plain text beneath the localized failure summary.
- Callback implementations must not swallow native errors. No automatic retry runs. A synchronous ref blocks duplicate pending execution. Escape/back are disabled during an operation to avoid hiding an unresolved outcome.
- Product copy resolves through `useLocale()` and the local bilingual `emoji/messages.json` immediately; no shared translation edit is required. Those English/Korean pairs can be merged into `locales/messages.json` later if the host wants to consolidate translations.

## Data and Unicode behavior

The checked-in catalog includes **3,781 fully-qualified Unicode Emoji 16.0 sequences**, with CLDR 46 English and Korean names/keywords. The default grid omits duplicate skin-tone variants; the skin-tone selector substitutes an exact official sequence wherever the corresponding homogeneous tone variant exists. Mixed-tone emoji remain available through exact glyph search and retain their complete sequence in recent history. The selector does not expose independent skin-tone choices for each person in a couple.

Search covers every category while text is present, supports NFC Korean normalization, English case folding, whitespace-separated terms, CLDR keywords, localized category names, and hand-maintained common aliases such as `따봉`, `ㅋㅋ`, `ㅠㅠ`, `고마워`, `lol`, and `congrats`. Searching an exact fully-qualified emoji returns that exact sequence, including mixed tones. Display and callback output never slice graphemes or synthesize ZWJ/variation-selector sequences. Copying a heart preserves U+FE0F; professional/family emoji retain every joiner, and flags retain their entire sequence.

Official primary sources checked during implementation:

- [Unicode Emoji 16.0 test data](https://www.unicode.org/Public/emoji/16.0/emoji-test.txt), including keyboard recommendations and qualification status.
- [CLDR 46 release](https://cldr.unicode.org/downloads/cldr-46).
- [CLDR 46 Korean annotations](https://github.com/unicode-org/cldr/blob/release-46/common/annotations/ko.xml), [English annotations](https://github.com/unicode-org/cldr/blob/release-46/common/annotations/en.xml), and corresponding `annotationsDerived` files.
- [Unicode License V3 in CLDR 46](https://github.com/unicode-org/cldr/blob/release-46/LICENSE), reproduced in `emoji/UNICODE-LICENSE.txt`.

`emoji/provenance.json` records each downloaded URL and its SHA-256. `python3 apps/desktop/src/emoji/generate-data.py` reproducibly regenerates the checked-in JSON from the versioned official sources (maintainer-only network access; never invoked at runtime). Raw JSON is approximately 1.18 MB before bundler compression and is lazy-loaded on opening the picker. Keep the Unicode license alongside redistributed data. Rendering depends on the installed platform emoji font, so newer Unicode glyph coverage must be checked on each supported OS version.

## Recent history and interaction

Successful actions persist up to 32 unique exact strings under `prism:emoji:recent:v1`. Reads bound serialized input to 16 KiB and each string to 100 UTF-16 units; display ignores strings absent from the official catalog. Malformed/unavailable storage safely starts empty. A write failure preserves action success and in-memory history while displaying a storage notice; it never retries the copy/paste operation.

The responsive ARIA grid has named buttons, roving focus, arrow navigation, Home/End, Enter activation, and Escape to close. Arrow Down in search enters the grid; left/right remain text editing keys while search has focus. IME composition, keyCode 229, and immediate post-composition Enter are guarded. Events do not reach ordinary launcher bubble handlers; a host capture-phase global shortcut handler must still explicitly skip this surface. No permanent shortcut legend is rendered.

## Validation

Mounted React tests cover exact variation-selector and family/professional ZWJ output, bilingual/alias/category search, official skin tones, persisted and bounded recent history, unavailable storage, IME guards, keyboard navigation and launcher event isolation, explicit load/action retry, duplicate pending operations, Korean UI, and copy-only fallback. Run:

```sh
pnpm --filter @prism/desktop exec vitest run src/emoji/EmojiPicker.test.tsx
pnpm --filter @prism/desktop typecheck
```

These tests establish DOM and callback contracts. Real native paste-target safety, Accessibility permission behavior, OS emoji font coverage, and visual integration in the existing running app still require host integration verification. No development server or native app was started, restarted, or stopped for this work.
