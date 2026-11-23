#!/usr/bin/env python3
"""Builds assets/studio/index.html: Paramix Studio (third_party/paramix-studio/dist, GPL-3.0)
with the app's bridge (assets/studio/bridge.js) inlined first in <head>, so Web Serial, file
downloads and tab jumps go through the app. Run again after updating Paramix."""
import pathlib
root = pathlib.Path(__file__).resolve().parent.parent
html = (root / 'third_party/paramix-studio/dist/index.html').read_text(encoding='utf-8')
bridge = (root / 'assets/studio/bridge.js').read_text(encoding='utf-8')
tag = '<head>'
i = html.find(tag)
assert i >= 0, 'no <head>'
i += len(tag)
out = html[:i] + '\n<script>\n' + bridge + '\n</script>\n' + html[i:]
(root / 'assets/studio/index.html').write_text(out, encoding='utf-8')
print('assets/studio/index.html', len(out), 'bytes')
