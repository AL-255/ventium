"""Unchanged short cold-PC controls for the branch-address experiment.

Identity-only adapter; no new CRC/clock tolerance or valid-score claim.
"""
import hashlib
from pathlib import Path

original_adapter=Path(__file__).with_name('run_pair_next_disjoint_coremark.py')
text=original_adapter.read_text()
assert hashlib.sha256(text.encode()).hexdigest()=='c5c113bf7f5fd5fba5449dc0e0349af65c24df1c964dc71c1a3a26fa0fa4a4a3'
for old,new in (
    ('ventium-pair-next-disjoint-cm10-','ventium-branch-address-cm10-'),
    ('original,original_driver,Path(native_observation.__file__)',
     'original,original_driver,original_adapter,Path(native_observation.__file__)'),
):
    assert text.count(old)==1,old;text=text.replace(old,new)
exec(compile(text,str(__file__),'exec'),globals())
