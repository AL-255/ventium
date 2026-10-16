"""Regrade both short cold controls against the immediate V-result parent."""
from pathlib import Path

original_adapter=Path(__file__).with_name('audit_decode_bus_coremark.py')
text=original_adapter.read_text()
for old,new in (
    ('branch-address-soc-r1','v-result-carry-soc-r1'),
    ('7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68',
     '810840218013b9e8ec8f3fbc1f0f39da8dbdcbd8b9c09021ba03ea27036014bd'),
    ('for p in (original,Path(__file__),root/',
     'for p in (original,original_adapter,Path(__file__),root/')):
    assert text.count(old)==1;text=text.replace(old,new)
exec(compile(text,str(__file__),'exec'),globals())
