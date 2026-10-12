#!/usr/bin/env python3
"""Adopt the memory-divide synthesis and queue its guarded native clock audit.

Use the exact reviewed wait/closure/controller behavior from fetch-probe; only
candidate identities change. Never start or restart synthesis, route, or deploy.
"""
import hashlib
from pathlib import Path

original = Path(__file__).with_name('run_fetch_probe_timing.py')
text = original.read_text()
digest = 'a0ff546de75b33f4a21f062bffc9603f32d2f9210d2f043b7397b8d621a9d5ac'
assert hashlib.sha256(text.encode()).hexdigest() == digest
old = 'from prepare_fetch_probe_synthesis import PARENT as ROOT, MANIFEST, MODEL'
assert text.count(old) == 1
text = text.replace(old, 'from prepare_memdiv_capture_synthesis import ROOT, MANIFEST, MODEL')
assert text.count('ventium-fetch-probe-') == 2
text = text.replace('ventium-fetch-probe-', 'ventium-memdiv-')
assert text.count("'probe-") == 8
text = text.replace("'probe-", "'memdiv-")
anchor = "    assert all(sha(p) == h for p,h in pins.items())\n"
assert text.count(anchor) == 3
first = text.index(anchor)
text = text[:first]+"    pins["+repr(str(original))+'] = '+repr(digest)+'\n'+text[first:]
exec(compile(text, str(original), 'exec'), globals())
