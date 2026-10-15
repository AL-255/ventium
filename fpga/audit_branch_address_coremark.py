"""Regrade the short cold controls; no valid-score or standard-suite claim."""
import hashlib
from pathlib import Path

original_adapter=Path(__file__).with_name('audit_pair_next_disjoint_coremark.py')
text=original_adapter.read_text()
assert hashlib.sha256(text.encode()).hexdigest()=='16e592f59a071040658bfd7b301bf1c2e1ed16cde191e7b920e6953062cba003'
for old,new in (
    ('b542e94d172defa3528ef0e2faf80a636a5072aa99e63d6ab6ff56335acba2a2',
     '0a1f097ee98c816eef72fc432a17fe09e77d7912651c548ad14853512e8edc52'),
    ('original,original_driver,Path(__file__)',
     'original,original_driver,original_adapter,Path(__file__)'),
):
    assert text.count(old)==1,old;text=text.replace(old,new)
exec(compile(text,str(__file__),'exec'),globals())
