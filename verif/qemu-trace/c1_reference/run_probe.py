"""Native instruction-level C1 check, exact oracle plus unchanged-value control."""
import argparse
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import run_round_increment as rounding


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def save(p, data):
    with p.open('x') as f:
        json.dump(data, f, indent=2)


def cases():
    rows = []
    for old in rounding.cases():
        rows.append(dict(args=(*old['args'], 1), expected=old['expected'], mask=0x200))
    one = (0x3fff, 1<<63)
    for prec in range(3):
        for rc in range(4):
            for sign in (0, 0x8000):
                for low in (1<<63, (1<<63)+(1<<61), 3<<62, (1<<64)-1):
                    value = rounding.exact_value(0x3fff|sign, low)
                    n, d = abs(value).numerator, abs(value).denominator
                    q, r = divmod(n,d)
                    expected = int((rc==0 and (2*r>d or (2*r==d and q&1))) or
                                   (r and ((rc==1 and value<0) or (rc==2 and value>0))))
                    for seed in (0,1):
                        rows.append(dict(args=(8,prec,rc,0x3fff|sign,low,*one,seed), expected=expected,mask=0x200))
    for kind in (*range(9,20),22,23,24,25):
        for sign in (0,0x8000):
            for seed in (0,1):
                for rc in range(4):
                    expected = seed if kind==22 else int(bool(sign)) if kind==19 else 0
                    rows.append(dict(args=(kind,0,rc,0x3fff|sign,3<<62,*one,seed),expected=expected,mask=0x200))
    for kind in (20,21):
        for numerator in range(1,32):
            for denominator in (1,2,3,5,7):
                def encode(n):
                    e=n.bit_length()-1
                    return (16383+e,n<<(63-e))
                for sign in (0,0x8000):
                    a=encode(numerator); b=encode(denominator)
                    q,r=divmod(numerator,denominator)
                    if kind==21 and (2*r>denominator or (2*r==denominator and q&1)):
                        q+=1
                    bits=((q&4)<<6)|((q&2)<<13)|((q&1)<<9)
                    rows.append(dict(args=(kind,0,0,a[0]|sign,a[1],*b,1), expected=bits,mask=0x4700))
    return rows


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    a=ap.parse_args(); build=a.build.resolve(strict=True); root=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and os.sched_getaffinity(0)=={12}
    assert os.environ['INVOCATION_ID'] and shutil.disk_usage(scratch).free>4*1024**3+32*1024**2
    closed=json.loads((build/'closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged']
    candidate=Path(closed['binary'])
    assert sha(candidate)==closed['sha256']
    control=scratch/'ventium-qemu-preexit-r2.81Yu1ixT/observer-build/qemu-i386'
    assert sha(control)=='52a9ca27d2d1bb40a360a7c2e881b8fe63b0795f285ae823b96e33e75ef0ff31'
    root.mkdir()
    inputs=(Path(__file__),HERE/'probe.c',Path(rounding.__file__),
            candidate,control,build/'closed.json')
    pins={str(p):sha(p) for p in inputs}
    rows=cases(); save(root/'cases.json',rows)
    data=b''.join(struct.pack('<10I',kind,prec,rc,ah,al&0xffffffff,al>>32,bh,
        bl&0xffffffff,bl>>32,seed) for row in rows for kind,prec,rc,ah,al,bh,bl,seed in [row['args']])
    (root/'stdin.bin').write_bytes(data)
    save(root/'started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],cases=len(rows)))
    command=['gcc','-m32','-march=pentium','-mno-sse','-O2','-fno-pic','-fno-pie',
        '-fno-stack-protector','-nostdlib','-static','-Wl,--build-id=none,-e,_start',
        str(HERE/'probe.c'),'-o',str(root/'probe')]
    with (root/'compile.log').open('x') as f:
        code=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,timeout=30).returncode
    save(root/'compile.json',dict(command=command,native_exit=code))
    assert code==0
    result=dict(passed=False,rows=[],errors=[],canonical_gate_passed=False,
                hardware_acceptance=False,gameplay_ipc=None)
    start=time.monotonic(); original=None
    for label,command in (('control',[str(control),'-cpu','pentium',str(root/'probe')]),
                          ('candidate',[str(candidate),'-cpu','pentium',str(root/'probe')]),
                          ('native',[str(root/'probe')])):
        with (root/(label+'.bin')).open('xb') as out, (root/(label+'.stderr')).open('x') as err:
            done=subprocess.run(command,input=data,stdout=out,stderr=err,timeout=120)
        raw=(root/(label+'.bin')).read_bytes()
        assert done.returncode==0 and len(raw)==16*len(rows)
        values=list(struct.iter_unpack('<4I',raw))
        numeric=[v[:3] for v in values]
        if label=='control': original=numeric
        mismatches=[i for i,(r,v) in enumerate(zip(rows,values)) if
                    (v[3]&r['mask'])!=(r['expected']<<9 if r['mask']==0x200 else r['expected'])]
        value_changes=[i for i,(old,new) in enumerate(zip(original,numeric)) if old!=new]
        result['rows'].append(dict(label=label,command=command,native_exit=done.returncode,
            records=len(values),c1_mismatches=len(mismatches),mismatch_indices=mismatches,
            numeric_changes=len(value_changes),numeric_change_indices=value_changes,
            stdout_sha256=sha(root/(label+'.bin'))))
    result.update(seconds=time.monotonic()-start,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed']=result['pins_unchanged'] and result['rows'][0]['c1_mismatches']>0 and all(
        r['c1_mismatches']==0 for r in result['rows'][1:]) and result['rows'][1]['numeric_changes']==0
    save(root/'closed.json',result)
    print(json.dumps({**result,'rows':[{k:v for k,v in r.items() if not k.endswith('_indices')} for r in result['rows']]},indent=2),flush=True)
    return int(not result['passed'])


if __name__=='__main__':
    raise SystemExit(main())
