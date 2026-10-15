"""Regrade the unchanged short seeds on the early bus model, not valid scores."""
import hashlib
from pathlib import Path

original_adapter = Path(__file__).with_name('audit_decode_bus_coremark.py')
text = original_adapter.read_text()
for old, new in (
    ('branch-address-soc-r1', 'decode-bus-soc-r1'),
    ('7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68',
     '593833e1650b5869373abbd74debcc63d15ea53eca1aa87f62e833982ead2fe9'),
    ('for p in (original,Path(__file__),root/',
     'for p in (original,original_adapter,Path(__file__),root/'),
):
    assert text.count(old) == 1, old
    text = text.replace(old, new)
exec(compile(text, str(__file__), 'exec'), globals())
