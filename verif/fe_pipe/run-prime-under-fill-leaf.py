#!/usr/bin/env python3
"""Cold leaf A/B with the real fill state machine and held backing slave."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]

def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('control-source','candidate-source','profile','out'):
        parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args()
    assert Path(os.environ['TMPDIR']).resolve()==Path('/home/yukidama/external/tmp').resolve()
    assert args.out.resolve().is_relative_to(Path(os.environ['TMPDIR']).resolve())
    args.out.mkdir()
    tb=REPO/'verif/l1/tb_l1d_mem_chain.sv'
    additions=[HERE/'prime_pair_owner_leaf.svh',HERE/'prime_under_fill_leaf.svh']
    text=tb.read_text()
    replacements={
        '  int ticks=0, accepted=0, backing=0;':'  logic hold_ack=0;\n  int ticks=0, accepted=0, backing=0;',
        '  assign m_ack=m_req && ((ticks%3)==0);':'  assign m_ack=m_req && !hold_ack && ((ticks%3)==0);',
        '      if((c_req && !c_ack) || m_req)':'''      if((c_req && !c_ack) || (m_req &&
         !(dut.mc_lookup_prime && dut.st==dut.L1_FILL &&
           c_next_addr[5 +: 7] != dut.fset)))''',
        '  initial begin\n    for(int i=0;i<65536;i++)':'  `include "prime_under_fill_leaf.svh"\n  initial begin\n    for(int i=0;i<65536;i++)',
        '    $finish;':'    `include "prime_pair_owner_leaf.svh"\n    run_prime_under_fill();\n    $finish;',
    }
    for old,new in replacements.items():
        assert text.count(old)==1,old
        text=text.replace(old,new)
    generated=args.out/'tb_l1d_mem_chain.sv';generated.write_text(text)
    command=next(l for l in args.profile.read_text().splitlines() if l.startswith('C '))
    defs=set(re.findall(r'\+define\+(\w+)',command))
    assert {'VEN_L1D_HIT_UNDER_FILL','VEN_RAW_V_READ_PRIME','VEN_FP_RESIDENT_PRIME'}<=defs
    assert 'VEN_L1D_PRIME_UNDER_FILL' not in defs
    pins={str(p.resolve()):sha(p) for p in [Path(__file__),tb,*additions,args.profile,generated]}
    result=dict(passed=False,variants=[],gameplay_ipc=None,standard_suite=False)
    env=dict(os.environ,CCACHE_DISABLE='1',PYTHONDONTWRITEBYTECODE='1')
    try:
        for name,source in [('control',args.control_source),('candidate',args.candidate_source)]:
            directory=args.out/name;directory.mkdir()
            files=[source/'rtl/mem'/x for x in ('ven_p54_bank_arb.sv','ven_p54_hit_return.sv','ven_l1d.sv')]
            pins.update({str(p.resolve()):sha(p) for p in files})
            variant=defs|({'VEN_L1D_PRIME_UNDER_FILL'} if name=='candidate' else set())
            cmd=['timeout','--kill-after=5s','180s','/tools/verilator/v5.046/bin/verilator',
                 '--binary','--timing','-sv','--assert','-j','32','-Wno-fatal','-Wno-UNUSED',
                 *['-Werror-'+k for k in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                 '-I'+str(HERE),'--top-module','tb_l1d_mem_chain','--Mdir',str(directory/'obj'),'-o','test',
                 *['+define+'+d for d in sorted(variant)],*map(str,files),str(generated)]
            (directory/'command.json').write_text(json.dumps(cmd,indent=2)+'\n')
            with (directory/'build.log').open('x') as f:
                rc=subprocess.run(cmd,env=env,stdout=f,stderr=subprocess.STDOUT).returncode
            row=dict(name=name,build_exit=rc);result['variants'].append(row)
            assert rc==0,(name,'build',rc)
            with (directory/'run.log').open('x') as f:
                rc=subprocess.run(['timeout','30s',directory/'obj/test'],env=env,stdout=f,stderr=subprocess.STDOUT).returncode
            row['native_exit']=rc
            log=(directory/'run.log').read_text()
            assert rc==0 and 'L1D-MEM-CHAIN-OK accepted=150' in log and 'PRIME-PAIR-OWNER-LEAF-OK checks=3' in log
            assert 'PRIME-UNDER-FILL-LEAF-OK checks=51' in log
            row['binary_sha256']=sha(directory/'obj/test')
        result['passed']=True
    finally:
        result['inputs_unchanged']=all(sha(p)==h for p,h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        (args.out/'inputs.json').write_text(json.dumps(pins,indent=2)+'\n')
        (args.out/'closed.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps(result,indent=2),flush=True)
    assert result['passed']

if __name__=='__main__':main()
