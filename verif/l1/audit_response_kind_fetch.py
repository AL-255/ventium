"""Regrade the original full fetch-boundary traces, witnesses and native exits."""
import hashlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO/'verif/l1/audit_way_banked_fetch.py'
SOURCE_SHA = 'c10d8a35cdc8199a8f4d306513809eef4dcfeea36c481efdf93a0d1b49cf8cba'
text = SOURCE.read_text()
assert hashlib.sha256(text.encode()).hexdigest() == SOURCE_SHA
for before, after, count in (
    ('way-banked', 'response-kind', 3),
    ("('parent','fp-compare')", "('parent','prefix-payload')", 1),
    ("'parent':'5de1eb0813bb02f252c8aea444a41a4fdc121e028843aabbf6bcd9e41a4a62d8'",
     "'parent':'e3ec298c7049e348ba7ebb6921ef4cdc875faf71cdda76810e124c05a16041e6'", 1),
    ("'candidate':'139e45dbd7a75a7ddffc19526387ab66bd01908908585aaae7f68c90059799b7'",
     "'candidate':'da6744ec11615ca7900a6ed132bc9e64471dd567e363d33985864e50719be6dd'", 1),
    ("    pins=dict(started['pins'])",
     "    pins=dict(started['pins'])\n    pins["+repr(str(SOURCE))+']='+repr(SOURCE_SHA), 1)):
    assert text.count(before) == count, before
    text = text.replace(before, after)
exec(compile(text, str(__file__), 'exec'), globals())
