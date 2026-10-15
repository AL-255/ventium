"""Regrade the V-result candidate's two short controls; no valid-score claim."""
from pathlib import Path

original_adapter=Path(__file__).with_name('audit_decode_bus_coremark.py')
text=original_adapter.read_text()
for old,new in (
    ('branch-address-soc-r1','pipe-wait-soc-r1'),
    ('7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68',
     'b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e'),
    ('for p in (original,Path(__file__),root/',
     'for p in (original,original_adapter,Path(__file__),root/'),
):
    assert text.count(old)==1,old;text=text.replace(old,new)
exec(compile(text,str(__file__),'exec'),globals())
