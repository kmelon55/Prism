import { act, StrictMode } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EmojiPicker, type EmojiPickerProps } from './EmojiPicker';
import { createCatalog, RECENT_KEY, RECENT_LIMIT } from './catalog';
import data from './data.json';
const catalog = createCatalog(data);
let root: Root, container: HTMLDivElement;
const onCopy = vi.fn<EmojiPickerProps['onCopy']>();
const onPaste = vi.fn<NonNullable<EmojiPickerProps['onPaste']>>();
const onClose = vi.fn();
const loadCatalog = vi.fn(async () => catalog);
beforeEach(() => {
  vi.resetAllMocks(); localStorage.clear(); localStorage.setItem('prism:preferences', JSON.stringify({ language: 'en' }));
  onCopy.mockResolvedValue(undefined); onPaste.mockResolvedValue(undefined); loadCatalog.mockResolvedValue(catalog);
  container = document.createElement('div'); document.body.append(container); root = createRoot(container);
});
afterEach(async () => { await act(async () => root.unmount()); container.remove(); vi.restoreAllMocks(); });
async function mount(props: Partial<EmojiPickerProps> = {}) { await act(async () => root.render(<StrictMode><EmojiPicker onClose={onClose} onCopy={onCopy} onPaste={onPaste} loadCatalog={loadCatalog} {...props}/></StrictMode>)); }
function button(label: string) { const result = [...container.querySelectorAll('button')].find(button => button.getAttribute('aria-label') === label || button.textContent?.trim() === label); expect(result, label).toBeDefined(); return result!; }
async function click(label: string) { await act(async () => button(label).click()); }
async function query(value: string) { const input = container.querySelector('input')!; await act(async () => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!.set!.call(input, value); input.dispatchEvent(new Event('input', { bubbles: true })); }); }
async function key(target: Element, key: string, options: KeyboardEventInit = {}) { await act(async () => target.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key, ...options }))); }
function glyphs() { return [...container.querySelectorAll<HTMLButtonElement>('[data-emoji]')].map(item => item.dataset.emoji); }

