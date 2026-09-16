"""Validate every bitmap/font referenced by the captured RC frames before iOS packaging."""
import base64
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
assets = json.loads((root / 'miniEXView/Resources/EnglishRC.json').read_text())
bitmaps = assets['bitmaps']
fonts = assets['fonts']
assert len(bitmaps) == 43 and len(fonts) == 3 and len(assets['bargraphs']) == 26
for font in fonts:
    assert len(font['indexes']) == font['last'] - font['first'] + 2
    assert all(0 <= index < len(font['glyphs']) for index in font['indexes'])
    assert all(len(base64.b64decode(g)) == font['width'] * font['height'] for g in font['glyphs'])
for bitmap in bitmaps + assets['bargraphs']:
    pixels = bitmap['width'] * bitmap['height']
    fmt = bitmap['type']
    n = pixels * 2 if fmt == 'COLOR16' else pixels if fmt == 'COLOR8' else (pixels + 7) // 8 if fmt == 'MONO' else (pixels + 3) // 4 if fmt == 'CGRAY2' else (pixels + 1) // 2
    assert bitmap['width'] > 0 and bitmap['height'] > 0 and bitmap['fragments'] > 0
    assert len(base64.b64decode(bitmap['data'])) >= n * bitmap['fragments']

frames = 0
for title, expected in [('short', 65), ('long', 695)]:
    copied = (root / f'miniEXView/Resources/RC-{title}.txt').read_bytes()
    original = (root / f'miniEXViewTests/Fixtures/RC from miniEX {title}.txt').read_bytes()
    assert copied == original
    count = 0
    for line in copied.splitlines():
        line = line.lstrip(b'~')
        if not line: continue
        def ah(data): return int(''.join(format(byte - 65, 'x') for byte in data), 16)
        body = line[13:-4]
        if not body.startswith(b'*a'): continue
        size = ah(body[2:4])
        cm = bytes(ah(body[i:i + 2]) for i in range(4, 4 + 2 * (size + 5), 2))
        if (cm[0], cm[1], cm[3] | cm[4] << 8) != (5, 1, 0x0240): continue
        data = cm[5:]
        pos = 2
        while pos < len(data):
            end = pos + data[pos] + 1
            command = data[pos + 1]
            args = data[pos + 2:end]
            if command in (0x46, 0x4c, 0x4d):
                assert args[0] < len(bitmaps), (title, count, command, args[0])
                if command == 0x4c:
                    assert args[3] < bitmaps[args[0]]['fragments']
            if command == 0x48:
                assert args[2] < len(fonts)
            pos = end
        count += 1
    assert count == expected, (title, count, expected)
    frames += count
print(f'{frames} captured RC frames and all referenced English bitmaps/fonts validated.')
