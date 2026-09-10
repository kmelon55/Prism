/** Compatibility width, case and accent folding while preserving whole Hangul syllables. */
export function normalizeSearchText(value: string): string {
  return value.toLowerCase().normalize("NFKD").replace(/\p{M}/gu, "").normalize("NFC");
}

/** A typed leading Jamo may stand for a syllable; full syllables still match literally. */
function matchesCharacter(needle: string, candidate: string): boolean {
  if (needle === candidate) return true;
  const initial = needle.codePointAt(0)!;
  const syllable = candidate.codePointAt(0)!;
  return initial >= 0x1100 && initial <= 0x1112 && syllable >= 0xac00 && syllable <= 0xd7a3
    && Math.floor((syllable - 0xac00) / 588) === initial - 0x1100;
}

export function subsequenceScore(needle: string, haystack: string): number | null {
  const characters = [...haystack];
  let score = 0;
  let cursor = 0;
  let streak = 0;
  for (const character of needle) {
    let index = cursor;
    while (index < characters.length && !matchesCharacter(character, characters[index])) index += 1;
    if (index === characters.length) return null;
    const isBoundary = index === 0 || /[\s_\-./]/.test(characters[index - 1]);
    streak = index === cursor ? streak + 1 : 0;
    score += 14 + streak * 5 + (isBoundary ? 12 : 0) - Math.min(index - cursor, 9);
    cursor = index + 1;
  }
  return score - Math.max(characters.length - [...needle].length, 0) * 0.08;
}
