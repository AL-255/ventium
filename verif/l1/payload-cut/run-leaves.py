"""Bounded cache tests with ACK-equivalence assertions; not whole-core acceptance."""
import argparse, concurrent.futures, hashlib, json, os, resource, shlex, subprocess
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--work-dir',type=Path,required=True,
                    help='prepared private tree containing candidate/ and exact110.defines.args.txt')
R=parser.parse_args().work_dir.resolve(strict=True)
REPO=Path(__file__).resolve().parents[3]
# This read-only guard must inherit the launcher's lock FD. Python's default
# close_fds=True otherwise makes an actually bounded invocation look unowned.
assert subprocess.run([str(REPO/'tools/build_scope.sh'),'--is-active'],stdout=subprocess.DEVNULL,close_fds=False).returncode==0, 'use the bounded run-leaves.sh wrapper'
assert subprocess.check_output(['findmnt','-T',str(R),'-no','FSTYPE'],text=True).strip()=='ext4'
assert R.is_relative_to(Path('/home/yukidama/external/tmp').resolve()), 'external scratch required'
O=R/'leaves'; O.mkdir()
env=dict(os.environ,TMPDIR=str(R),PYTHONDONTWRITEBYTECODE='1')
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
source=R/'candidate/rtl/mem/ven_l1d.sv'
assert hashlib.sha256(source.read_bytes()).hexdigest()=='aba87b60f05c0ee5ee6d994d5d62fc8367440b11f80c419799727c35538b743e', 'expected exact reviewed owner-repaired payload candidate; do not silently inherit an old L1'
window=['VEN_L1D_WINDOW_REUSE']
two=window+['VEN_L1D_TWO_WINDOW_REUSE']
keep=two+['VEN_L1D_WINDOW_KEEP_STORE','VEN_L1D_TWO_WINDOW_KEEP_STORE']
full=shlex.split((R/'exact110.defines.args.txt').read_text())
assert len(full)==110 and len(set(full))==110
assert all(x.startswith('+define+') for x in full)
assert '+define+SYNTHESIS' not in full and '+define+VTM_NO_DPI' not in full
assert {'+define+VEN_FE_PIPE','+define+VEN_FE_DTLB_MULTI','+define+VEN_FE_DTLB_PERM',
        '+define+VEN_SYS_FASTPATH','+define+VEN_SYS_FASTPATH_RELOC',
        '+define+VEN_SYS_FASTLOAD_FLAT','+define+VEN_SYS_FASTSTORE_FLAT',
        '+define+VEN_L1D_HIT_UNDER_FILL','+define+VEN_L1D_TWO_WINDOW_REUSE'} <= set(full)
profiles=[
 ('window','tb_l1d_window_reuse',window),
 ('two','tb_l1d_window_reuse',two),
 ('keep','tb_l1d_window_reuse',keep),
 ('banked-keep','tb_l1d_window_reuse',keep+['VEN_L1D_BANKED_DATA','VEN_L1D_BANK0_SHARED_XLINE']),
 ('stream','tb_l1d_hit_stream',two+['VEN_L1D_HIT_STREAM']),
 ('wide','tb_l1d_load64',two+['VEN_FP_LOAD64','VEN_L1D_FILL_FORWARD']),
 ('coherence','tb_l1d_coherence',two),
 ('owner','tb_l1d_early_retarget',full),
]
files=[source,Path(__file__),R/'exact110.defines.args.txt',
       REPO/'verif/l1/payload-cut/primary_mux.smt2',REPO/'verif/l1/payload-cut/primary-payload.patch',
       REPO/'rtl/mem/ven_p54_bank_arb.sv',REPO/'rtl/mem/ven_p54_hit_return.sv']
files += list({REPO/f'verif/l1/{p[1]}.sv' for p in profiles})
def hashes(): return {str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
before=hashes(); (O/'inputs.json').write_text(json.dumps(before,indent=2))
def command(argv,stem,seconds=120):
    (O/(stem+'.command.json')).write_text(json.dumps([str(x) for x in argv],indent=2))
    with (O/(stem+'.log')).open('xb') as log:
        rc=subprocess.run(argv,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=seconds).returncode
    (O/(stem+'.exit')).write_text(str(rc)+'\n'); return rc
assert command(['z3',REPO/'verif/l1/payload-cut/primary_mux.smt2'],'algebra',10)==0
assert (O/'algebra.log').read_text().split()==['unsat','sat']
def run(profile):
    name,top,defs=profile
    defs=[d if d.startswith('+define+') else '+define+'+d for d in defs]
    obj=O/(name+'-obj')
    cmd=['verilator','--binary','--timing','--assert','-j','4','-sv','-Wall','-Wno-UNUSED','-Wno-fatal',
         '-Werror-IMPLICIT','-Werror-PINMISSING','-Werror-UNDRIVEN','-Werror-MULTIDRIVEN','-Werror-LATCH','-Werror-UNOPTFLAT',
         *defs,'--top-module',top,'--Mdir',obj,'-o',top,REPO/'rtl/mem/ven_p54_bank_arb.sv',
         REPO/'rtl/mem/ven_p54_hit_return.sv',source,REPO/f'verif/l1/{top}.sv']
    build=command(cmd,name+'-build')
    row=dict(profile=name,build_exit=build,passed=False,runs=[])
    if build==0:
        binary=obj/top
        row['binary_sha256']=hashlib.sha256(binary.read_bytes()).hexdigest()
        scenarios=[('hold',['+HOLD_B']),('retarget',[]),('code',['+CODE_A'])] if name=='owner' else [('run',[])]
        for label,extra in scenarios:
            rc=command([binary,*extra],name+'-'+label,30)
            row['runs'].append(dict(scenario=label,exit=rc))
        row['passed']=all(r['exit']==0 for r in row['runs'])
    print(json.dumps(row),flush=True); return row
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool: rows=list(pool.map(run,profiles))
stable=hashes()==before
(O/'result.json').write_text(json.dumps(dict(passed=stable and all(r['passed'] for r in rows),
    cases=rows,inputs_unchanged=stable,gameplay_ipc=None,standard_suite=False),indent=2))
assert stable and all(r['passed'] for r in rows)
