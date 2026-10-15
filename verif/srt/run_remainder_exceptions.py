"""Bounded shared-FPU parent/candidate exception and state-ownership test."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import sys
import time
import traceback

import prepare_remainder_exceptions as recipe
HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO/'verif/qemu-trace/remainder_sequence'))
import state_vectors as vectors
from run_small_quotient import sha, save


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for n in ('parent', 'reference', 'out'): ap.add_argument('--'+n, type=Path, required=True)
    a = ap.parse_args(); root=a.out.resolve(); parent=a.parent.resolve(strict=True)
    reference=a.reference.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and os.sched_getaffinity(0)==set(range(8,16))
    assert shutil.disk_usage(scratch).free>5*1024**3 and os.environ['INVOCATION_ID']
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
        'MemoryMax=10G','MemorySwapMax=2G'],check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    old=json.loads((parent/'build-started.json').read_text())
    built=json.loads((parent/'build-closed.json').read_text())
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert sha(parent/'obj/tb_ventium')==built['binary_sha256']==\
        '86afc1911cc3c9a066ad5888414af81683226c0a083e9f9d0e2acd4d13582f76'
    files=sorted(p for p in (parent/'candidate').rglob('*') if p.is_file())
    assert len(files)==195 and all(sha(p)==old['pins'][str(p)] for p in files)
    started=json.loads((reference/'started.json').read_text())
    closed=json.loads((reference/'closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged'] and not closed['native_oracle_errors']
    assert all(sha(p)==h for p,h in started['pins'].items())
    rows=vectors.rows(); assert rows==[dict(r,a=tuple(r['a']),b=tuple(r['b'])) for r in json.loads((reference/'cases.json').read_text())]
    raw=(reference/'native.bin').read_bytes(); assert len(raw)==108*len(rows)
    expected=[raw[i:i+108] for i in range(0,len(raw),108)]
    assert all(not vectors.check_native(r,v) for r,v in zip(rows,expected))
    definitions=old['definitions'];assert len(definitions)==len(set(definitions))==152
    pins=dict(started['pins'])
    for p in (*files,Path(__file__),Path(recipe.__file__),HERE/'tb_remainder_exceptions.sv',
              parent/'build-started.json',parent/'build-closed.json',parent/'obj/tb_ventium',
              reference/'started.json',reference/'closed.json',reference/'cases.json',reference/'native.bin',
              REPO/'tools/build_scope.sh',REPO/'tools/verilator_serial.sh',Path(os.environ['VENTIUM_VERILATOR_BIN'])):
        pins[str(p.resolve())]=sha(p)
    root.mkdir();save(root/'started.json',dict(pins=pins,definitions=definitions,
        invocation=os.environ['INVOCATION_ID'],parent=str(parent),reference=str(reference),whole_core=False))
    with (root/'vectors.txt').open('x') as f:
        for r in rows:
            f.write(f"{r['cw']:04x} {r['sw']:04x} {r['tag']:04x} {r['a'][0]:04x}{r['a'][1]:016x} {r['b'][0]:04x}{r['b'][1]:016x} {r['op']}\n")
    result=dict(passed=False,errors=[],variants=[],canonical_gate_passed=False,
                standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    begin=time.monotonic()
    try:
        observations={}
        for variant in ('parent','candidate'):
            assert shutil.disk_usage(scratch).free>4*1024**3+512*1024**2
            folder=root/variant;folder.mkdir();source=folder/'source'
            shutil.copytree(parent/'candidate',source)
            if variant=='candidate':
                for n in recipe.PARENTS:(source/n).write_text(recipe.transform((source/n).read_text(),n))
            changed=[str(p.relative_to(parent/'candidate')) for p in files
                     if sha(p)!=sha(source/p.relative_to(parent/'candidate'))]
            assert changed==(sorted(recipe.PARENTS) if variant=='candidate' else [])
            command=[REPO/'tools/verilator_serial.sh','--binary','--timing','--assert','-sv',
                '-j','32','--verilate-jobs','1','--output-split','10000','--output-split-cfuncs','500',
                '-Wall','-Wno-UNUSED','-Wno-fatal',
                *['-Werror-'+n for n in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                *['+define+'+d for d in definitions],'-f',source/'rtl_ven_core.f',
                '--top-module','tb_remainder_exceptions','--Mdir',folder/'obj','-o','test',HERE/'tb_remainder_exceptions.sv']
            row=dict(name=variant,changed=changed,command=list(map(str,command)))
            result['variants'].append(row)
            with (folder/'build.log').open('x') as f:
                row['build_exit']=subprocess.run(command,cwd=source,stdout=f,stderr=subprocess.STDOUT,
                    pass_fds=(9,),timeout=240).returncode
            assert row['build_exit']==0
            with (folder/'run.log').open('x') as f:
                child=subprocess.Popen(['taskset','-c','12',folder/'obj/test','+vectors='+str(root/'vectors.txt')],stdout=f,stderr=subprocess.STDOUT)
                observed=set();start=time.monotonic()
                try:
                    while child.poll() is None:
                        try:
                            if Path('/proc',str(child.pid),'exe').resolve()==(folder/'obj/test').resolve():
                                observed.add(tuple(sorted(os.sched_getaffinity(child.pid))))
                        except (FileNotFoundError,ProcessLookupError):pass
                        assert time.monotonic()-start<120
                        time.sleep(.0001)
                    row['native_exit']=child.wait()
                finally:
                    if child.poll() is None:child.kill()
                    child.wait()
            row['affinity']=sorted(observed);assert row['native_exit']==0 and observed=={(12,)}
            log=(folder/'run.log').read_text()
            assert f'REM-EXCEPTION-TRANSPORT-OK rows={len(rows)} resets=3' in log
            found=re.findall(r'^ROW (\d+) ([0-9a-f]{216}) (\d+) (\d+)$',log,re.M)
            assert len(found)==len(rows)
            diffs=[];latencies=[]
            for i,((number,hexdata,latency,fault),r,native) in enumerate(zip(found,rows,expected)):
                assert int(number)==i
                actual=int(hexdata,16).to_bytes(108,'little')
                errors=vectors.compare(r,native,actual)
                if errors:diffs.append(dict(index=i,errors=errors))
                latencies.append(int(latency))
                assert bool(int(fault))==bool(vectors.flags(r)&0x40)
            save(folder/'graded.json',dict(mismatches=diffs,latencies=latencies,cases=len(rows)))
            row.update(mismatches=len(diffs),cases=len(rows),artifacts={str(p):sha(p) for p in
                (*[source/n for n in recipe.PARENTS],folder/'run.log',folder/'build.log',folder/'graded.json',folder/'obj/test')})
            observations[variant]=latencies
        result['latencies_unchanged']=observations['parent']==observations['candidate']
        result['passed']=bool(result['variants'][0]['mismatches']) and result['variants'][1]['mismatches']==0
    except Exception as e:result['errors'].append(dict(error=repr(e),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged'];save(root/'closed.json',result)
    print(json.dumps(result,indent=2),flush=True)
    return int(not result['passed'])


if __name__=='__main__':raise SystemExit(main())
