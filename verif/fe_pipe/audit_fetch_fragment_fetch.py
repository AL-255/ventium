"""Regrade original closed fetch records; explicitly retain old tool identities."""
import hashlib
from pathlib import Path

import run_fetch_fragment_owned as tooling

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO/'verif/l1/audit_way_banked_fetch.py'
SOURCE_SHA = 'c10d8a35cdc8199a8f4d306513809eef4dcfeea36c481efdf93a0d1b49cf8cba'
text = SOURCE.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == SOURCE_SHA
for old, new, count in (
    ('way-banked', 'fetch-fragment', 3),
    ('ventium-fetch-fragment-fetch-oct14-r1.service', 'ventium-fetch-fragment-fetch-oct15-r1.service', 1),
    ("('parent','fp-compare')", "('parent','prefix-payload')", 1),
    ("'parent':'5de1eb0813bb02f252c8aea444a41a4fdc121e028843aabbf6bcd9e41a4a62d8'",
     "'parent':'e3ec298c7049e348ba7ebb6921ef4cdc875faf71cdda76810e124c05a16041e6'", 1),
    ("'candidate':'139e45dbd7a75a7ddffc19526387ab66bd01908908585aaae7f68c90059799b7'",
     "'candidate':"+repr(tooling.MODEL), 1),
    ("    pins=dict(started['pins'])",
     "    pins=dict(started['pins'])\n    tooling.qualify_tooling(pins)\n    pins["+repr(str(SOURCE))+']='+repr(SOURCE_SHA), 1)):
    assert text.count(old) == count, old
    text = text.replace(old, new)
exec(compile(text, str(__file__), 'exec'), globals())
