"""Run the actual shared FP top against independent four-layout checks.

Frozen 152-define core profile; cold reset, no snapshot or reference RTL
substitution. The unmodified parent must fail the same pointer assertion.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess
import time
import traceback

import prepare

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[2]


def sha(path):
    with Path(path).open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('parent','out'):ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args();parent=a.parent.resolve(strict=True);root=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and shutil.disk_usage(scratch).free>5*1024**3
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    assert Path('/proc/self/cgroup').read_text().strip().endswith('/ventium-ipc-parallel32.scope')
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                    'MemoryMax=10G','MemorySwapMax=2G'],check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    old=json.loads((parent/'build-started.json').read_text())
    closed=json.loads((parent/'build-closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit']==0
    assert sha(parent/'obj/tb_ventium')==closed['binary_sha256']=='2fc497047dc64848f28a920522a6fa4ec1e8ef0c686179394576d6237402acb2'
    files=sorted(p for p in (parent/'candidate').rglob('*') if p.is_file())
    assert all(sha(p)==old['pins'][str(p)] for p in files)
    definitions=old['definitions'];assert len(definitions)==len(set(definitions))==152
    pins={str(p):sha(p) for p in (*files,Path(__file__),HERE/'prepare.py',HERE/'tb_restore.sv',
        parent/'build-started.json',parent/'build-closed.json',REPO/'tools/build_scope.sh',
        REPO/'tools/verilator_serial.sh',Path(os.environ['VENTIUM_VERILATOR_BIN']))}
    root.mkdir()
    def save(name,value):
        with (root/name).open('x') as stream:json.dump(value,stream,indent=2)
    save('started.json',dict(pins=pins,definitions=definitions,invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0)),parent=str(parent),whole_core=False))
    result=dict(passed=False,errors=[],rows=[],whole_core=False,canonical_gate_passed=False,
        standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    begin=time.monotonic()
    try:
        for variant in ('parent','repaired'):
            assert shutil.disk_usage(scratch).free>4*1024**3+256*1024**2
            folder=root/variant;folder.mkdir();source=folder/'source'
            shutil.copytree(parent/'candidate',source)
            if variant=='repaired':
                for name in prepare.PARENTS:
                    (source/name).write_text(prepare.transform((source/name).read_text(),name))
            changed=[str(p.relative_to(parent/'candidate')) for p in files
                     if sha(p)!=sha(source/p.relative_to(parent/'candidate'))]
            assert changed==(sorted(prepare.PARENTS) if variant=='repaired' else [])
            command=[REPO/'tools/verilator_serial.sh','--binary','--timing','--assert','-sv',
                '-j','32','--verilate-jobs','1','--output-split','10000','--output-split-cfuncs','500',
                '-Wall','-Wno-UNUSED','-Wno-fatal',
                *['-Werror-'+n for n in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                *['+define+'+d for d in definitions],'-f',source/'rtl_ven_core.f',
                '--top-module','tb_restore','--Mdir',folder/'obj','-o','test',HERE/'tb_restore.sv']
            row=dict(name=variant,command=list(map(str,command)),changed=changed);result['rows'].append(row)
            with (folder/'build.log').open('x') as stream:
                native=subprocess.run(command,cwd=source,stdout=stream,stderr=subprocess.STDOUT,
                    pass_fds=(9,),timeout=240)
            row['build_exit']=native.returncode;assert native.returncode==0
            with (folder/'run.log').open('x') as stream:
                native=subprocess.run([folder/'obj/test'],stdout=stream,stderr=subprocess.STDOUT,timeout=30)
            row['native_exit']=native.returncode;row['log']=(folder/'run.log').read_text()
            if variant=='parent':
                assert native.returncode in (-6,1,134) and 'ENV-POINTER mode=0 full=0 sample=0' in row['log']
            else:assert native.returncode==0 and 'FP-ENV-RESTORE-OK cases=1024' in row['log']
            row['artifacts']={str(p):sha(p) for p in (*[source/n for n in prepare.PARENTS],
                folder/'build.log',folder/'run.log',folder/'obj/test')}
        result['passed']=True
    except Exception as error:result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged'];save('closed.json',result)
    print(json.dumps(result,indent=2),flush=True)
    return int(not result['passed'])


if __name__=='__main__':raise SystemExit(main())
