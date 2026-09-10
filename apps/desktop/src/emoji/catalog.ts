export interface EmojiRecord { emoji: string; name: string; nameKo: string; group: string; keywords: string[] }
export interface EmojiCatalog { all: EmojiRecord[]; base: EmojiRecord[]; byEmoji: Map<string, EmojiRecord>; variants: Map<string, Map<string, EmojiRecord>> }
export const skinTones = ['', '🏻', '🏼', '🏽', '🏾', '🏿'] as const;
export type SkinTone = typeof skinTones[number];
const stripTone = (value: string) => value.replace(/[\u{1f3fb}-\u{1f3ff}\ufe0f]/gu, '');
const hasTone = (value: string) => /[\u{1f3fb}-\u{1f3ff}]/u.test(value);
const aliases: Record<string, string> = {
  '👍': '따봉 좋아 좋아요 굿 good yes +1 thumbs up', '👎': '싫어 별로 아니 no -1',
  '😂': 'ㅋㅋ ㅋㅋㅋ 웃음 lol haha', '🤣': 'ㅋㅋ ㅋㅋㅋ 웃음 lol lmao', '😭': 'ㅠㅠ ㅜㅜ 눈물 슬픔 sad cry',
  '❤️': '하트 사랑 love heart', '🔥': '불 핫 hot fire', '🙏': '감사 고마워 부탁 thank thanks please pray',
  '🎉': '축하 생일 파티 congratulations congrats party', '✅': '완료 확인 체크 done check',
  '👋': '안녕 인사 hello hi bye', '💻': '컴퓨터 노트북 개발 coding laptop',
};
export const categories = [
  ['Smileys & Emotion', '😀', 'Smileys', '표정'], ['People & Body', '👋', 'People', '사람'],
  ['Animals & Nature', '🌿', 'Nature', '자연'], ['Food & Drink', '🍊', 'Food', '음식'],
  ['Travel & Places', '🚀', 'Travel', '여행'], ['Activities', '⚽', 'Activities', '활동'],
  ['Objects', '💡', 'Objects', '사물'], ['Symbols', '💛', 'Symbols', '기호'], ['Flags', '🏳️', 'Flags', '국기'],
] as const;
export function createCatalog(all: EmojiRecord[]): EmojiCatalog {
  const variants = new Map<string, Map<string, EmojiRecord>>();
  for (const item of all) {
    const tones = [...item.emoji].filter(char => hasTone(char));
    if (!tones.length || !tones.every(tone => tone === tones[0])) continue;
    const key = stripTone(item.emoji);
    if (!variants.has(key)) variants.set(key, new Map());
    variants.get(key)!.set(tones[0], item);
  }
  return { all, base: all.filter(item => !hasTone(item.emoji)), byEmoji: new Map(all.map(item => [item.emoji, item])), variants };
}
let cached: Promise<EmojiCatalog> | undefined;
export function loadEmojiCatalog(): Promise<EmojiCatalog> {
  return cached ??= import('./data.json').then(module => createCatalog(module.default)).catch(error => { cached = undefined; throw error; });
}
export function withSkinTone(catalog: EmojiCatalog, item: EmojiRecord, tone: SkinTone): EmojiRecord {
  return tone ? catalog.variants.get(stripTone(item.emoji))?.get(tone) ?? item : item;
}
const normalize = (value: string) => value.normalize('NFC').toLowerCase().replaceAll('_', ' ').replaceAll('-', ' ');
export function searchEmojis(catalog: EmojiCatalog, query: string, category: string, tone: SkinTone, recent: string[]): EmojiRecord[] {
  const normalized = normalize(query).trim();
  const exact = catalog.byEmoji.get(query.trim());
  if (exact) return [exact];
  // Searching always covers every category. Category selection only filters browsing.
  const source = normalized ? catalog.base : category === 'recent' ? recent.flatMap(value => catalog.byEmoji.get(value) ?? []) : catalog.base.filter(item => category === 'all' || item.group === category);
  const tokens = normalized.split(/\s+/).filter(Boolean);
  return source.filter(item => {
    const categoryLabels = categories.find(category => category[0] === item.group)?.join(' ') ?? '';
    const haystack = normalize([item.name, item.nameKo, item.group, categoryLabels, ...item.keywords, aliases[item.emoji] ?? ''].join(' '));
    return tokens.every(token => haystack.includes(token));
  }).map(item => category === 'recent' && !normalized ? item : withSkinTone(catalog, item, tone));
}
export const RECENT_KEY = 'prism:emoji:recent:v1';
export const RECENT_LIMIT = 32;
export function readRecents(): string[] {
  try {
    const raw = localStorage.getItem(RECENT_KEY);
    if (!raw || raw.length > 16384) return [];
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? [...new Set(parsed.filter((value): value is string => typeof value === 'string' && value.length <= 100))].slice(0, RECENT_LIMIT) : [];
  } catch { return []; }
}
export function rememberEmoji(emoji: string, catalog: EmojiCatalog, current: string[]): { recent: string[]; persisted: boolean } {
  const recent = [emoji, ...current.filter(value => value !== emoji && catalog.byEmoji.has(value))].slice(0, RECENT_LIMIT);
  try { localStorage.setItem(RECENT_KEY, JSON.stringify(recent)); return { recent, persisted: true }; }
  catch { return { recent, persisted: false }; }
}
