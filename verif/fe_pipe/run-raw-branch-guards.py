#!/usr/bin/env python3
"""Test actual private branch-hint integration under the shared build guard."""
import argparse,hashlib,json,os,subprocess
from pathlib import Path
ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('--rtl',type=Path,required=True)
ap.add_argument('--out',type=Path,required=True)
a=ap.parse_args()
here=Path(__file__).resolve().parent;repo=here.parents[1]
scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
assert __debug__ and a.out.resolve().is_relative_to(scratch)
assert Path(os.environ['TMPDIR']).resolve().is_relative_to(scratch)
rtl=a.rtl.resolve(strict=True);a.out.mkdir()
assert 'VEN_RAW_BRANCH_FALLTHROUGH_PRIME' in (rtl/'core/core_mem_chain.svh').read_text()
sources=[rtl/'ventium_pkg.sv',rtl/'core/ventium_alu_pkg.sv',rtl/'core/ventium_decode_pkg.sv',
         rtl/'core/issue_uv.sv',here/'tb_raw_branch_guards.sv']
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
pins={str(p):sha(p) for p in [*sources,Path(__file__),*[rtl/'core'/n for n in
    ('core_mem_chain.svh','core_raw_branch_mov.svh','core_raw_held_prime.svh',
     'core_ref_operand_prime.svh','core_agi_resident_prime.svh')]]}
command=[str(repo/'tools/verilator_serial.sh'),'--binary','--timing','--assert','-sv','-Wall',
    '-Wno-UNUSED','-Wno-fatal',*['-Werror-'+x for x in
    ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
    *['+define+'+x for x in ('VTM_NO_DPI','VEN_PIPE_MEM_CHAIN','VEN_PIPE_REG_LOAD_PRIME',
    'VEN_RAW_V_READ_PRIME','VEN_RAW_BRANCH_FALLTHROUGH_PRIME','VEN_L1_AXI','VEN_IC_BRAM',
    'VEN_SYS_FASTLOAD_FLAT','VEN_DBG_CORE')],'-I'+str(rtl/'core'),
    '--top-module','tb_raw_branch_guards','--Mdir',str(a.out/'obj'),'-j','1',*map(str,sources)]
with (a.out/'started.json').open('x') as f:json.dump(dict(command=command,pins=pins),f,indent=2)
result=dict(passed=False,errors=[])
try:
    with (a.out/'build.log').open('x') as f:
        p=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,timeout=180,pass_fds=(9,))
    result['build_exit']=p.returncode;assert p.returncode==0
    with (a.out/'run.log').open('x') as f:
        p=subprocess.run([str(a.out/'obj/Vtb_raw_branch_guards')],stdout=f,stderr=subprocess.STDOUT,timeout=30)
    result['run_exit']=p.returncode
    assert p.returncode==0 and 'RAW-BRANCH-GUARDS-OK' in (a.out/'run.log').read_text()
    result['passed']=True
except Exception as error:result['errors'].append(repr(error))
finally:
    result['pins_unchanged']=all(sha(p)==h for p,h in pins.items())
    result['passed'] &= result['pins_unchanged']
    with (a.out/'closed.json').open('x') as f:json.dump(result,f,indent=2)
print(json.dumps(result));raise SystemExit(0 if result['passed'] else 1)
