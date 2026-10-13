"""Source-extracted native cofactor miter, not sequential/full-PC acceptance.

The no-memory request/SMC cone is a Boolean abstraction of the pinned source
contract. All removed guard uses are compared in the actual hint equations.
Negative controls break ownership, sticky poison, or external invalidation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import traceback

import prepare_prime_coherence_cut as recipe

sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
TEMPLATE = '''`timescale 1ns/1ps
module tb;
  localparam S_PIPE=1;
  reg state,pipe_mem_active_q,pipe_agi,fp_sys_bail,live_extra,fx_act;
  reg load_shape,store_shape,pair_rest,mem_store_pair_ready,ic_snoop_valid;
  reg rep_stos_cont_poison_q,rep_stos_cont_redecode_q,rep_stos_cont_q;
  reg rep_stos_cont_ready_noevent,fp_irq_divert,hit1,hit2,bypass_hit,extra;
  wire rep_stos_cont_hold=rep_stos_cont_ready_noevent && !fp_irq_divert;
  wire fp_issue_block=rep_stos_cont_hold || rep_stos_cont_redecode_q || !live_extra;
  wire cycle_mode=1,real_bus=1,exec_issue_ok=1,pipe_frontend_ready=1;
  wire fsm_case_enabled=live_extra;
  wire [6:0] stall_cnt=0,pending_mem_pen=0;
  wire pipe_prime_live_arm;
  // Request shape/rest can be arbitrary: both original new requests include
  // !pipe_agi && !fp_sys_bail, and the hint live arm excludes a held packet.
  wire no_new_guard=!pipe_agi && !fp_sys_bail;
  wire pipe_load_req=state && (pipe_mem_active_q ? load_shape : no_new_guard && load_shape);
  wire pipe_store_req=state && (pipe_mem_active_q ? store_shape : no_new_guard && store_shape);
  wire mem_store_pair_req=(pipe_load_req || pipe_store_req) && pair_rest && mem_store_pair_ready;
  wire mem_we=state && !pipe_load_req && pipe_store_req;
  wire smc_v1=state && (pipe_store_req || fx_act);
  wire icsnp_v1=mem_we || smc_v1;
  wire ic_snoop_valid2=mem_we || mem_store_pair_req;
  wire icsnp_v2=ic_snoop_valid2 || smc_v1;
  wire ic_snp1_hit=icsnp_v1 && hit1,ic_snp2_hit=icsnp_v2 && hit2;
  wire rep_stos_cont_icbp_snoop_hit=(icsnp_v1 || icsnp_v2) && bypass_hit;
  wire exec_flush_all=ic_snoop_valid,rep_stos_cont_snoop_now=ic_snoop_valid;
  wire rep_stos_cont_inval_now=exec_flush_all || rep_stos_cont_snoop_now ||
      ic_snp1_hit || ic_snp2_hit || rep_stos_cont_icbp_snoop_hit;
  wire rep_stos_cont_recovery_need=rep_stos_cont_redecode_q ||
      (rep_stos_cont_q && (rep_stos_cont_poison_q || rep_stos_cont_inval_now));
  wire rep_stos_cont_take=rep_stos_cont_ready_noevent && !rep_stos_cont_inval_now && !fp_irq_divert;
  // Offers ordinarily exclude external invalidation too. Leave it possible
  // here to strengthen the cofactor check and test the retained guard.
  wire agi_prime_offer=!fx_act && extra,ref_prime_offer=!fx_act && extra;
  wire pipe_fetch_checked_handoff=0,fp_pipe_rd_haz=0,fp_dbg_active=0;
  wire dbg_step_active=0,dbg_block_issue=0,irq_shadow=0;
  wire [2:0] mispred_bubbles=0;
  wire d_is_x87=0,pipe_sdispatch_short_window_ok=1,pipe_fp_scalar_dispatch_ok=1;
  wire fp_shared_mem_admit=0,fp_shared_direct=0;
  wire old_agi,new_agi,old_ref,new_ref;
  // EXTRACTED
  integer checks=0,agi=0,refs=0,blocked_poison=0,blocked_external=0,own_stores=0;
  initial begin
    for(integer i=0;i<1048576;i++) begin
      {state,pipe_mem_active_q,pipe_agi,fp_sys_bail,live_extra,fx_act,
       load_shape,store_shape,pair_rest,mem_store_pair_ready,ic_snoop_valid,
       rep_stos_cont_poison_q,rep_stos_cont_redecode_q,rep_stos_cont_q,
       rep_stos_cont_ready_noevent,fp_irq_divert,hit1,hit2,bypass_hit,extra}=20'(i);
      #1;checks++;
      if({old_agi,old_ref} !== {new_agi,new_ref})
        $fatal(1,"PRIME-COHERENCE-MISMATCH case=%0d old=%b%b new=%b%b",i,old_agi,old_ref,new_agi,new_ref);
      if(new_agi)agi++;if(new_ref)refs++;
      if(extra && !fx_act && pipe_prime_live_arm) begin
        if(icsnp_v1 || icsnp_v2 || rep_stos_cont_take)
          $fatal(1,"PRIME-COHERENCE-OWNER case=%0d",i);
        if(rep_stos_cont_q && rep_stos_cont_poison_q && !new_agi && !new_ref)blocked_poison++;
        if(rep_stos_cont_q && ic_snoop_valid && !new_agi && !new_ref)blocked_external++;
      end
      if(mem_store_pair_req)own_stores++;
    end
    if(!agi || !refs || !blocked_poison || !blocked_external || !own_stores)$fatal(1,"COVERAGE");
    $display("PRIME-COHERENCE-OK checks=%0d agi=%0d ref=%0d poison=%0d external=%0d stores=%0d",
        checks,agi,refs,blocked_poison,blocked_external,own_stores);
    $finish;
  end
endmodule
'''


def fixture(before, after):
    body = recipe.assignment(before['rtl/core/core.sv'], 'pipe_prime_live_arm')
    for path, kind in zip(recipe.CHANGES, ('agi', 'ref')):
        name=kind+'_prime_commit'
        body += recipe.assignment(before[path], name).replace(name, 'old_'+kind)
        body += recipe.assignment(after[path], name).replace(name, 'new_'+kind)
    return TEMPLATE.replace('  // EXTRACTED',body)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',type=Path,required=True);ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args();source=args.source.resolve(strict=True);root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert os.environ.get('INVOCATION_ID') and os.sched_getaffinity(0)=={12}
    inputs={n:(source/n).read_text() for n in recipe.PARENTS};changed=recipe.transform(inputs)
    assert sorted(n for n in inputs if inputs[n]!=changed[n])==sorted(recipe.CHANGES)
    for path,kind in zip(recipe.CHANGES,('agi','ref')):
        old,new=recipe.edits(inputs[path],kind)
        assert changed[path].replace(new,old)==inputs[path]
    for name in inputs:
        bad=dict(inputs);bad[name]+='\n'
        try:recipe.transform(bad)
        except ValueError:pass
        else:raise AssertionError('accepted source drift')
    pins={str(p):sha(p) for p in (Path(__file__).resolve(),Path(recipe.__file__).resolve(),
        Path(recipe.__file__).with_name('prepare_mc_local_commit.py'),
        *(source/n for n in inputs),Path('/usr/bin/iverilog'),Path('/usr/bin/vvp'))}
    root.mkdir()
    def save(name,value):
        with (root/name).open('x') as f:json.dump(value,f,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],affinity=[12]))
    for path in recipe.CHANGES:(root/Path(path).name).write_text(changed[path])
    positive=fixture(inputs,changed)
    cases=[('positive',positive,False)]
    # Remove poison/external only from the new commit equations.
    for label,token in [('lost-poison','rep_stos_cont_poison_q'),('lost-external','exec_flush_all || rep_stos_cont_snoop_now')]:
        bad=dict(changed)
        for path,kind in zip(recipe.CHANGES,('agi','ref')):
            old=recipe.assignment(bad[path],kind+'_prime_commit')
            new=old.replace(token,"1'b0")
            assert new!=old;bad[path]=bad[path].replace(old,new)
        cases.append((label,fixture(inputs,bad),True))
    cases.append(('broken-owner',positive.replace('wire no_new_guard=!pipe_agi && !fp_sys_bail;',
                                                 "wire no_new_guard=1'b1;"),True))
    begin=time.monotonic();rows=[];errors=[]
    try:
        for label,text,mutant in cases:
            folder=root/label;folder.mkdir();sv=folder/'tb.sv';sv.write_text(text)
            binary=folder/'test.vvp'
            child=subprocess.run(['/usr/bin/iverilog','-g2012','-DVEN_FP_PIPE','-s','tb','-o',str(binary),str(sv)],
                capture_output=True,text=True,timeout=10)
            (folder/'build.log').write_text(child.stdout+child.stderr);assert child.returncode==0,child.stderr
            child=subprocess.run(['/usr/bin/vvp',str(binary)],capture_output=True,text=True,timeout=45)
            log=child.stdout+child.stderr;(folder/'run.log').write_text(log)
            assert child.returncode==(1 if mutant else 0),log
            marker=('PRIME-COHERENCE-OWNER' if label=='broken-owner' else
                    'PRIME-COHERENCE-MISMATCH' if mutant else 'PRIME-COHERENCE-OK checks=1048576 ')
            assert marker in log,log
            rows.append(dict(name=label,mutant=mutant,native_exit=child.returncode,coverage=log.strip(),
                             artifacts={str(p):sha(p) for p in folder.iterdir()}))
    except Exception as exc:errors.append(dict(error=repr(exc),traceback=traceback.format_exc()))
    stable=all(sha(p)==h for p,h in pins.items())
    result=dict(passed=not errors and stable,rows=rows,errors=errors,pins_unchanged=stable,
        seconds=time.monotonic()-begin,source_guard_files=len(inputs),abstract_ownership_cone=True,
        sequential_core=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,
        derivatives={p:sha(root/Path(p).name) for p in recipe.CHANGES})
    save('closed.json',result);print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