describe('mounted emoji picker', () => {
  it('copies exact fully-qualified heart and complete family ZWJ sequences', async () => {
    await mount(); await query('❤️'); await click('red heart'); expect(onCopy).toHaveBeenLastCalledWith('\u2764\ufe0f');
    await query('👨‍👩‍👧‍👦'); await click('family: man, woman, girl, boy');
    expect(onCopy).toHaveBeenLastCalledWith('👨\u200d👩\u200d👧\u200d👦'); expect(onPaste).not.toHaveBeenCalled();
  });
  it('searches Korean/English CLDR terms, common slang and categories across current category', async () => {
    await mount(); await query('따봉'); expect(glyphs()).toContain('👍');
    await query('강아지'); expect(glyphs()).toContain('🐶');
    await query('laptop'); expect(glyphs()).toContain('💻');
    await query('음식'); expect(glyphs()).toContain('🍊');
    await query('ㅋㅋ'); expect(glyphs()).toContain('😂');
    await query('nonexistent-emoji-xyz'); expect(container.textContent).toContain('No matching emoji');
  });
  it('selects official skin-tone ZWJ sequences and persists exact recents after paste', async () => {
    await mount({ initialMode: 'paste' }); await query('woman technologist');
    const select = container.querySelector('select')!;
    await act(async () => { select.value = '🏽'; select.dispatchEvent(new Event('change', { bubbles: true })); });
    expect(glyphs()).toContain('👩🏽‍💻'); await click('woman technologist: medium skin tone');
    expect(onPaste).toHaveBeenCalledExactlyOnceWith('👩🏽‍💻');
    expect(JSON.parse(localStorage.getItem(RECENT_KEY)!)[0]).toBe('👩🏽‍💻');
    await act(async () => root.unmount()); root = createRoot(container); await mount(); await click('Recent');
    expect(glyphs()).toEqual(['👩🏽‍💻']);
  });
  it('bounds and deduplicates recents and filters unknown entries', async () => {
    localStorage.setItem(RECENT_KEY, JSON.stringify(['invalid', ...catalog.base.slice(0, 50).map(item => item.emoji)]));
    await mount(); await query('👍'); await click('thumbs up'); await click('thumbs up');
    const saved = JSON.parse(localStorage.getItem(RECENT_KEY)!);
    expect(saved.length).toBeLessThanOrEqual(RECENT_LIMIT); expect(saved.filter((value: string) => value === '👍')).toHaveLength(1); expect(saved).not.toContain('invalid');
  });
  it('does not execute or close during IME composition, including the post-composition Enter', async () => {
    await mount(); const input = container.querySelector('input')!;
    await act(async () => input.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true })));
    await key(input, 'Enter'); await key(input, 'Escape'); expect(onCopy).not.toHaveBeenCalled(); expect(onClose).not.toHaveBeenCalled();
    await act(async () => input.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true })));
    await key(input, 'Enter'); expect(onCopy).not.toHaveBeenCalled();
    await key(input, 'Enter', { isComposing: true }); expect(onCopy).not.toHaveBeenCalled();
  });
  it('supports grid arrows, Enter and Escape without bubbling to launcher handlers', async () => {
    const parentKey = vi.fn(); document.addEventListener('keydown', parentKey);
    await mount(); await key(container.querySelector('input')!, 'ArrowDown');
    expect(document.activeElement?.getAttribute('data-emoji')).toBe('😀');
    await key(document.activeElement!, 'ArrowRight'); expect(document.activeElement?.getAttribute('data-emoji')).toBe('😃');
    await key(document.activeElement!, 'Enter'); expect(onCopy).toHaveBeenCalledExactlyOnceWith('😃');
    await key(document.activeElement!, 'Escape'); expect(onClose).toHaveBeenCalledOnce(); expect(parentKey).not.toHaveBeenCalled(); document.removeEventListener('keydown', parentKey);
  });
  it('retains the failed operation and requires explicit retry without recording failure as recent', async () => {
    onPaste.mockRejectedValueOnce(new Error('Target changed'));
    await mount({ initialMode: 'paste' }); await query('👍'); await click('thumbs up');
    expect(container.querySelector('[role="alert"]')?.textContent).toContain('Paste failed'); expect(localStorage.getItem(RECENT_KEY)).toBeNull(); expect(container.querySelector('[role="alert"]')?.textContent).toContain('Target changed');
    await key(container.querySelector('input')!, 'Enter'); await click('Copy'); await query('❤️'); expect(onPaste).toHaveBeenCalledTimes(1); expect(onCopy).not.toHaveBeenCalled();
    await click('Retry paste'); expect(onPaste).toHaveBeenLastCalledWith('👍'); expect(onPaste).toHaveBeenCalledTimes(2);
    expect(container.querySelector('[role="alert"]')).toBeNull(); expect(JSON.parse(localStorage.getItem(RECENT_KEY)!)).toEqual(['👍']);
  });
  it('offers an explicit copy fallback for the exact failed paste string', async () => {
    onPaste.mockRejectedValueOnce('Accessibility permission is required.');
    await mount({ initialMode: 'paste' }); await query('👩🏽‍💻');
    await click('woman technologist: medium skin tone');
    expect(container.querySelector('[role="alert"]')?.textContent).toContain('Accessibility permission is required.');
    await query('❤️'); await click('Copy instead');
    expect(onCopy).toHaveBeenCalledExactlyOnceWith('👩🏽‍💻'); expect(onPaste).toHaveBeenCalledTimes(1);
    expect(container.querySelector('[role="alert"]')).toBeNull();
  });
  it('prevents duplicate async actions and closing while an action is pending', async () => {
    let resolve!: () => void; onCopy.mockImplementation(() => new Promise<void>(done => { resolve = done; }));
    await mount(); await query('👍'); await act(async () => { button('thumbs up').click(); button('thumbs up').click(); });
    await key(container.querySelector('input')!, 'Escape'); expect(onCopy).toHaveBeenCalledTimes(1); expect(onClose).not.toHaveBeenCalled();
    await act(async () => resolve()); expect(container.textContent).toContain('Copied');
  });
  it('shows loading and only retries a failed data load on request', async () => {
    let reject!: (error: Error) => void; const loader = vi.fn(() => new Promise<typeof catalog>((_resolve, no) => { reject = no; }));
    await mount({ loadCatalog: loader }); expect(container.textContent).toContain('Loading emoji');
    await act(async () => reject(new Error('Chunk unavailable'))); expect(container.textContent).toContain('Emoji could not be loaded');
    const count = loader.mock.calls.length; await query('heart'); expect(loader).toHaveBeenCalledTimes(count);
    loader.mockResolvedValue(catalog); await click('Retry loading'); expect(glyphs()).toContain('❤️');
  });
  it('keeps action success separate from a localStorage failure', async () => {
    await mount(); vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('Quota'); });
    await query('👍'); await click('thumbs up'); expect(onCopy).toHaveBeenCalledOnce(); expect(container.textContent).toContain('Copied');
    expect(container.textContent).toContain('Recent choices could not be saved'); expect(container.querySelector('[role="alert"]')).toBeNull();
  });
  it('renders Korean UI and safely hides paste when no target callback exists', async () => {
    localStorage.setItem('prism:preferences', JSON.stringify({ language: 'ko' }));
    await mount({ onPaste: undefined, initialMode: 'paste' }); expect(container.textContent).toContain('복사');
    expect(container.textContent).not.toContain('붙여넣기'); await query('따봉');
    await act(async () => container.querySelector<HTMLButtonElement>('[data-emoji="👍"]')!.click()); expect(onCopy).toHaveBeenCalledWith('👍');
  });
});
