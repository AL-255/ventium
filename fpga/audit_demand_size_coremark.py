"""Regrade unchanged short seeds on the demand-width model; not valid scores."""
from pathlib import Path

original_adapter = Path(__file__).with_name('audit_decode_bus_coremark.py')
text = original_adapter.read_text()
for old, new in (
    ('branch-address-soc-r1', 'early-bus-soc-r1'),
    ('7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68',
     '20cef474c2a10fca2ec27b26f09d88e9b7dc70ead963fab09ce28a6baaa4d60d'),
    ('for p in (original,Path(__file__),root/',
     'for p in (original,original_adapter,Path(__file__),root/'),
):
    assert text.count(old) == 1, old
    text = text.replace(old, new)
exec(compile(text, str(__file__), 'exec'), globals())
