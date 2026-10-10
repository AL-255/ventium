#!/usr/bin/env python3
"""Test the actual private prefix-overlap admission include."""
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
assert 'VEN_P54_PREFIX_EX_SYSTEM' in (rtl/'core/core_prefix_ex_chain.svh').read_text()
sources=[rtl/'ventium_pkg.sv',rtl/'core/ventium_alu_pkg.sv',rtl/'core/ventium_decode_pkg.sv',
         here/'tb_prefix_ex_system_guards.sv']
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
pins={str(p):sha(p) for p in [*sources,Path(__file__),*[rtl/'core'/n for n in
    ('core_prefix_ex_chain.svh',)]]}
command=[str(repo/'tools/verilator_serial.sh'),'--binary','--timing','--assert','-sv','-Wall',
    '-Wno-UNUSED','-Wno-fatal',*['-Werror-'+x for x in
    ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
    *['+define+'+x for x in ('VTM_NO_DPI','VEN_P54_PREFIX_EX_CHAIN','VEN_P54_PREFIX_EX_SYSTEM',
    'VEN_P54_INT_EXEC_OCC','VEN_PIPE_SDISPATCH','VEN_PIPE_SDECODE','VEN_L1_AXI','VEN_IC_BRAM',
    'VEN_FP_PIPE','VEN_FP_PIPE2','VEN_DBG_CORE')],'-I'+str(rtl/'core'),
    '--top-module','tb_prefix_ex_system_guards','--Mdir',str(a.out/'obj'),'-j','1',*map(str,sources)]
with (a.out/'started.json').open('x') as f:json.dump(dict(command=command,pins=pins),f,indent=2)
result=dict(passed=False,errors=[])
try:
    with (a.out/'build.log').open('x') as f:
        p=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,timeout=180,pass_fds=(9,))
    result['build_exit']=p.returncode;assert p.returncode==0
    with (a.out/'run.log').open('x') as f:
        p=subprocess.run([str(a.out/'obj/Vtb_prefix_ex_system_guards')],stdout=f,stderr=subprocess.STDOUT,timeout=30)
    result['run_exit']=p.returncode
    assert p.returncode==0 and 'PREFIX-EX-SYSTEM-GUARDS-OK' in (a.out/'run.log').read_text()
    result['passed']=True
except Exception as error:result['errors'].append(repr(error))
finally:
    result['pins_unchanged']=all(sha(p)==h for p,h in pins.items())
    result['passed'] &= result['pins_unchanged']
    with (a.out/'closed.json').open('x') as f:json.dump(result,f,indent=2)
print(json.dumps(result));raise SystemExit(0 if result['passed'] else 1)
