"""Qualify private reference helpers on the unchanged 192 cold pointer images.

The matching closed RTL traces are reused, not regenerated or trimmed. The
control must equal pinned QEMU's entire trace; candidate must equal RTL's.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import traceback

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO/'verif/diff'))
import tracefmt


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def save(p, value):
    with p.open('x') as f:
        json.dump(value, f, indent=2)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('build','witness','out'):
        ap.add_argument('--'+name, type=Path, required=True)
    a = ap.parse_args()
    build, witness = a.build.resolve(strict=True), a.witness.resolve(strict=True)
    root = a.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    assert os.sched_getaffinity(0)==set(range(8,16)) and os.environ['INVOCATION_ID']
    assert shutil.disk_usage(scratch).free>4*1024**3+128*1024**2
    built = json.loads((build/'closed.json').read_text())
    assert built['passed'] and built['pins_unchanged'] and not built['errors']
    assert all(sha(p)==h for p,h in built['pins'].items())
    models = {r['variant']:Path(r['binary']) for r in built['rows']}
    assert set(models)=={'control','candidate','wrong-v86-mode'}
    assert all(sha(r['binary'])==r['sha256'] for r in built['rows'])
    old = json.loads((witness/'closed.json').read_text())
    started = json.loads((witness/'started.json').read_text())
    assert len(old['rows'])==192 and all(r['rtl_self_check'] and r['qemu_exit']==135 for r in old['rows'])
    pins = dict(built['pins'])
    pins.update(started['pins'])
    for row in old['rows']:
        pins.update(row['artifacts'])
    producer, compare = REPO/'verif/qemu-trace/gen_trace.py', REPO/'verif/diff/compare.py'
    bios = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/pc-bios'
    for p in (Path(__file__), producer, compare, REPO/'verif/diff/tracefmt.py',
              build/'closed.json', witness/'closed.json', *models.values(), bios/'vgabios-stdvga.bin'):
        pins[str(p.resolve())] = sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    root.mkdir()
    cases = started['cases']
    save(root/'started.json', dict(pins=pins, cases=cases, models={k:str(v) for k,v in models.items()},
        invocation=os.environ['INVOCATION_ID'], affinity=sorted(os.sched_getaffinity(0)),
        reused_closed_rtl=str(witness), canonical_oracle_changed=False))
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VTM_','TB_','AXI_','QEMU_'))}
    env['PYTHONDONTWRITEBYTECODE']='1'
    def case_run(index, case):
        folder = root/case['name']
        folder.mkdir()
        original = witness/case['name']
        image = original/'probe.bin'
        pair = [8+2*(index%4),9+2*(index%4)]
        def run(label, command):
            actual = ['taskset','-c',','.join(map(str,pair)),'timeout','--kill-after=2s','20s',*map(str,command)]
            save(folder/(label+'-command.json'),actual)
            seen = {}
            with (folder/(label+'.log')).open('x') as log:
                child = subprocess.Popen(actual,env=env,stdout=log,stderr=subprocess.STDOUT)
                try:
                    while child.poll() is None:
                        queue=[child.pid]
                        while queue:
                            pid=queue.pop()
                            try:
                                proc=Path('/proc')/str(pid)
                                queue.extend(map(int,(proc/'task'/str(pid)/'children').read_text().split()))
                                if (proc/'exe').readlink().name=='qemu-system-i386':
                                    affinity=sorted(os.sched_getaffinity(pid))
                                    assert affinity==pair
                                    seen[pid]=affinity
                            except (FileNotFoundError,ProcessLookupError):
                                pass
                        time.sleep(.002)
                    code=child.wait()
                finally:
                    if child.poll() is None:
                        child.terminate(); child.wait(timeout=5)
            save(folder/(label+'-native.json'),dict(exit=code, observed_affinity=seen))
            assert seen, (label,'no actual QEMU child observed')
            return code
        row=dict(case=case['defines'], variants={})
        for label, model in models.items():
            q = run(label+'-native',[model,'-L',bios,'-display','none','-monitor','none','-serial','none',
                '-no-reboot','-machine','pc','-cpu','pentium','-m','32',
                '-device','isa-debug-exit,iobase=0xf4,iosize=0x04','-bios',image])
            trace = folder/(label+'.vtrace')
            g = run(label+'-trace',[sys.executable,'-B',producer,'--system','--qemu',model,'--cpu','pentium',
                '--image',image,'--image-mode','bios','--max-insn','3000','--port',str(15500+index),
                '--out',trace,'--args','-L',bios])
            assert g==0
            reference = original/('golden.vtrace' if label=='control' else 'rtl.vtrace')
            compare_pair = (reference, trace) if label=='control' else (trace, reference)
            command=[sys.executable,'-B',str(compare),'--mode','func',*map(str,compare_pair)]
            save(folder/(label+'-compare-command.json'),command)
            with (folder/(label+'-compare.log')).open('x') as log:
                d=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=20).returncode
            row['variants'][label]=dict(native_exit=q, trace_exit=g, compare_exit=d,
                                        records=len(tracefmt.read_trace(str(trace)).records))
            if label=='control':
                assert q==135 and d==0
            elif label=='candidate':
                assert q==133 and d==0
            else:
                assert q in (133,135) and ((d==0)==(q==133))
                if case['defines']['MODE']!=2:
                    assert q==133 and d==0
        row['artifacts']={str(p):sha(p) for p in folder.iterdir() if p.is_file()}
        save(folder/'closed.json',row)
        return row
    begin=time.monotonic()
    result=dict(passed=False,rows=[],errors=[],canonical_gate_passed=False,hardware_acceptance=False,
                standard_suite=False,gameplay_ipc=None)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures={pool.submit(case_run,i,c):c for i,c in enumerate(cases)}
        for future in concurrent.futures.as_completed(futures):
            try:
                result['rows'].append(future.result())
            except Exception as error:
                result['errors'].append(dict(case=futures[future],error=repr(error),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['mutant_detected']=sum(r['variants']['wrong-v86-mode']['native_exit']==135 for r in result['rows'])
    result['passed']=len(result['rows'])==192 and not result['errors'] and result['pins_unchanged'] and result['mutant_detected']>0
    save(root/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='rows'},indent=2),flush=True)
    return int(not result['passed'])


if __name__=='__main__':
    raise SystemExit(main())
