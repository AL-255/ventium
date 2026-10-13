"""Bounded full-FP-shell parent/candidate test using real native x87 operands."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import struct
import subprocess
import time
import traceback
import prepare
import vectors

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[2]
MODEL='369a23b48abaebd54991533e8933094c9791d6b6d9a6a13edb1f128029c6b150'


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()


def save(p,value):
    with p.open('x') as f: json.dump(value,f,indent=2)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('parent','out'): ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args(); parent=a.parent.resolve(strict=True); root=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    # The linked leaf is small, but GCC produces two ~80 MiB PCH caches per
    # variant. Admit with the full build reserve; losslessly compact those
    # caches only after their native model finishes below.
    assert shutil.disk_usage(scratch).free>5*1024**3
    assert os.environ['INVOCATION_ID'] and os.sched_getaffinity(0)==set(range(8,16))
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    assert Path('/proc/self/cgroup').read_text().strip().endswith('/ventium-ipc-parallel32.scope')
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                    'MemoryMax=10G','MemorySwapMax=2G'],check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    old=json.loads((parent/'build-started.json').read_text())
    closed=json.loads((parent/'build-closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit']==0
    assert sha(parent/'obj/tb_ventium')==closed['binary_sha256']==MODEL
    files=sorted(p for p in (parent/'candidate').rglob('*') if p.is_file())
    assert len(files)==195 and all(sha(p)==old['pins'][str(p)] for p in files)
    definitions=old['definitions']; assert len(definitions)==len(set(definitions))==152
    pins={str(p):sha(p) for p in (*files,Path(__file__),HERE/'prepare.py',HERE/'vectors.py',
        HERE/'native.c',HERE/'tb_frndint.sv',parent/'build-started.json',parent/'build-closed.json',
        REPO/'tools/build_scope.sh',REPO/'tools/verilator_serial.sh',Path(os.environ['VENTIUM_VERILATOR_BIN']))}
    root.mkdir(); rows=vectors.rows(); data=b''.join(map(vectors.pack,rows))
    save(root/'started.json',dict(pins=pins,definitions=definitions,invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0)),parent=str(parent),whole_core=False))
    save(root/'cases.json',rows); (root/'stdin.bin').write_bytes(data)
    with (root/'vectors.txt').open('x') as f:
        for r in rows: f.write(f"{r['cw']:04x} {r['sw']:04x} {r['tag']:04x} {r['hi']:04x} {r['m']:016x} {r['kind']}\n")
    result=dict(passed=False,errors=[],rows=[],whole_core=False,canonical_gate_passed=False,
                standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    begin=time.monotonic()
    try:
        command=['gcc','-m32','-march=pentium','-mno-sse','-O2','-fno-pic','-fno-pie',
            '-fno-stack-protector','-nostdlib','-static','-Wl,--build-id=none,-e,_start',
            str(HERE/'native.c'),'-o',str(root/'native')]
        with (root/'native-build.log').open('x') as f:
            code=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,timeout=30).returncode
        assert code==0
        with (root/'native.bin').open('xb') as f, (root/'native.stderr').open('x') as err:
            p=subprocess.Popen(['taskset','-c','12',str(root/'native')],stdin=subprocess.PIPE,stdout=f,stderr=err)
            # Large pipe input keeps the real child live until this observation.
            deadline=time.monotonic()+5; affinity=None
            while time.monotonic()<deadline and p.poll() is None:
                got=os.sched_getaffinity(p.pid)
                if got=={12}: affinity=sorted(got);break
                time.sleep(.001)
            p.communicate(data,timeout=30)
        assert p.returncode==0 and affinity==[12]
        raw=(root/'native.bin').read_bytes(); assert len(raw)==16*len(rows)
        expected=list(struct.iter_unpack('<4I',raw)); independent=0
        for r,v in zip(rows,expected):
            exact=vectors.finite_result(r)
            if exact is not None:
                value,flags=exact
                assert v[0]|(v[1]<<32)|(v[2]<<64)==value,(r,v,exact)
                assert v[3]&0x82ff==flags,(r,v,exact)
                independent+=1
        result['native']=dict(exit=p.returncode,affinity=affinity,rows=len(rows),independent=independent)
        baseline=None
        for variant in ('parent','repaired'):
            assert shutil.disk_usage(scratch).free>4*1024**3+256*1024**2
            folder=root/variant;folder.mkdir();source=folder/'source'
            shutil.copytree(parent/'candidate',source)
            if variant=='repaired':
                for name in prepare.PARENTS: (source/name).write_text(prepare.transform((source/name).read_text(),name))
            changed=[str(p.relative_to(parent/'candidate')) for p in files
                     if sha(p)!=sha(source/p.relative_to(parent/'candidate'))]
            assert changed==(sorted(prepare.PARENTS) if variant=='repaired' else [])
            command=[REPO/'tools/verilator_serial.sh','--binary','--timing','--assert','-sv',
                '-j','32','--verilate-jobs','1','--output-split','10000','--output-split-cfuncs','500',
                '-Wall','-Wno-UNUSED','-Wno-fatal',
                *['-Werror-'+n for n in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                *['+define+'+d for d in definitions],'-f',source/'rtl_ven_core.f',
                '--top-module','tb_frndint','--Mdir',folder/'obj','-o','test',HERE/'tb_frndint.sv']
            row=dict(name=variant,command=list(map(str,command)),changed=changed);result['rows'].append(row)
            with (folder/'build.log').open('x') as f:
                row['build_exit']=subprocess.run(command,cwd=source,stdout=f,stderr=subprocess.STDOUT,
                    pass_fds=(9,),timeout=240).returncode
            assert row['build_exit']==0
            with (folder/'run.log').open('x') as f:
                p=subprocess.Popen(['taskset','-c','12',str(folder/'obj/test'),'+vectors='+str(root/'vectors.txt')],
                                   stdout=f,stderr=subprocess.STDOUT)
                affinities=[]
                while p.poll() is None:
                    try: affinities.append(sorted(os.sched_getaffinity(p.pid)))
                    except ProcessLookupError: pass
                    if time.monotonic()-begin>500: p.kill();p.wait();raise TimeoutError('leaf runtime')
                    time.sleep(.002)
            row['native_exit']=p.returncode;row['affinities']=affinities
            log=(folder/'run.log').read_text()
            assert p.returncode==0 and f'FRND-TRANSPORT-OK rows={len(rows)} resets=2' in log
            found=re.findall(r'^ROW (\d+) ([0-9a-f]+) ([0-9a-f]+) ([0-9a-f]+) (\d+) (\d+)$',log,re.M)
            assert len(found)==len(rows) and any(x==[12] for x in affinities)
            actual=[]; differences=[]
            for i,(item,r,v) in enumerate(zip(found,rows,expected)):
                n,value,sw,tag,latency,stack=item
                assert int(n)==i
                current=(int(value,16),int(sw,16),int(tag,16),int(latency),int(stack));actual.append(current)
                if r['kind']==0 and (current[0] != v[0]|v[1]<<32|v[2]<<64 or (current[1]&0x82ff)!=(v[3]&0x82ff)):
                    differences.append(i)
            row['mismatch_indices']=differences;row['mismatches']=len(differences)
            if variant=='parent': baseline=actual;assert differences
            else:
                assert all(old[3:]==new[3:] for old,new in zip(baseline,actual))
                assert all(old==new for old,new,r in zip(baseline,actual,rows) if r['kind'])
            row['artifacts']={str(p):sha(p) for p in (*[source/n for n in prepare.PARENTS],
                folder/'build.log',folder/'run.log',folder/'obj/test')}
            row['pch_archives']=[]
            for speed in ('fast','slow'):
                p=folder/'obj'/('Vtb_frndint__pch.h.'+speed+'.gch')
                assert p.is_file() and not p.is_symlink() and p.stat().st_nlink==1
                digest=sha(p); dest=Path(str(p)+'.gz')
                with p.open('rb') as src,dest.open('xb') as out:
                    with gzip.GzipFile(fileobj=out,mode='wb',compresslevel=1,mtime=0) as gz:
                        shutil.copyfileobj(src,gz,1024*1024)
                with gzip.open(dest,'rb') as f: assert hashlib.file_digest(f,'sha256').hexdigest()==digest
                assert sha(p)==digest
                row['pch_archives'].append(dict(path=str(p),sha256=digest,
                    archive=str(dest),archive_sha256=sha(dest)))
                p.unlink()
        result['passed']=result['rows'][1]['mismatches']==0
    except Exception as e: result['errors'].append(dict(error=repr(e),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged'];save(root/'closed.json',result)
    print(json.dumps({**result,'rows':[{k:v for k,v in r.items() if k not in ('command','mismatch_indices','affinities')} for r in result['rows']]},indent=2),flush=True)
    return int(not result['passed'])


if __name__=='__main__': raise SystemExit(main())
