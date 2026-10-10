#!/usr/bin/env python3
"""Actual parent/candidate miter over every beat of the existing fill corpus."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time

from run_l1_legacy_capture_cut import HERE, REPO, VL, observer, ports, sha
from prepare_l1_legacy_capture_cut import PARENT_SHA, transform


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for flag in ('parent-export','candidate','out'):ap.add_argument('--'+flag,type=Path,required=True)
    args=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    parent=args.parent_export.resolve(strict=True); candidate=args.candidate.resolve(strict=True)
    out=args.out.resolve(); assert __debug__ and out.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve().is_relative_to(scratch)
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    out.mkdir()
    old=parent/'ventium/rtl/mem/ven_l1d.sv'; assert sha(old)==PARENT_SHA
    assert candidate.read_text()==transform(old.read_text())
    manifest=parent/'input-manifest.json'
    defs=set(json.loads(manifest.read_text())['hardware_defines'])-{'SYNTHESIS'}
    extensions=[HERE/n for n in ('code_word_reuse_leaf.svh','data_under_ifill_leaf.svh','prime_under_ifill_leaf.svh')]
    base=HERE/'tb_l1d_mem_chain.sv'
    inputs=[Path(__file__),HERE/'run_l1_legacy_capture_cut.py',HERE/'prepare_l1_legacy_capture_cut.py',
            old,candidate,manifest,base,*extensions]
    modules=[parent/'ventium/rtl/mem'/n for n in ('ven_p54_bank_arb.sv','ven_p54_hit_return.sv')]
    pins={str(p):sha(p) for p in [*inputs,*modules]}
    def write(p,text):
        with p.open('x') as f:f.write(text)
        pins[str(p)]=sha(p)
    def save(n,v):
        with (out/n).open('x') as f:json.dump(v,f,indent=2);f.write('\n')
    def run(label,command,limit):
        save(label+'.command.json',list(map(str,command)))
        with (out/(label+'.log')).open('x') as log:
            rc=subprocess.run(['timeout','--kill-after=5s',str(limit)+'s',*map(str,command)],
                stdout=log,stderr=subprocess.STDOUT,pass_fds=(9,)).returncode
        return rc,(out/(label+'.log')).read_text()
    save('started.json',dict(pins=pins,invocation=os.environ.get('INVOCATION_ID')))
    result=dict(passed=False,errors=[],gameplay_ipc=None,standard_suite=False); start=time.monotonic()
    try:
        rc,pp=run('preprocess',[VL,'-E',*['+define+'+d for d in sorted(defs)],old],20);assert rc==0
        write(out/'parent_l1d.sv',old.read_text().replace('module ven_l1d #(','module parent_l1d #(')
              .replace('endmodule : ven_l1d','endmodule : parent_l1d'))
        fixture=base.read_text().replace('  ven_l1d dut(.*);','  ven_l1d dut(.*);\n'+observer(ports(pp)))
        fixture=fixture.replace('  int ticks=0, accepted=0, backing=0;',
            '  logic hold_ack=0;\n  int ticks=0, accepted=0, backing=0;')
        fixture=fixture.replace('assign m_ack=m_req && ((ticks%3)==0);','assign m_ack=m_req && !hold_ack && ((ticks%3)==0);')
        fixture=fixture.replace('  initial begin\n    for(int i=0;i<65536;i++)',
            ''.join('  `include "'+p.name+'"\n' for p in extensions)+'  initial begin\n    for(int i=0;i<65536;i++)')
        fixture=fixture.replace('    $finish;','    run_code_word_reuse();\n    run_data_under_ifill();\n    run_prime_under_ifill();\n    $display("CUT-UNDERFILL-MITER-OK samples=%0d",cut_miter_edges);\n    $finish;')
        fixture=fixture.replace('#1000000; $fatal', '#3000000; $fatal')
        write(out/'tb_l1d_mem_chain.sv',fixture)
        command=[REPO/'tools/verilator_serial.sh','--binary','--timing','--assert','-sv','-Wall','-Wno-UNUSED','-Wno-fatal',
            *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
            '-I'+str(HERE),*['+define+'+d for d in sorted(defs)],'--top-module','tb_l1d_mem_chain',
            '--Mdir',out/'obj','-j','32',*modules,out/'parent_l1d.sv',candidate,out/'tb_l1d_mem_chain.sv']
        rc,_=run('build',command,180);assert rc==0
        rc,log=run('run',[out/'obj/Vtb_l1d_mem_chain'],30);assert rc==0
        for marker in ('L1D-MEM-CHAIN-OK accepted=150','CODE-WORD-REUSE-LEAF-OK checks=51',
                       'DATA-UNDER-IFILL-OK checks=659 held_completions=640',
                       'PRIME-UNDER-IFILL-OK checks=661 completions=0'):
            assert marker in log,marker
        result.update(passed=True,native_exit=rc,binary_sha256=sha(out/'obj/Vtb_l1d_mem_chain'),
            samples=int(re.search(r'CUT-UNDERFILL-MITER-OK samples=(\d+)',log)[1]))
    except Exception as error:result['errors'].append(repr(error))
    finally:
        result.update(pins_unchanged=all(sha(p)==h for p,h in pins.items()),seconds=time.monotonic()-start)
        result['passed'] &= result['pins_unchanged'];save('pins.json',pins);save('closed.json',result)
    print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
