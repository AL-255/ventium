#!/usr/bin/env python3
"""Run actual candidate token leaf inside the normal guarded build scope."""
import argparse, hashlib, json, os, subprocess
from pathlib import Path
ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('--source',type=Path,required=True)
ap.add_argument('--out',type=Path,required=True)
a=ap.parse_args()
repo=Path(__file__).resolve().parents[2]
scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
assert __debug__ and a.out.resolve().is_relative_to(scratch)
assert Path(os.environ['TMPDIR']).resolve().is_relative_to(scratch)
a.out.mkdir();body=Path(__file__).with_name('tb_prefix66_system_token.sv')
source=a.source.resolve(strict=True)
assert 'VEN_P54_PREFIX66_SYSTEM' in source.read_text()
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
pins={str(p):sha(p) for p in (source,body,Path(__file__))}
command=[str(repo/'tools/verilator_serial.sh'),'--binary','--timing','--assert','-sv','-Wall',
    '-Wno-UNUSED','-Wno-fatal',*['-Werror-'+x for x in
    ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
    '+define+VEN_P54_PREFIX66_SYSTEM','+define+VEN_SYS_FASTPATH','+define+VEN_L1_AXI',
    '+define+VEN_FP_PIPE','-I'+str(source.parent),'--top-module','tb_prefix66_system_token',
    '--Mdir',str(a.out/'obj'),'-j','1',str(body)]
with (a.out/'started.json').open('x') as f:json.dump(dict(command=command,pins=pins),f,indent=2)
with (a.out/'build.log').open('x') as f:
    p=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,timeout=180,pass_fds=(9,))
result=dict(build_exit=p.returncode,passed=False)
if p.returncode==0:
    with (a.out/'run.log').open('x') as f:
        q=subprocess.run([str(a.out/'obj/Vtb_prefix66_system_token')],stdout=f,stderr=subprocess.STDOUT,timeout=30)
    result.update(run_exit=q.returncode,passed=q.returncode==0 and
                  'PREFIX66-SYSTEM-TOKEN-OK' in (a.out/'run.log').read_text())
result['pins_unchanged']=all(sha(Path(p))==h for p,h in pins.items())
result['passed'] &= result['pins_unchanged']
with (a.out/'closed.json').open('x') as f:json.dump(result,f,indent=2)
print(json.dumps(result));raise SystemExit(0 if result['passed'] else 1)
