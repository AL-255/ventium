"""Cross-instruction PC retention, exception priority and full-stack controls."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import time


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def save(p, d):
    with p.open('x') as f:
        json.dump(d, f, indent=2)


def cases():
    rows = []
    specials = [(0,1,0), (0,1<<63,0), (0x3fff,0x4000000000000000,0),
        (0x7fff,0xa123456789abcdef,0), (0x7fff,0xc123456789abcdef,0),
        (0x3fff,3<<62,0), (0x3fff,1<<63,3)]
    for sign in (0,0x8000):
        for pc in (0,2,3):
            for rc in range(4):
                for seed in (0,0x200):
                    for sticky in (0,0x1c):
                        for mask in (0x3f,0x3e,0x3d,0x1f,0x3c,0x1e,0x1d,0x1c):
                            for hi,m,tag in specials:
                                rows.append((0x40|(pc<<8)|(rc<<10)|mask,
                                    0x4500|seed|sticky,tag,hi|sign,m,0))
                    for hi,m in ((0x4017,(1<<63)+(1<<39)), (0x4034,(1<<63)+(1<<10))):
                        rows.append((0x7f|(pc<<8)|(rc<<10),0x4500|seed,0,hi|sign,m,1))
    return rows


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('build','out'): ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args(); root=a.out.resolve(); build=a.build.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert os.sched_getaffinity(0)=={12} and Path(os.environ['TMPDIR']).resolve()==scratch
    assert os.environ['INVOCATION_ID'] and shutil.disk_usage(scratch).free>4*1024**3+32*1024**2
    built=json.loads((build/'closed.json').read_text()); qemu=Path(built['binary'])
    assert built['passed'] and built['pins_unchanged'] and sha(qemu)==built['sha256']
    source=Path(__file__).with_name('state_probe.c'); rows=cases()
    root.mkdir(); save(root/'cases.json',rows)
    data=b''.join(struct.pack('<8I',cw,sw,tag,hi,m&0xffffffff,m>>32,kind,0)
                  for cw,sw,tag,hi,m,kind in rows)
    (root/'stdin.bin').write_bytes(data)
    pins={str(p):sha(p) for p in (Path(__file__),source,qemu,build/'closed.json')}
    save(root/'started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],cases=len(rows)))
    command=['gcc','-m32','-march=pentium','-mno-sse','-O2','-fno-pic','-fno-pie',
        '-fno-stack-protector','-nostdlib','-static','-Wl,--build-id=none,-e,_start',str(source),'-o',str(root/'probe')]
    with (root/'compile.log').open('x') as f:
        code=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,timeout=30).returncode
    save(root/'compile.json',dict(command=command,native_exit=code)); assert code==0
    outputs={}; executions=[]; begin=time.monotonic()
    for name,command in (('native',[str(root/'probe')]),('candidate',[str(qemu),'-cpu','pentium',str(root/'probe')])):
        with (root/'stdin.bin').open('rb') as inp, (root/(name+'.bin')).open('xb') as out, (root/(name+'.stderr')).open('x') as err:
            child=subprocess.Popen(command,stdin=inp,stdout=out,stderr=err)
            observed=[]; start=time.monotonic()
            while child.poll() is None:
                try: observed.append(sorted(os.sched_getaffinity(child.pid)))
                except ProcessLookupError: pass
                if time.monotonic()-start>90:
                    child.kill();child.wait();raise TimeoutError(name)
                time.sleep(.001)
            code=child.wait()
        raw=(root/(name+'.bin')).read_bytes()
        assert code==0 and len(raw)==108*len(rows) and observed and all(x==[12] for x in observed)
        outputs[name]=[raw[i:i+108] for i in range(0,len(raw),108)]
        executions.append(dict(name=name,command=command,native_exit=code,observed_affinity=[12],sha256=sha(root/(name+'.bin'))))
    mismatches=[]
    for i,(native,candidate) in enumerate(zip(outputs['native'],outputs['candidate'])):
        n=struct.unpack('<27I',native); c=struct.unpack('<27I',candidate)
        # Undefined C0/C2/C3 and native-vs-QEMU selector/pointer presentation
        # are not this probe's oracle; every physical stack payload is checked.
        if ((n[0]^c[0])&0xffff or (n[1]^c[1])&0xbaff or
                (n[2]^c[2])&0xffff or native[28:]!=candidate[28:]):
            mismatches.append(i)
    stable=all(sha(p)==h for p,h in pins.items())
    result=dict(passed=stable and not mismatches,pins_unchanged=stable,cases=len(rows),
        pc_following_add_cases=sum(r[-1]==1 for r in rows),mismatches=mismatches,
        executions=executions,seconds=time.monotonic()-begin,canonical_gate_passed=False,
        standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    save(root/'closed.json',result);print(json.dumps(result,indent=2))
    return int(not result['passed'])


if __name__=='__main__':raise SystemExit(main())
