"""Fresh actual-instruction sequence/PC tests, with a pinned unfixed control."""
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
import precision_oracle
import prepare

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[2]
PARENT=Path('/home/yukidama/external/tmp/ventium-qemu-frndint.wRXifJwr/build-r1')


def sha(path):
    with Path(path).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def save(path,value):
    with path.open('x') as f:json.dump(value,f,indent=2)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',required=True,type=Path)
    ap.add_argument('--build',required=True,type=Path)
    ap.add_argument('--precision-only',action='store_true')
    args=ap.parse_args();root=args.out.resolve();build=args.build.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert build.is_relative_to(scratch) and Path(os.environ['TMPDIR']).resolve()==scratch
    assert os.sched_getaffinity(0)=={12} and os.environ['INVOCATION_ID']
    assert shutil.disk_usage(scratch).free>4*1024**3+128*1024**2
    parent=json.loads((PARENT/'closed.json').read_text());control=Path(parent['binary'])
    assert parent['passed'] and parent['pins_unchanged']
    assert sha(control)==parent['sha256']=='da49b8105f90b4257494a7b7f1e57e5428fa66dc667278b824d381d9d0e9f84d'
    built=json.loads((build/'closed.json').read_text());candidate=Path(built['binary'])
    assert built['passed'] and built['pins_unchanged'] and sha(candidate)==built['sha256']
    before=json.loads((PARENT/'source.json').read_text())['after']
    after=json.loads((build/'source.json').read_text())['after']
    assert before.keys()==after.keys()
    fixed=build!=PARENT.resolve()
    assert fixed or args.precision_only
    expected=prepare.transform((PARENT/'source'/prepare.HELPER).read_text())
    assert [n for n in before if before[n]!=after[n]]==([prepare.HELPER] if fixed else [])
    if fixed:assert (build/'source'/prepare.HELPER).read_text()==expected
    pins={str(build/'source'/n):h for n,h in after.items()}
    manual=REPO/'ventium-refs/01-intel-canonical/241430-004_Pentium_Processor_Family_Developers_Manual_Volume_3_Jul95.pdf'
    for path in (Path(__file__),HERE/'probe.c',HERE/'precision_probe.c',Path(oracle.__file__),
                 Path(precision_oracle.__file__),Path(prepare.__file__),candidate,control,manual,
                 build/'closed.json',build/'source.json',PARENT/'closed.json',PARENT/'source.json'):
        pins[str(path)]=sha(path)
    assert all(sha(path)==h for path,h in pins.items())
    root.mkdir();begin=time.monotonic()
    save(root/'started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],fixed=fixed,
        build=str(build),binary_sha256=sha(candidate),precision_only=args.precision_only))
    results=[]
    modes=[('precision',precision_oracle,'precision_probe.c')]
    if not args.precision_only:modes.insert(0,('sequence',oracle,'probe.c'))
    for mode,grader,source in modes:
        dest=root/mode;dest.mkdir();rows=grader.cases();save(dest/'cases.json',rows)
        payload=b''.join(struct.pack('<10I',r['id'],r['kind'],r['cw'],r['sw'],
            r['a'][0],r['a'][1]&0xffffffff,r['a'][1]>>32,r['b'][0],r['b'][1]&0xffffffff,r['b'][1]>>32) for r in rows)
        (dest/'stdin.bin').write_bytes(payload)
        cmd=['gcc','-m32','-march=pentium','-mno-sse','-O2','-fno-pic','-fno-pie',
            '-fno-stack-protector','-nostdlib','-static','-Wl,--build-id=none,-e,_start',str(HERE/source),'-o',str(dest/'probe')]
        with (dest/'compile.log').open('x') as f:
            done=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,timeout=30)
        save(dest/'compile.json',dict(command=cmd,native_exit=done.returncode));assert done.returncode==0
        for name,cmd in (('native',[str(dest/'probe')]),('control',[str(control),'-cpu','pentium',str(dest/'probe')]),
                         ('candidate',[str(candidate),'-cpu','pentium',str(dest/'probe')])):
            with (dest/'stdin.bin').open('rb') as inp,(dest/(name+'.bin')).open('xb') as out,(dest/(name+'.stderr')).open('x') as err:
                child=subprocess.Popen(cmd,stdin=inp,stdout=out,stderr=err);observed=set();start=time.monotonic()
                try:
                    while child.poll() is None:
                        try:observed.add(tuple(sorted(os.sched_getaffinity(child.pid))))
                        except ProcessLookupError:pass
                        assert time.monotonic()-start<90,name+' timeout'
                        time.sleep(.0001)
                    code=child.wait()
                finally:
                    if child.poll() is None:child.kill()
                    child.wait()
            save(dest/(name+'.native.json'),dict(command=cmd,native_exit=code,actual_wait=True,
                reaped=True,observed_affinity=sorted(observed),sha256=sha(dest/(name+'.bin')),
                seconds=time.monotonic()-start))
            assert code==0 and observed=={(12,)}
            checked=grader.grade(rows,(dest/(name+'.bin')).read_bytes())
            save(dest/(name+'.graded.json'),checked)
            results.append(dict(mode=mode,name=name,**{k:v for k,v in checked.items() if k!='errors'},mismatches=len(checked['errors'])))
            print(json.dumps(results[-1]),flush=True)
    stable=all(sha(path)==h for path,h in pins.items())
    positive=all(r['passed'] for r in results if r['mode']=='precision' or r['name']!='control')
    negative=args.precision_only or any(r['mode']=='sequence' and r['name']=='control' and not r['passed'] for r in results)
    result=dict(passed=stable and positive and negative,pins_unchanged=stable,
        negative_control_required=not args.precision_only,
        negative_control_rejected=None if args.precision_only else negative,
        fixed=fixed,results=results,seconds=time.monotonic()-begin,canonical_gate_passed=False,
        standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    save(root/'closed.json',result);print(json.dumps(result),flush=True)
    return int(not result['passed'])


if __name__=='__main__':raise SystemExit(main())
