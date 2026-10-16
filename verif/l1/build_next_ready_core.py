"""Build the single-L1 readiness cofactor on the measured boundary-stage core."""
import inspect
from pathlib import Path
import sys

import prepare_next_ready_cofactor as recipe
from run_next_ready_cofactor_leaf import ROOT

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'fetchguard'))
import build_decode_bus_core as previous

MODEL='e604895eeb367591b16a564d4b91b282a30a6c65b3bee5c7f81823c5e48ae56a'
native=previous.native


def check_leaf(leaf):
    start,done=[native.load(leaf/n) for n in ('started.json','closed.json')]
    assert done['passed'] and done['proof_passed'] and done['pins_unchanged'] and not done['errors']
    assert [(r['profile'],r['mode'],r['native_exit']) for r in done['rows']]==[
        *[(p,'positive',0) for p in ('chain','prime','fill','dual','full')],
        *[('full',m,1) for m in ('drop-request','current-tag','drop-old-cacheability')]]
    pins=dict(start['pins'])
    for row in done['rows']:pins.update(row['artifacts'])
    cache=ROOT/'next-ready-cache-r3';closed=native.load(cache/'closed.json')
    assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
    assert [(r['label'],r['build_exit'],r['native_exit']) for r in closed['rows']]==[
        ('positive-lut1',0,0),('positive-lut0',0,0),('mutant-lut1',0,1)]
    assert not any(closed['memory_events'][k] for k in ('oom','oom_kill','oom_group_kill'))
    pins.update(closed['pins'])
    for name in ('positive-lut1','positive-lut0'):
        log=(cache/(name+'-native.log')).read_text()
        assert 'NEXT-READY-CACHE-OK samples=295042' in log
        assert 'NEXT-READY-DFILL-OK checks=320' in log
    for p in cache.iterdir():
        if p.is_file():pins[str(p)]=native.sha(p)
    for p in (leaf/'started.json',leaf/'closed.json',leaf/'ven_l1d.sv',
              leaf/'proof.smt2',leaf/'proof.stdout',leaf/'proof.stderr',Path(previous.__file__),Path(__file__)):
        pins[str(p.resolve())]=native.sha(p)
    assert native.sha(leaf/'ven_l1d.sv')==done['derivative_sha256']
    assert native.stable(pins)
    return pins


def adapted_main():
    text=inspect.getsource(previous.main)
    for old,new in (("(leaf/'core_bus_driver.svh')","(leaf/'ven_l1d.sv')"),
        ("'tb_decode_bus_'","'tb_next_ready_'"),
        ('Only no-request DECODE address payload; MMU/fault/request authority unchanged',
         'Next-read readiness cofactor only; same requests, cache ownership and cycle behavior')):
        assert text.count(old)==1;text=text.replace(old,new)
    return text


def main():
    namespace=dict(previous.__dict__,__file__=__file__,recipe=recipe,MODEL=MODEL,check_leaf=check_leaf)
    exec(compile(adapted_main(),__file__,'exec'),namespace)
    return namespace['main']()


if __name__=='__main__':raise SystemExit(main())
