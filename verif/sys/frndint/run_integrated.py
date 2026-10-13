"""Cold full-core FRNDINT program: native self-check, no snapshots or masks."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import time
import traceback

HERE=Path(__file__).resolve().parent;REPO=HERE.parents[2]
sys.path.insert(0,str(REPO/'verif/diff'))
import tracefmt


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def save(p,d):
    with p.open('x') as f:json.dump(d,f,indent=2)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('parent','core','leaf','out'):ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args();root=a.out.resolve();core=a.core.resolve(strict=True);parent=a.parent.resolve(strict=True);leaf=a.leaf.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and os.sched_getaffinity(0)=={13} and os.environ['INVOCATION_ID']
    assert shutil.disk_usage(scratch).free>4*1024**3+128*1024**2
    audit=json.loads((leaf/'audit.json').read_text());assert audit['passed']
    assert all(sha(p)==h for p,h in audit['artifacts'].items())
    allrows=json.loads((leaf/'cases.json').read_text())
    values=list(struct.iter_unpack('<4I',(leaf/'native.bin').read_bytes()))
    finite={(0x3fff,3<<62),(0x4017,(1<<63)+1),(0x403d,(1<<64)-1),(0xc03d,(1<<64)-1)}
    specials={(0,1),(0x7fff,0xa123456789abcdef),(0x3fff,0x4000000000000000)}
    chosen=[(r,v) for r,v in zip(allrows,values) if r['kind']==0 and
        ((r['hi'],r['m']) in finite or r['tag'] or
         ((r['hi'],r['m']) in specials and r['cw']&0xf00==0x300))]
    assert len(chosen)==412
    pins={str(p):sha(p) for p in (Path(__file__),HERE/'integrated.S',leaf/'audit.json',leaf/'native.bin',leaf/'cases.json')}
    for folder in (core,parent):
        built=json.loads((folder/'build-closed.json').read_text())
        assert built['passed'] and sha(folder/'obj/tb_ventium')==built['binary_sha256']
        for p in (folder/'obj/tb_ventium',folder/'build-closed.json',folder/'build-started.json'):pins[str(p)]=sha(p)
    root.mkdir();save(root/'started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],cases=len(chosen),cold=True))
    data=bytearray()
    for r,v in chosen:
        env=bytearray(108);struct.pack_into('<III',env,0,r['cw'],r['sw'],r['tag'])
        for i in range(8):struct.pack_into('<QH',env,28+10*i,1<<63,0x3fff)
        struct.pack_into('<QH',env,28,r['m'],r['hi'])
        data+=env+struct.pack('<4I',*v)
    (root/'cases.bin').write_bytes(data);save(root/'cases.json',chosen)
    result=dict(passed=False,rows=[],errors=[],differential_trace=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    start=time.monotonic()
    try:
        command=['gcc','-m32','-march=pentium','-nostdlib','-static','-no-pie',
                 '-Wl,--build-id=none,-e,_start,-Ttext=0x08048000',str(HERE/'integrated.S'),'-o',str(root/'test.elf')]
        with (root/'compile.log').open('x') as f:code=subprocess.run(command,cwd=root,stdout=f,stderr=subprocess.STDOUT,timeout=30).returncode
        assert code==0
        p=subprocess.run([root/'test.elf'],capture_output=True,timeout=30)
        result['native_exit']=p.returncode;assert p.returncode==0 and not p.stdout and not p.stderr
        command=[sys.executable,'-B',str(REPO/'verif/tests/elf2flat.py'),str(root/'test.elf'),'--out',str(root/'test.flat')]
        p=subprocess.run(command,capture_output=True,text=True,timeout=30)
        save(root/'flatten.json',dict(command=command,native_exit=p.returncode,stdout=p.stdout,stderr=p.stderr))
        assert p.returncode==0
        fields=dict(line.split('=',1) for line in p.stdout.splitlines())
        assert re.fullmatch('0x[0-9a-f]{8}',fields['entry']) and re.fullmatch('0x[0-9a-f]{8}',fields['load_addr'])
        for name,folder in (('parent',parent),('repaired',core)):
            command=[str(folder/'obj/tb_ventium'),'--image',str(root/'test.flat'),'--load',fields['load_addr'],'--entry',fields['entry'],
                '--init-esp','0x408002e0','--out',str(root/(name+'.vtrace')),'--max-insn','50000',
                '--max-cycles','2000000','--x87','--cycle-func','--l1-axi']
            env=dict(os.environ,AXI_RLAT='7',AXI_WLAT='7')
            with (root/(name+'.log')).open('x') as f:
                child=subprocess.Popen(command,stdout=f,stderr=subprocess.STDOUT,env=env)
                affinity=[];begin=time.monotonic()
                while child.poll() is None:
                    try:affinity.append(sorted(os.sched_getaffinity(child.pid)))
                    except ProcessLookupError:pass
                    if time.monotonic()-begin>120:child.kill();child.wait();raise TimeoutError(name)
                    time.sleep(.002)
            trace=tracefmt.read_trace(str(root/(name+'.vtrace')));last=trace.records[-1]
            log=(root/(name+'.log')).read_text()
            row=dict(name=name,native_exit=child.returncode,affinity_verified=bool(affinity) and all(v==[13] for v in affinity),
                exit_code=int(last['ebx'],16),completed_cases=int(last['ebp'],16),records=len(trace.records),
                actual_v_retirements=int(re.search(r'pairedV=(\d+)',log).group(1)),command=command)
            result['rows'].append(row)
            assert child.returncode==0 and row['affinity_verified'] and '--l1-axi selected' in log
            assert '--max-cycles (' not in log and '--max-insn (' not in log
        assert result['rows'][0]['exit_code']!=0 and result['rows'][0]['completed_cases']<len(chosen)
        assert result['rows'][1]['exit_code']==0 and result['rows'][1]['completed_cases']==len(chosen)
        result['passed']=True
    except Exception as e:result['errors'].append(dict(error=repr(e),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-start,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save(root/'closed.json',result);print(json.dumps(result,indent=2))
    return int(not result['passed'])


if __name__=='__main__':raise SystemExit(main())
