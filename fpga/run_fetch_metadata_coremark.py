"""Run unchanged short cold CoreMark controls for the three-file transfer.

Identity-only adapter: preserve CRC policy, native observation, reaping, mode,
affinity and resource checks. These runs cannot provide a valid CoreMark score.
"""
import hashlib
from pathlib import Path

original_adapter=Path(__file__).with_name('run_pair_next_disjoint_coremark.py')
text=original_adapter.read_text()
assert hashlib.sha256(text.encode()).hexdigest()=='c5c113bf7f5fd5fba5449dc0e0349af65c24df1c964dc71c1a3a26fa0fa4a4a3'
for old,new in (
    ('ventium-pair-next-disjoint-cm10-','ventium-fetch-metadata-cm10-'),
    ('original,original_driver,Path(native_observation.__file__)',
     'original,original_driver,original_adapter,Path(native_observation.__file__)'),
):
    assert text.count(old)==1,old
    text=text.replace(old,new)
exec(compile(text,str(__file__),'exec'),globals())
