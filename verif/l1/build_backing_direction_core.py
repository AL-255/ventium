"""Build only the tested direction delta on the current V-result CPU source."""
import inspect
from pathlib import Path
import sys

import prepare_backing_direction as recipe
from run_backing_direction_leaf import ROOT

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'fetchguard'))
import build_decode_bus_core as predecessor

MODEL='a8e5d55b7704f2449002c71af8db1c5c2fe7ae908669fc5dbf2e663d3a59ff73'
native=predecessor.native


def check_leaf(leaf):
    start,done=[native.load(leaf/n) for n in ('started.json','closed.json')]
    assert done['passed'] and done['pins_unchanged'] and not done['errors']
    assert [(r['profile'],r['mode'],r['native_exit']) for r in done['rows']]==[
        ('default','positive',0),('dual','positive',0),('full','positive',0),
        *[('full',m,1) for m in ('late-direction','fill-write','lost-admission','wrong-payload')]]
    pins=dict(start['pins'])
    for row in done['rows']: pins.update(row['artifacts'])
    axi=ROOT/'backing-direction-axi-r3'
    result=native.load(axi/'closed.json')
    assert result['passed'] and result['pins_unchanged'] and not result['errors']
    assert result['full_l1'] and result['real_axi_master'] and not result['whole_core']
    assert [(r['mode'],r['build_exit'],r['native_exit']) for r in result['rows']]==[
        ('positive',0,0),('fill-write-negative',0,1)]
    assert not any(result['memory_events'][k] for k in ('oom','oom_kill','oom_group_kill'))
    log=(axi/'positive/native.log').read_text()
    assert 'BACKING-DIRECTION-AXI-OK checks=2387 stores=68 pairs=3 load_stores=1 quad=1 blocked=30 idle_direction_changes=2024 full_queue=84' in log
    pins.update(result['pins'])
    for row in result['rows']:pins.update(row['artifacts'])
    for p in (leaf/'started.json',leaf/'closed.json',leaf/'ven_l1d.sv',axi/'started.json',
              axi/'closed.json',Path(predecessor.__file__),Path(__file__)):
        pins[str(p.resolve())]=native.sha(p)
    assert native.sha(leaf/'ven_l1d.sv')==done['derivative_sha256']
    assert native.stable(pins)
    return pins


def adapted_main():
    source=inspect.getsource(predecessor.main)
    for old,new in (
        ("(leaf/'core_bus_driver.svh')","(leaf/'ven_l1d.sv')"),
        ("'tb_decode_bus_'","'tb_backing_direction_'"),
        ("contract_change='Only no-request DECODE address payload; MMU/fault/request authority unchanged'",
         "contract_change='Early inactive backing direction only; active packets, admission and cycles unchanged'")):
        assert source.count(old)==1
        source=source.replace(old,new)
    return source


def main():
    recipe.FILE='rtl/mem/ven_l1d.sv'
    namespace=dict(predecessor.__dict__)
    namespace.update(__file__=__file__,recipe=recipe,MODEL=MODEL,check_leaf=check_leaf)
    exec(compile(adapted_main(),__file__,'exec'),namespace)
    return namespace['main']()


if __name__=='__main__':raise SystemExit(main())
