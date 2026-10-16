"""Build the size cofactor on the faster retained boundary-stage parent.

Do not carry forward the next-ready cofactor's measured timing regression.
All other parent sources, definitions and native build guards stay unchanged.
"""
import inspect
from pathlib import Path
import subprocess
import sys

import prepare_sfetch_interior_cofactor as recipe
import run_sfetch_interior_cofactor as leaf_test

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'fetchguard'))
import build_decode_bus_core as previous

MODEL='e604895eeb367591b16a564d4b91b282a30a6c65b3bee5c7f81823c5e48ae56a'
native=previous.native


def check_leaf(leaf):
    start,done=[native.load(leaf/n) for n in ('started.json','closed.json')]
    assert done['passed'] and done['proof_passed'] and done['pins_unchanged'] and not done['errors']
    assert not done['whole_core'] and not done['standard_suite'] and not done['physical_fpga']
    assert not any(done['memory_events'][k] for k in ('oom','oom_kill','oom_group_kill'))
    assert [(r['profile'],r['mode'],r['native_exit']) for r in done['rows']]==[
        ('default','positive',0),('interior16','positive',0),
        *[('interior16',mode,1) for mode in leaf_test.MODES[1:]]]
    props=dict(s.split('=',1) for s in subprocess.check_output([
        'systemctl','--user','show','ventium-sfetch-interior-leaf-oct16-r1.service',
        '-p','InvocationID','-p','MainPID','-p','SubState','-p','Result','-p','ExecMainStatus'],
        text=True,timeout=10).splitlines())
    assert props==dict(InvocationID=start['invocation'],MainPID='0',SubState='exited',
                       Result='success',ExecMainStatus='0')
    for row in done['rows']:
        assert row['passed'] and row['compile_exit']==0 and row['waited'] and row['proc_gone']
        assert row['affinity']==[18,19] and not Path('/proc',str(row['pid'])).exists()
        work=leaf/(row['profile']+'-'+row['mode'])
        log=(work/'native.log').read_text()
        if row['mode']=='positive':
            assert 'SFETCH-INTERIOR-COFACTOR-OK checks=196608' in log and 'FATAL' not in log
        else:
            assert 'SFETCH-INTERIOR-MISMATCH' in log
    assert (leaf/'proof.smt2').read_text()==leaf_test.symbolic()[0]
    assert (leaf/'proof.stdout').read_text().splitlines()==leaf_test.symbolic()[1]
    assert not (leaf/'proof.stderr').read_text()
    pins=dict(start['pins'])|done['artifacts']
    for p in (leaf/'started.json',leaf/'closed.json',Path(__file__),Path(previous.__file__)):
        pins[str(p.resolve())]=native.sha(p)
    assert native.sha(leaf/'core.sv')==done['derivative_sha256'] and native.stable(pins)
    return pins


def adapted_main():
    assert native.sha(previous.__file__)=='8fa9b0f1db1225b6feeb6aa2e9c73262657bbc24651530bc128724d49c3132e6'
    text=inspect.getsource(previous.main)
    for old,new in (("(leaf/'core_bus_driver.svh')","(leaf/'core.sv')"),
        ("'tb_decode_bus_'","'tb_sfetch_interior_'"),
        ('Only no-request DECODE address payload; MMU/fault/request authority unchanged',
         'Interior fetch-size output cofactor only; exact clip, requests, stages and cycles unchanged')):
        assert text.count(old)==1;text=text.replace(old,new)
    return text


def main():
    namespace=dict(previous.__dict__,__file__=__file__,recipe=recipe,MODEL=MODEL,check_leaf=check_leaf)
    exec(compile(adapted_main(),__file__,'exec'),namespace)
    return namespace['main']()


if __name__=='__main__':raise SystemExit(main())
