"""Regenerate offline picker data from pinned official Unicode/CLDR sources."""
import hashlib
import json
from pathlib import Path
import re
import urllib.request
import xml.etree.ElementTree as ET

OUT = Path(__file__).parent
sources = []
def fetch(url):
    data = urllib.request.urlopen(url, timeout=60).read()
    sources.append({'url': url, 'sha256': hashlib.sha256(data).hexdigest()})
    return data.decode('utf-8')

def key(text):
    return text.replace('\ufe0f', '')

annotations = {}
for lang in ['en', 'ko']:
    values = {}
    for folder in ['annotations', 'annotationsDerived']:
        xml = fetch(f'https://raw.githubusercontent.com/unicode-org/cldr/release-46/common/{folder}/{lang}.xml')
        for node in ET.fromstring(xml).iter('annotation'):
            value = ''.join(node.itertext()).strip()
            if value in ['↑↑↑', '∅∅∅']:
                continue
            item = values.setdefault(key(node.attrib['cp']), {'name': '', 'keywords': []})
            if node.attrib.get('type') == 'tts':
                item['name'] = value
            else:
                item['keywords'].extend(value.split(' | '))
    annotations[lang] = values

source = fetch('https://www.unicode.org/Public/emoji/16.0/emoji-test.txt')
records = []
group = subgroup = ''
for line in source.splitlines():
    if line.startswith('# group: '): group = line[9:]
    if line.startswith('# subgroup: '): subgroup = line[12:]
    match = re.match(r'^([0-9A-F ]+)\s*; fully-qualified\s*# \S+ E[\d.]+ (.+)$', line)
    if not match: continue
    glyph = ''.join(chr(int(cp, 16)) for cp in match[1].split())
    en = annotations['en'].get(key(glyph), {})
    ko = annotations['ko'].get(key(glyph), {})
    records.append({'emoji': glyph, 'name': en.get('name') or match[2], 'nameKo': ko.get('name') or match[2], 'group': group, 'keywords': list(dict.fromkeys([subgroup, *en.get('keywords', []), *ko.get('keywords', [])]))})
(OUT / 'data.json').write_text(json.dumps(records, ensure_ascii=False, separators=(',', ':')) + '\n')
license_text = fetch('https://raw.githubusercontent.com/unicode-org/cldr/release-46/LICENSE')
(OUT / 'UNICODE-LICENSE.txt').write_text(license_text)
(OUT / 'provenance.json').write_text(json.dumps({'unicodeEmoji': '16.0', 'cldr': '46', 'count': len(records), 'sources': sources}, indent=2) + '\n')
print(f'Generated {len(records)} fully-qualified sequences, { (OUT / "data.json").stat().st_size } bytes')
