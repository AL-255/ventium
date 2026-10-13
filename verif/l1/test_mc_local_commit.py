"""Native commit-expression miter under independently source-audited guards.

This checks the local Boolean identity, not a full sequential core proof.
Only the selector/offer exclusion contracts are abstracted; commit and accept
expressions are extracted verbatim from their actual source.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

import prepare_mc_local_commit as recipe
from test_window_current_reuse import sha

HERE=Path(__file__).resolve().parent
TEMPLATE='''`timescale 1ns/1ps
module tb;
  logic mc_valid_q,agi_extra,ref_extra,prime_base,prime_extra,chain_extra;
  logic agi_commit_extra,ref_commit_extra,mc_prime_branch,mc_prime_u_branch;
  logic u_taken,u_pred_taken,v_br_taken_eff,v_pred_taken;
  logic mc_readonly_int_commit,mc_fp_self_prime,fp_shared_mem_admit,mem_next_ready;
  typedef struct packed {logic br_taken;} desc_t;
  wire desc_t pipe_u_eff;
  assign pipe_u_eff.br_taken=u_taken;
  wire agi_prime_select=!mc_valid_q && agi_extra;
  wire ref_prime_select=!mc_valid_q && ref_extra;
  wire agi_prime_commit=agi_prime_select && agi_commit_extra;
  wire ref_prime_commit=ref_prime_select && ref_commit_extra;
  wire mc_offer=mc_valid_q && chain_extra;
  wire mc_prime_offer=prime_base && prime_extra && !agi_prime_select && !ref_prime_select;
  wire old_commit,new_commit,mc_pipeline_commit;
  wire old_chain,new_chain,old_prime,new_prime;
  // EXTRACTED
  integer checks=0,chain_count=0,prime_count=0,other_count=0,branch_reject=0;
  initial begin
    for(integer i=0;i<262144;i++) begin
      {mc_valid_q,agi_extra,ref_extra,prime_base,prime_extra,chain_extra,
       agi_commit_extra,ref_commit_extra,mc_prime_branch,mc_prime_u_branch,
       u_taken,u_pred_taken,v_br_taken_eff,v_pred_taken,mc_readonly_int_commit,
       mc_fp_self_prime,fp_shared_mem_admit,mem_next_ready}=18'(i);
      #1;checks++;
      if ({old_commit,old_chain,old_prime} !== {new_commit,new_chain,new_prime})
        $fatal(1,"MC-LOCAL-MISMATCH case=%0d old=%b%b%b new=%b%b%b",i,
          old_commit,old_chain,old_prime,new_commit,new_chain,new_prime);
      if(new_chain) chain_count++;
      if(new_prime) prime_count++;
      if(agi_prime_commit || ref_prime_commit) other_count++;
      if(mc_prime_offer && !mc_offer && mc_prime_branch &&
         (mc_prime_u_branch ? u_taken!=u_pred_taken : v_br_taken_eff!=v_pred_taken) &&
         (mc_readonly_int_commit || (mc_fp_self_prime && fp_shared_mem_admit)) &&
         mem_next_ready && !new_prime) branch_reject++;
    end
    if(!chain_count || !prime_count || !other_count || !branch_reject)
      $fatal(1,"MC-LOCAL-COVERAGE");
    $display("MC-LOCAL-OK checks=%0d chain=%0d prime=%0d other=%0d rejected=%0d",
       checks,chain_count,prime_count,other_count,branch_reject);
    $finish;
  end
endmodule
'''


def fixture(original,changed):
    body=recipe.assignment(original,'mem_next_commit').replace('mem_next_commit','old_commit')
    body+=recipe.assignment(changed,'mc_pipeline_commit')
    body+=recipe.assignment(changed,'mem_next_commit').replace('mem_next_commit','new_commit')
    for name,label in (('mc_chain_accept','chain'),('mc_prime_accept','prime')):
        body+=recipe.assignment(original,name).replace(name,'old_'+label).replace('mem_next_commit','old_commit')
        body+=recipe.assignment(changed,name).replace(name,'new_'+label)
    return TEMPLATE.replace('  // EXTRACTED',body)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',type=Path,required=True);ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args();source=args.source.resolve(strict=True);root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert os.environ.get('INVOCATION_ID') and os.sched_getaffinity(0)=={12}
    inputs={n:(source/n).read_text() for n in recipe.PARENTS}
    changed=recipe.transform(inputs);original=inputs['core_mem_chain.svh'];restored=changed
    for old,new in reversed(list(recipe.edits(original))):
        assert restored.count(new)==1;restored=restored.replace(new,old)
    assert restored==original
    for name in recipe.PARENTS:
        bad=dict(inputs);bad[name]+='\n'
        try:recipe.transform(bad)
        except ValueError:pass
        else:raise AssertionError('accepted source drift')
    pins={str(p):sha(p) for p in (Path(__file__).resolve(),Path(recipe.__file__).resolve(),
        HERE/'test_window_current_reuse.py',*(source/n for n in recipe.PARENTS),Path('/usr/bin/iverilog'),Path('/usr/bin/vvp'))}
    root.mkdir()
    def save(name,value):
        with (root/name).open('x') as f:json.dump(value,f,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],affinity=[12]))
    (root/'core_mem_chain.svh').write_text(changed)
    tb=fixture(original,changed);cases=[('positive',tb,False)]
    # Both negative controls change only the abstract source contract. The
    # real source audit separately proves those selector exclusions exist.
    for label,old in (('unguarded-agi','wire agi_prime_select=!mc_valid_q && agi_extra;'),
                      ('unguarded-ref','wire ref_prime_select=!mc_valid_q && ref_extra;')):
        assert tb.count(old)==1
        cases.append((label,tb.replace(old,old.replace('!mc_valid_q && ','')),True))
    rows=[];errors=[];begin=time.monotonic()
    try:
        for label,text,mutant in cases:
            folder=root/label;folder.mkdir();sv=folder/'tb.sv';sv.write_text(text);binary=folder/'test.vvp'
            native=subprocess.run(['/usr/bin/iverilog','-g2012','-s','tb','-o',str(binary),str(sv)],
                capture_output=True,text=True,timeout=10)
            (folder/'build.log').write_text(native.stdout+native.stderr)
            assert native.returncode==0,native.stderr
            native=subprocess.run(['/usr/bin/vvp',str(binary)],capture_output=True,text=True,timeout=30)
            log=native.stdout+native.stderr;(folder/'run.log').write_text(log)
            assert native.returncode==(1 if mutant else 0),log
            assert ('MC-LOCAL-MISMATCH' if mutant else 'MC-LOCAL-OK checks=262144 ') in log,log
            rows.append(dict(name=label,mutant=mutant,native_exit=native.returncode,coverage=log.strip(),
                artifacts={str(p):sha(p) for p in folder.iterdir() if p.is_file()}))
    except Exception as exc:
        import traceback
        errors.append(dict(error=repr(exc),traceback=traceback.format_exc()))
    stable=all(sha(p)==h for p,h in pins.items())
    result=dict(passed=stable and not errors and len(rows)==len(cases),pins_unchanged=stable,
        errors=errors,rows=rows,seconds=time.monotonic()-begin,source_guard_files=3,source_scope_exact=True,
        derivative_sha256=sha(root/'core_mem_chain.svh'),abstract_selector_contract=True,
        sequential_core=False,hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None)
    save('closed.json',result);print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
