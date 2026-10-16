"""Build the width-payload experiment on the faster boundary-stage core."""
import inspect
from pathlib import Path
import subprocess
import sys

import prepare_prime_width_payload as recipe
import run_prime_width_payload as leaf_test

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'fetchguard'))
import build_decode_bus_core as previous

MODEL='e604895eeb367591b16a564d4b91b282a30a6c65b3bee5c7f81823c5e48ae56a'
native=previous.native


def check_leaf(leaf):
    start,done=[native.load(leaf/n) for n in ('started.json','closed.json')]
    assert done['passed'] and done['pins_unchanged'] and not done['errors']
    assert not done['whole_core'] and not done['standard_suite'] and not done['physical_fpga']
    assert not any(done['memory_events'][k] for k in ('oom','oom_kill','oom_group_kill'))
    assert [(r['span'],r['mode'],r['native_exit']) for r in done['rows']]==[
        (False,'positive',0),(True,'positive',0),*[(True,m,1) for m in leaf_test.MODES[1:]]]
    owner=dict(s.split('=',1) for s in subprocess.check_output([
        'systemctl','--user','show','ventium-prime-width-leaf-oct16-r1.service',
        '-p','InvocationID','-p','MainPID','-p','SubState','-p','Result','-p','ExecMainStatus'],
        text=True,timeout=10).splitlines())
    assert owner==dict(InvocationID=start['invocation'],MainPID='0',SubState='exited',
                       Result='success',ExecMainStatus='0')
    for row in done['rows']:
        assert row['passed'] and row['compile_exit']==0 and row['waited'] and row['proc_gone']
        assert row['affinity']==[18,19,20,21] and not Path('/proc',str(row['pid'])).exists()
        work=leaf/(('span-' if row['span'] else 'legacy-')+row['mode'])
        log=(work/'native.log').read_text()
        if row['mode']=='positive':
            assert 'PRIME-WIDTH-OK' in log and 'samples=65536' in log and 'FATAL' not in log
        else:
            assert any(s in log for s in ('PRIME_WIDTH_MISMATCH','PRIME_WIDTH_STROBE_MISMATCH',
                                         'MC_ADDRESS_PAYLOAD_MISMATCH'))
    pins=dict(start['pins'])|done['artifacts']
    for p in (leaf/'started.json',leaf/'closed.json',Path(__file__),Path(previous.__file__)):
        pins[str(p.resolve())]=native.sha(p)
    assert native.sha(leaf/'core_mem_chain.svh')==done['derivative_sha256'] and native.stable(pins)
    return pins


def adapted_main():
    assert native.sha(previous.__file__)=='8fa9b0f1db1225b6feeb6aa2e9c73262657bbc24651530bc128724d49c3132e6'
    text=inspect.getsource(previous.main)
    for old,new in (("(leaf/'core_bus_driver.svh')","(leaf/'core_mem_chain.svh')"),
        ("'tb_decode_bus_'","'tb_prime_width_'"),
        ('Only no-request DECODE address payload; MMU/fault/request authority unchanged',
         'Early prime width payload only; checked eligibility and offered strobes asserted against parent')):
        assert text.count(old)==1
        text=text.replace(old,new)
    return text


def main():
    scope=dict(previous.__dict__,__file__=__file__,recipe=recipe,MODEL=MODEL,check_leaf=check_leaf)
    exec(compile(adapted_main(),__file__,'exec'),scope)
    return scope['main']()


if __name__=='__main__': raise SystemExit(main())
