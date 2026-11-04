import assert from 'node:assert/strict';
import { readdirSync, readFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const sourceRoot = fileURLToPath(new URL('../apps/mac/Sources/', import.meta.url));
const modules = readdirSync(sourceRoot).filter(name => existsSync(path.join(sourceRoot, name, 'Resources/ko.lproj/Localizable.strings')));
function catalog(module, language) {
  const source = readFileSync(path.join(sourceRoot, module, `Resources/${language}.lproj/Localizable.strings`), 'utf8');
  const entries = [...source.matchAll(/("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*")\s*;/g)];
  const result = new Map();
  for (const [, rawKey, rawValue] of entries) {
    const key = JSON.parse(rawKey), value = JSON.parse(rawValue);
    assert(!result.has(key), `${module}/${language}: duplicate key ${key}`);
    result.set(key, value);
  }
  assert(result.size > 0, `${module}/${language}: empty catalog`);
  return result;
}
function files(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const name = path.join(directory, entry.name);
    return entry.isDirectory() ? files(name) : name.endsWith('.swift') ? [name] : [];
  });
}
function normalize(value) {
  return value.replace(/%(?:\d+\$)?(?:\.\d+)?(?:lld|ld|llu|lu|d|u|f|g|@)/g, '{}');
}
// Keep interpolated expressions together, including nested calls and string literals.
function* literals(source) {
  let i = 0;
  while (i < source.length) {
    if (source.startsWith('//', i)) {
      const end = source.indexOf('\n', i);
      i = end < 0 ? source.length : end + 1;
      continue;
    }
    if (source[i] !== '"') { i++; continue; }
    const start = i++;
    let value = '';
    while (i < source.length) {
      if (source.startsWith('\\(', i)) {
        i += 2;
        let depth = 1;
        while (i < source.length && depth) {
          if (source[i] === '(') depth++;
          else if (source[i] === ')') depth--;
          i++;
        }
        value += '{}';
      } else if (source[i] === '\\') {
        const next = source[++i];
        value += ({ n: '\n', t: '\t', r: '\r' })[next] ?? next;
        i++;
      } else if (source[i] === '"') { i++; break; }
      else value += source[i++];
    }
    yield { start, end: i, value };
  }
}

test('all feature catalogs have matching English and Korean keys and placeholders', () => {
  for (const module of modules) {
    const en = catalog(module, 'en'), ko = catalog(module, 'ko');
    assert.deepEqual([...en.keys()].sort(), [...ko.keys()].sort(), module);
    for (const [key, value] of en) {
      assert.equal(value, key, `${module}: English must use the source copy`);
      assert(!/[가-힣]/u.test(value), `${module}: Korean leaked into English: ${key}`);
      const translated = ko.get(key);
      assert(translated.trim(), `${module}: empty Korean value for ${key}`);
      const placeholders = text => [...text.matchAll(/%(?:\d+\$)?(?:\.\d+)?(?:lld|ld|llu|lu|d|u|f|g|@)/g)].map(match => match[0].replace(/%\d+\$/, '%')).sort();
      assert.deepEqual(placeholders(translated), placeholders(key), `${module}: placeholder mismatch for ${key}`);
    }
  }
});

test('localized UI literals resolve in each feature catalog', () => {
  const missing = [];
  for (const module of modules) {
    const keys = new Set([...catalog(module, 'ko').keys()].map(normalize));
    for (const file of files(path.join(sourceRoot, module))) {
      const source = readFileSync(file, 'utf8');
      for (const { start, end, value } of literals(source)) {
        const before = source.slice(Math.max(0, start - 100), start), after = source.slice(end, end + 60);
        const helper = /(?:\bL|\bN|L10n\.tr|L10n\.format|SystemStrings\.localized|ClipboardText\.localize|ScriptStrings\.localized|ScriptStrings\.localize|\blocalized)\(\s*$/.test(before);
        const direct = /String\(localized:\s*$/.test(before) || (/Text\(\s*$/.test(before) && /^,\s*bundle:/.test(after));
        if (!(helper || direct) || !value) continue;
        // SystemSetting expands an English enum name into one of thirteen fully translated keys.
        if (module === 'PrismSystem' && value === 'Open macOS {} settings') {
          assert.equal([...keys].filter(key => /^Open macOS .+ settings$/.test(key)).length, 13);
          continue;
        }
        if (!keys.has(normalize(value))) missing.push(`${path.relative(sourceRoot, file)}: ${value}`);
      }
      assert(!/bundle:\s*\.module(?!\.prismLocalized)\b/.test(source), `${file}: bypasses the app language`);
    }
  }
  assert.deepEqual(missing, []);
});

test('product UI and sync errors do not hard-code Korean outside catalogs', () => {
  const hardCoded = [];
  for (const module of modules) {
    for (const file of files(path.join(sourceRoot, module))) {
      const source = readFileSync(file, 'utf8');
      for (const { start, value } of literals(source)) {
        if (!/[가-힣]/u.test(value)) continue;
        const before = source.slice(Math.max(0, start - 100), start);
        if (/(?:\bText|\bButton|\bTextField|\bSecureField|\bToggle|\bPicker|PrismSettingsPage|TransferError|SyncFailure\.message)\(\s*$/.test(before)
            || /(?:\btitle:|\bstatus\s*=)\s*$/.test(before)) {
          hardCoded.push(`${path.relative(sourceRoot, file)}: ${value}`);
        }
      }
    }
  }
  assert.deepEqual(hardCoded, []);
});
