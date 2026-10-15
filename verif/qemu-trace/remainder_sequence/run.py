"""Bounded native/private-reference sequence tests; never promote an oracle."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import time

import oracle

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[2]


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def save(p,value):
    with p.open('x') as f:json.dump(value,f,indent=2)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',required=True,type=Path)
    root=parser.parse_args().out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and os.sched_getaffinity(0)=={12}
    assert shutil.disk_usage(scratch).free>4*1024**3+128*1024**2 and os.environ['INVOCATION_ID']
    build=scratch/'ventium-qemu-frndint.wRXifJwr/build-r1'
    built=json.loads((build/'closed.json').read_text());candidate=Path(built['binary'])
    assert built['passed'] and built['pins_unchanged']
    assert sha(candidate)==built['sha256']=='da49b8105f90b4257494a7b7f1e57e5428fa66dc667278b824d381d9d0e9f84d'
    control=scratch/'ventium-qemu-preexit-r2.81Yu1ixT/observer-build/qemu-i386'
    assert sha(control)=='52a9ca27d2d1bb40a360a7c2e881b8fe63b0795f285ae823b96e33e75ef0ff31'
    manual=REPO/'ventium-refs/01-intel-canonical/241430-004_Pentium_Processor_Family_Developers_Manual_Volume_3_Jul95.pdf'
    inputs=(Path(__file__),HERE/'probe.c',Path(oracle.__file__),candidate,control,build/'closed.json',manual)
    pins={str(p):sha(p) for p in inputs};root.mkdir()
    rows=oracle.cases();save(root/'cases.json',rows)
    payload=b''.join(struct.pack('<10I',r['id'],r['kind'],r['cw'],r['sw'],
        r['a'][0],r['a'][1]&0xffffffff,r['a'][1]>>32,r['b'][0],r['b'][1]&0xffffffff,r['b'][1]>>32) for r in rows)
    (root/'stdin.bin').write_bytes(payload)
    save(root/'started.json',dict(pins=pins,cases=len(rows),invocation=os.environ['INVOCATION_ID']))
    cmd=['gcc','-m32','-march=pentium','-mno-sse','-O2','-fno-pic','-fno-pie',
        '-fno-stack-protector','-nostdlib','-static','-Wl,--build-id=none,-e,_start',str(HERE/'probe.c'),'-o',str(root/'probe')]
    with (root/'compile.log').open('x') as f:
        done=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,timeout=30)
    save(root/'compile.json',dict(command=cmd,native_exit=done.returncode));assert done.returncode==0
    results=[];begin=time.monotonic()
    for name,cmd in (('native',[str(root/'probe')]),('control',[str(control),'-cpu','pentium',str(root/'probe')]),
                     ('candidate',[str(candidate),'-cpu','pentium',str(root/'probe')])):
        with (root/'stdin.bin').open('rb') as inp,(root/(name+'.bin')).open('xb') as out,(root/(name+'.stderr')).open('x') as err:
            child=subprocess.Popen(cmd,stdin=inp,stdout=out,stderr=err);observed=[];start=time.monotonic()
            try:
                while child.poll() is None:
                    try:observed.append(sorted(os.sched_getaffinity(child.pid)))
                    except ProcessLookupError:pass
                    assert time.monotonic()-start<90,name+' timeout'
                    time.sleep(.001)
                code=child.wait()
            finally:
                if child.poll() is None:child.kill()
                child.wait()
        save(root/(name+'.native.json'),dict(command=cmd,native_exit=code,actual_wait=True,
            reaped=True,observed_affinity=sorted(set(tuple(x) for x in observed)),sha256=sha(root/(name+'.bin'))))
        assert code==0 and observed and all(x==[12] for x in observed)
        checked=oracle.grade(rows,(root/(name+'.bin')).read_bytes())
        save(root/(name+'.graded.json'),checked)
        results.append(dict(name=name,**{k:v for k,v in checked.items() if k!='errors'},mismatches=len(checked['errors'])))
        print(json.dumps(results[-1]),flush=True)
    stable=all(sha(p)==h for p,h in pins.items())
    result=dict(passed=stable and all(r['passed'] for r in results if r['name']!='control'),
        pins_unchanged=stable,results=results,seconds=time.monotonic()-begin,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    save(root/'closed.json',result);print(json.dumps(result),flush=True)
    return int(not result['passed'])


if __name__=='__main__':raise SystemExit(main())
