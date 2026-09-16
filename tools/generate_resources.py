"""Extract wire-compatible English RC bitmaps and fonts from Android Kotlin tables."""
import base64
import json
import re
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
proto = source / 'app/src/main/java/com/rsdynamics/miniexview/protocol'
bitmap_text = (proto / 'EnglishRcBitmapCatalog.kt').read_text()
bitmap_pattern = re.compile(r'bitmap\((\d+),\s*(\d+),\s*(\d+),\s*RcBitmapType\.(\w+),\s*((?:"[0-9A-F]+"\s*\+?\s*)+)\)', re.S)
bitmaps = []
for match in bitmap_pattern.finditer(bitmap_text):
    width, height, fragments = map(int, match.group(1, 2, 3))
    data = bytes.fromhex(''.join(re.findall(r'"([0-9A-F]+)"', match.group(5))))
    bitmaps.append(dict(width=width, height=height, fragments=fragments, type=match.group(4), data=base64.b64encode(data).decode()))
assert len(bitmaps) == 43, len(bitmaps)
font_text = (proto / 'MiniExFontCatalog.kt').read_text()
fonts = []
for i in range(3):
    part = font_text.split(f'private val font{i} = RcFont(', 1)[1].split('private val font' + str(i + 1) + ' = RcFont(', 1)[0].split('private val fonts', 1)[0]
    width = int(re.search(r'width = (\d+)', part).group(1))
    height = int(re.search(r'height = (\d+)', part).group(1))
    first = int(re.search(r'firstAscii = (\d+)', part).group(1))
    last = int(re.search(r'lastAscii = (\d+)', part).group(1))
    indexes = [int(v) for v in re.search(r'tableIndexes = intArrayOf\((.*?)\)', part, re.S).group(1).split(',') if v.strip()]
    glyph_part = part.split('glyphs = arrayOf(', 1)[1]
    glyphs = [base64.b64encode(bytes.fromhex(''.join(re.findall(r'"([0-9A-F]+)"', m)))).decode() for m in re.findall(r'decodeHex\((.*?)\)', glyph_part, re.S)]
    assert all(len(base64.b64decode(g)) == width * height for g in glyphs), i
    assert len(indexes) == last - first + 2
    fonts.append(dict(width=width, height=height, first=first, last=last, indexes=indexes, glyphs=glyphs))
assert len(fonts) == 3
bar_text = (proto / 'MiniExBargraph.kt').read_text()
bar_pairs = re.findall(r'(\d+) to "([0-9A-F]+)"', bar_text)
assert len(bar_pairs) == 26
bargraphs = []
for h, hex_data in bar_pairs:
    height = int(h)
    raw = bytes.fromhex(hex_data)
    normalized = (raw[:4*height] if len(raw) >= 4*height else raw + raw[-1:] * (4*height-len(raw)))
    bargraphs.append(dict(width=4,height=height,fragments=1,type='COLOR8',data=base64.b64encode(normalized).decode()))
target.mkdir(parents=True, exist_ok=True)
(target / 'EnglishRC.json').write_text(json.dumps(dict(bitmaps=bitmaps, fonts=fonts, bargraphs=bargraphs), separators=(',',':')))
print('Generated:',len(bitmaps),'bitmaps,',len(fonts),'fonts,',len(bargraphs),'bargraph columns')

# Language overlays share all fonts and bargraphs with the English catalog.
localized = (proto / 'LocalizedRcBitmapCatalogs.kt').read_text()
overlays = {}
for language, section in re.findall(r'private val (\w+)Catalog:.*?mapOf\((.*?)\n    \)\)', localized, re.S):
    bitmaps_by_id = {}
    for match in re.finditer(r'(\d+) to bitmap\((\d+),\s*(\d+),\s*(\d+),\s*RcBitmapType\.(\w+),\s*((?:"[0-9A-F]+"\s*\+?\s*)+)\)', section, re.S):
        bitmap_id, width, height, fragments = map(int, match.group(1, 2, 3, 4))
        data = bytes.fromhex(''.join(re.findall(r'"([0-9A-F]+)"', match.group(6))))
        bitmaps_by_id[str(bitmap_id)] = dict(width=width, height=height, fragments=fragments, type=match.group(5), data=base64.b64encode(data).decode())
    overlays[language] = bitmaps_by_id
assert len(overlays) == 6 and all(overlays.values())
(target / 'LocalizedRC.json').write_text(json.dumps(overlays, separators=(',', ':')))
print('Generated overlays:', ', '.join(f'{key}={len(value)}' for key, value in overlays.items()))
