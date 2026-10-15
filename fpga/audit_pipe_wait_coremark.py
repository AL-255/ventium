"""Regrade unchanged short seeds for the wait cofactor; not valid scores."""
from pathlib import Path

original_adapter = Path(__file__).with_name('audit_decode_bus_coremark.py')
text = original_adapter.read_text()
for old, new in (
    ('branch-address-soc-r1', 'demand-size-soc-r1'),
    ('7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68',
     '55e9255323354c314c102b2e7362ad3f9a5dfb1ca9c4e613a289f379936b6fce'),
    ('for p in (original,Path(__file__),root/',
     'for p in (original,original_adapter,Path(__file__),root/'),
):
    assert text.count(old) == 1, old
    text = text.replace(old, new)
exec(compile(text, str(__file__), 'exec'), globals())
