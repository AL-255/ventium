"""Independently regrade unchanged fetch-boundary traces on the prefix model."""
import hashlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO/'verif/l1/audit_way_banked_fetch.py'
SOURCE_SHA = 'c10d8a35cdc8199a8f4d306513809eef4dcfeea36c481efdf93a0d1b49cf8cba'
text = SOURCE.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == SOURCE_SHA
for before, after, count in (
    ('way-banked', 'prefix-payload', 3),
    ("('parent','fp-compare')", "('parent','fast-segment')", 1),
    ("'parent':'5de1eb0813bb02f252c8aea444a41a4fdc121e028843aabbf6bcd9e41a4a62d8'",
     "'parent':'1fb2f09e09ccddfca30ef2423e96226ddae40b4df44b4089204bed2cd79e505c'", 1),
    ("'candidate':'139e45dbd7a75a7ddffc19526387ab66bd01908908585aaae7f68c90059799b7'",
     "'candidate':'e3ec298c7049e348ba7ebb6921ef4cdc875faf71cdda76810e124c05a16041e6'", 1),
    ("    pins=dict(started['pins'])",
     "    pins=dict(started['pins'])\n    pins["+repr(str(SOURCE))+']='+repr(SOURCE_SHA), 1)):
    assert text.count(before) == count, before
    text = text.replace(before, after)
exec(compile(text, str(__file__), 'exec'), globals())
