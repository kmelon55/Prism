import { useEffect, useMemo, useRef, useState, type CSSProperties, type KeyboardEvent } from 'react';
import { ArrowLeft, Search, X } from 'lucide-react';
import { useLocale } from '../i18n';
import { categories, loadEmojiCatalog, readRecents, rememberEmoji, searchEmojis, skinTones, type EmojiCatalog, type EmojiRecord, type SkinTone } from './catalog';
import messages from './messages.json';
import './emoji.css';

export interface EmojiPickerProps {
  onClose: () => void;
  onCopy: (emoji: string) => Promise<void>;
  /** Omit when pasting into the captured original app is unavailable. */
  onPaste?: (emoji: string) => Promise<void>;
  initialMode?: 'copy' | 'paste';
  initialQuery?: string;
  /** Optional offline loader, also useful for testing loading/failure states. */
  loadCatalog?: () => Promise<EmojiCatalog>;
}
type FailedAction = { emoji: string; mode: 'copy' | 'paste'; detail?: string };
function actionErrorDetail(error: unknown): string | undefined {
  const value = error instanceof Error ? error.message : typeof error === 'string' ? error : '';
  return value.replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, 300) || undefined;
}
const toneNames = ['Default', 'Light', 'Medium-light', 'Medium', 'Medium-dark', 'Dark'];
export function EmojiPicker({ onClose, onCopy, onPaste, initialMode = 'copy', initialQuery = '', loadCatalog = loadEmojiCatalog }: EmojiPickerProps) {
  const locale = useLocale();
  const text = (value: string) => locale === 'ko' ? messages.find(pair => pair[0] === value)?.[1] ?? value : value;
  const [catalog, setCatalog] = useState<EmojiCatalog>();
  const [loadError, setLoadError] = useState(false);
  const [attempt, setAttempt] = useState(0);
  const [query, setQuery] = useState(initialQuery);
  const [category, setCategory] = useState('Smileys & Emotion');
  const [tone, setTone] = useState<SkinTone>('');
  const [recent, setRecent] = useState(readRecents);
  const [mode, setMode] = useState<'copy' | 'paste'>(initialMode === 'paste' && onPaste ? 'paste' : 'copy');
  const [active, setActive] = useState(0);
  const [columns, setColumns] = useState(10);
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState<FailedAction>();
  const [status, setStatus] = useState('');
  const [storageError, setStorageError] = useState(false);
  const locked = useRef(false);
  const composing = useRef(false);
  const compositionEnded = useRef(-Infinity);
  const mounted = useRef(true);
  const search = useRef<HTMLInputElement>(null);
  const grid = useRef<HTMLDivElement>(null);
  const cells = useRef(new Map<number, HTMLButtonElement>());
  useEffect(() => { mounted.current = true; search.current?.focus(); return () => { mounted.current = false; }; }, []);
  useEffect(() => {
    let cancelled = false;
    setLoadError(false);
    void Promise.resolve().then(loadCatalog).then(value => { if (!cancelled) setCatalog(value); }, () => { if (!cancelled) setLoadError(true); });
    return () => { cancelled = true; };
  }, [loadCatalog, attempt]);
  useEffect(() => {
    if (!grid.current || typeof ResizeObserver === 'undefined') return;
    const observer = new ResizeObserver(([entry]) => setColumns(Math.max(4, Math.floor(entry.contentRect.width / 52))));
    observer.observe(grid.current);
    return () => observer.disconnect();
  }, [catalog]);
  const items = useMemo(() => catalog ? searchEmojis(catalog, query, category, tone, recent) : [], [catalog, query, category, tone, recent]);
  const selected = items[Math.min(active, Math.max(0, items.length - 1))];
  const actualMode = mode === 'paste' && onPaste ? 'paste' : 'copy';
  useEffect(() => { setActive(0); grid.current?.scrollTo?.({ top: 0 }); }, [query, category, tone]);
  function isComposing(event: KeyboardEvent) { return composing.current || event.nativeEvent.isComposing || event.keyCode === 229 || performance.now() - compositionEnded.current < 80; }
  async function perform(item: FailedAction) {
    if (!catalog || locked.current || composing.current || (item.mode === 'paste' && !onPaste)) return;
    locked.current = true; setBusy(true); setStatus(''); setFailed(undefined);
    try {
      await (item.mode === 'paste' ? onPaste!(item.emoji) : onCopy(item.emoji));
      const saved = rememberEmoji(item.emoji, catalog, recent);
      if (mounted.current) { setRecent(saved.recent); setStorageError(!saved.persisted); setStatus(item.mode === 'paste' ? 'Pasted' : 'Copied'); }
    } catch (error) {
      if (mounted.current) setFailed({ ...item, detail: actionErrorDetail(error) });
    } finally {
      locked.current = false;
      if (mounted.current) setBusy(false);
    }
  }
  function move(index: number) {
    const next = Math.max(0, Math.min(index, items.length - 1));
    setActive(next); cells.current.get(next)?.focus(); cells.current.get(next)?.scrollIntoView?.({ block: 'nearest' });
  }
  function gridKey(event: KeyboardEvent) {
    if (isComposing(event)) { if (event.key === 'Enter' || event.key === ' ') event.preventDefault(); event.stopPropagation(); return; }
    const fromSearch = event.target === search.current;
    if (fromSearch && (event.key === 'ArrowLeft' || event.key === 'ArrowRight' || event.key === 'Home' || event.key === 'End')) return;
    const offsets: Record<string, number> = { ArrowRight: 1, ArrowLeft: -1, ArrowDown: columns, ArrowUp: -columns };
    if (event.key in offsets && items.length) { event.preventDefault(); move(fromSearch ? (event.key === 'ArrowUp' ? items.length - 1 : 0) : active + offsets[event.key]); }
    else if (event.key === 'Home' && items.length) { event.preventDefault(); move(0); }
    else if (event.key === 'End' && items.length) { event.preventDefault(); move(items.length - 1); }
    else if (event.key === 'Enter') { event.preventDefault(); if (selected && !failed) void perform({ emoji: selected.emoji, mode: actualMode }); }
  }
  const label = (item: EmojiRecord) => locale === 'ko' ? item.nameKo : item.name;
  const rows = Array.from({ length: Math.ceil(items.length / columns) }, (_, row) => items.slice(row * columns, (row + 1) * columns));
  return <section className="emoji-picker" aria-label={text('Emoji')} onKeyDown={event => {
    event.stopPropagation();
    if (event.key === 'Escape' && !isComposing(event)) { event.preventDefault(); if (!locked.current) onClose(); }
  }}>
    <header className="emoji-header">
      <button type="button" className="emoji-icon-button" aria-label={text('Close emoji picker')} onClick={onClose} disabled={busy}><ArrowLeft size={18}/></button>
      <div className="emoji-search"><Search size={17} aria-hidden="true"/><input ref={search} value={query} aria-label={text('Search emoji')} placeholder={text('Search in Korean or English')} onChange={event => setQuery(event.target.value)} onKeyDown={gridKey} onCompositionStart={() => { composing.current = true; }} onCompositionEnd={() => { composing.current = false; compositionEnded.current = performance.now(); }}/>{query && <button type="button" className="emoji-icon-button" aria-label={text('Clear search')} onClick={() => { setQuery(''); search.current?.focus(); }}><X size={14}/></button>}</div>
      <select className="emoji-tone" aria-label={text('Skin tone')} value={tone} onChange={event => setTone(event.target.value as SkinTone)}>{skinTones.map((value, index) => <option key={value} value={value}>{value || '✋'} {text(toneNames[index])}</option>)}</select>
    </header>
    <nav className="emoji-categories" aria-label={text('Emoji categories')}>
      {([['recent', '◷', 'Recent', '최근'], ['all', '⊞', 'All', '전체'], ...categories] as const).map(([id, glyph, en, ko]) => <button type="button" key={id} aria-label={locale === 'ko' ? ko : en} title={locale === 'ko' ? ko : en} aria-pressed={category === id && !query} className="emoji-category" onClick={() => { setCategory(id); setQuery(''); }}><span aria-hidden="true">{glyph}</span></button>)}
    </nav>
    {!catalog ? <div className="emoji-empty" role={loadError ? 'alert' : 'status'}><p>{text(loadError ? 'Emoji could not be loaded.' : 'Loading emoji…')}</p>{loadError && <button type="button" onClick={() => setAttempt(value => value + 1)}>{text('Retry loading')}</button>}</div> : <>
      <div className="emoji-grid" ref={grid} role="grid" aria-label={text('Emoji')} aria-rowcount={rows.length} aria-colcount={columns} aria-busy={busy} style={{ '--emoji-columns': columns } as CSSProperties} onKeyDown={gridKey}>
        {rows.map((row, rowIndex) => <div role="row" key={rowIndex} className="emoji-row">{row.map((item, column) => { const index = rowIndex * columns + column; return <div role="gridcell" key={item.emoji} aria-selected={index === active}><button type="button" ref={element => { if (element) cells.current.set(index, element); else cells.current.delete(index); }} className="emoji-cell" tabIndex={index === active ? 0 : -1} aria-label={label(item)} title={label(item)} data-emoji={item.emoji} disabled={busy || !!failed} onFocus={() => setActive(index)} onClick={() => { setActive(index); void perform({ emoji: item.emoji, mode: actualMode }); }}><span aria-hidden="true">{item.emoji}</span></button></div>; })}</div>)}
        {!items.length && <div className="emoji-empty"><p>{text(!query && category === 'recent' ? 'No recent emoji yet' : 'No matching emoji')}</p><span>{text(!query && category === 'recent' ? 'Your successful choices appear here.' : 'Try another word in Korean or English.')}</span></div>}
      </div>
    </>}
    {failed && <div className="emoji-error" role="alert"><span>{text(failed.mode === 'copy' ? 'Copy failed. Try again when ready.' : 'Paste failed. Check the original app, then retry.')}{failed.detail && <small className="emoji-error-detail">{failed.detail}</small>}</span><button type="button" onClick={() => void perform(failed)} disabled={busy || (failed.mode === 'paste' && !onPaste)}>{text(failed.mode === 'copy' ? 'Retry copy' : 'Retry paste')}</button>{failed.mode === 'paste' && <button type="button" disabled={busy} onClick={() => void perform({ emoji: failed.emoji, mode: 'copy' })}>{text('Copy instead')}</button>}<button type="button" onClick={() => setFailed(undefined)}>{text('Dismiss')}</button></div>}
    <footer className="emoji-footer"><div className="emoji-selection"><span className="emoji-preview" aria-hidden="true">{selected?.emoji ?? '☺️'}</span><span>{selected ? label(selected) : text('Choose an emoji')}</span></div><div className="emoji-modes" role="group" aria-label={text('Emoji action')}><button type="button" aria-pressed={actualMode === 'copy'} title={text('Copy to clipboard')} disabled={busy} onClick={() => setMode('copy')}>{text('Copy')}</button>{onPaste && <button type="button" aria-pressed={actualMode === 'paste'} title={text('Paste into the original app')} disabled={busy} onClick={() => setMode('paste')}>{text('Paste')}</button>}</div><span className="emoji-status" role="status">{text(busy ? 'Working…' : status)}</span></footer>
    {storageError && <p className="emoji-storage" role="status">{text('Recent choices could not be saved on this device.')}</p>}
  </section>;
}
export default EmojiPicker;
