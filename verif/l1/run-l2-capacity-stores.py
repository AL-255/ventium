#!/usr/bin/env python3
"""Bounded geometry/store probe of the already tested L2 capacity candidate."""
from concurrent.futures import ThreadPoolExecutor
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

REPO=Path(__file__).resolve().parents[2]
def sha(path):
    with Path(path).open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def save(path,value):
    with path.open('x') as stream:json.dump(value,stream,indent=2)

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--capacity',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert args.out.resolve().is_relative_to(scratch) and shutil.disk_usage(scratch).free>2*1024**3
    source=args.capacity.resolve(strict=True)
    result=json.loads((source/'closed.json').read_text())
    assert result['passed'] and result['stable_inputs'] and result['xpm_fidelity']
    assert all(sha(p)==h for p,h in result['source_pins'].items())
    lock_fds=tuple(int(p.name) for p in Path('/proc/self/fd').iterdir()
        if p.name.isdigit() and p.exists() and p.resolve()==Path('/tmp/ventium-heavy-build.lock'))
    assert lock_fds,'use tools/build_scope.sh'
    args.out.mkdir()
    sources={n:source/n for n in ('control.v','candidate.v','prims.sv')}
    sources['tb.sv']=REPO/'verif/l1/tb_l2_capacity_stores.sv'
    pins={str(p):sha(p) for p in (Path(__file__).resolve(),source/'closed.json')}
    for name,path in sources.items():
        target=args.out/name;shutil.copyfile(path,target)
        pins[str(path)]=sha(path);pins[str(target)]=sha(target)
    save(args.out/'pins.json',pins)
    def run(job):
        sets,mode=job;out=args.out/f'{sets}-{mode}';out.mkdir()
        defines=[] if mode=='control' else ['-DL2_CAPACITY_PARAM']
        command=['/tools/verilator/v5.046/bin/verilator','--binary','--timing','--assert',
            '-sv','-j','8','-Wall','-Wno-fatal','-Wno-UNUSED',
            *['-Werror-'+k for k in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
            '-DVEN_ALTSYNCRAM_XPM','-DVEN_L2_STREAM_CWF','-DVEN_L2_STREAM_ANY',*defines,
            '--top-module','tb_l2_capacity_stores',f'-GSETS={sets}',
            '--Mdir',str(out/'obj'),'-o','test',str(args.out/'tb.sv'),
            str(args.out/('control.v' if mode=='control' else 'candidate.v')),str(args.out/'prims.sv')]
        save(out/'command.json',command)
        with (out/'build.log').open('x') as log:
            rc=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=180,pass_fds=lock_fds).returncode
        row=dict(sets=sets,mode=mode,build_exit=rc,passed=False,cases=[])
        if rc:return row
        for cadence in (1,2,3):
            for seed in (1,7,101):
                logpath=out/f'run-{cadence}-{seed}.log'
                with logpath.open('x') as log:
                    rc=subprocess.run([out/'obj/test',f'+CADENCE={cadence}',
                        '+verilator+rand+reset+2',f'+verilator+seed+{seed}'],
                        stdout=log,stderr=subprocess.STDOUT,timeout=30).returncode
                match=re.search(r'L2-CAPACITY-STORES-OK sets=(\d+) cadence=(\d+) writes=(\d+) reads=(\d+) mutations=(\d+) ddr_reads=(\d+)',logpath.read_text())
                item=dict(seed=seed,cadence=cadence,native_exit=rc,passed=False)
                if match:
                    item.update(dict(zip(('sets','cadence','writes','reads','mutations','ddr_reads'),map(int,match.groups()))))
                    item['passed']=rc==0 and item['sets']==sets and item['writes']==17*sets and item['mutations']==sets
                row['cases'].append(item)
        row['passed']=all(r['passed'] for r in row['cases'])
        row['binary_sha256']=sha(out/'obj/test');print(json.dumps(row),flush=True)
        return row
    closed=dict(passed=False,gameplay_ipc=None,standard_suite=False,rows=[])
    try:
        with ThreadPoolExecutor(max_workers=4) as pool:
            closed['rows']=list(pool.map(run,[(128,'control')]+[(s,'candidate') for s in (128,256,512,1024)]))
        assert all(r['passed'] for r in closed['rows'])
        assert closed['rows'][0]['cases']==closed['rows'][1]['cases'],'default-geometry drift'
        closed['passed']=True
    except Exception as exc:closed['error']=repr(exc)
    finally:
        closed['stable_inputs']=all(sha(p)==h for p,h in pins.items())
        closed['passed'] &= closed['stable_inputs'];save(args.out/'closed.json',closed)
    assert closed['passed'],closed.get('error')

if __name__=='__main__':main()
