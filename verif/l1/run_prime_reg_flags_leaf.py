"""Source-extracted branch-prime commit miter, not a core or timing pass."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time

import prepare_prime_reg_flags as recipe
from run_parallel_tag_cache import sha

HERE=Path(__file__).resolve().parent


def once(source,pattern):
    rows=re.findall(pattern,source,re.M|re.S)
    assert len(rows)==1,(pattern,len(rows))
    return rows[0]


def module(sources,mutant=None):
    header=sources['core_mem_chain.svh']
    original=recipe.commit(header).replace('mc_pipeline_commit','old_commit',1)
    updated=recipe.commit(header).replace('v_br_taken_eff','mc_reg_v_br_taken')
    assert recipe.transform(sources).count(updated)==1
    candidate=updated.replace('mc_pipeline_commit','new_commit',1)
    added=recipe.ADDED
    if mutant=='stale-alu':
        added=added.replace('pipe_u_eff.wflags ? mc_reg_u_flags : eflags','eflags')
    elif mutant=='stale-shift':
        added=added.replace('if (pipe_u_eff.is_shift)',"if (1'b0)")
    elif mutant=='wrong-prediction':
        candidate=candidate.replace('mc_reg_v_br_taken == v_pred_taken','mc_reg_v_br_taken != v_pred_taken')
    else:
        assert mutant is None
    start=header.index('`ifdef VEN_PIPE_BRANCH_LOAD_PRIME\n`ifndef VEN_PIPE_REG_LOAD_PRIME')
    stop=header.index('  assign mc_query_pc =',start)
    guards=header[start:stop]
    text='''module prime_reg_leaf
  import ventium_decode_pkg::*;
  import ventium_alu_pkg::*;
(
 input fpd_t pipe_u_eff,pipe_v_eff,
 input logic [31:0] u_dst_reg_val,u_src_reg_val,mem_rdata,eflags,u_sh,u_shm1,
 input logic u_shcf,mc_valid_q,pipe_mem_active_q,pipe_pair_lookahead,
 input logic u_pred_taken,v_pred_taken,mc_offer,mc_prime_offer,
 input logic mc_readonly_int_commit,mc_fp_self_prime,fp_shared_mem_admit,
 output logic old_commit,new_commit,mc_prime_v_branch,v_br_taken_eff,mc_reg_v_br_taken
);
 logic [31:0] u_dst_val,u_src_val,u_flags;
 logic mc_prime_u_branch,mc_prime_branch;
'''
    for key in ('u_dst_val','u_src_val'):
        text+=once(sources['core.sv'],r'^  assign '+key+r' =.*?;\n')
    text+=once(sources['core.sv'],r'^  u_pipe u_upipe \(.*?^  \);\n').replace('.u_alu     (u_alu)', '.u_alu     ()')
    text+='''  uv_common original_branch (
    .eflags(eflags),.bcd_eax16(16'd0),.bcd_imm8(8'd0),.bcd_alu_op(5'd0),
    .bcd_ax(),.bcd_flags(),.u_d(pipe_u_eff),.v_d(pipe_v_eff),
    .u_flags(u_flags),.u_sh(u_sh),.u_shm1(u_shm1),.u_shcf(u_shcf),
    .v_br_taken_eff(v_br_taken_eff)
  );
'''
    # The new decision is an output for anti-vacuity checks in the bench.
    added=added.replace('  logic mc_reg_v_br_taken;\n','')
    return text+guards+added+original+candidate+'endmodule\n'


def bench():
    return '''module tb_prime_reg_flags;
  import ventium_decode_pkg::*;
  import ventium_alu_pkg::*;
  fpd_t pipe_u_eff,pipe_v_eff;
  logic [31:0] u_dst_reg_val,u_src_reg_val,mem_rdata,eflags,u_sh,u_shm1;
  logic u_shcf,mc_valid_q,pipe_mem_active_q,pipe_pair_lookahead;
  logic u_pred_taken,v_pred_taken,mc_offer,mc_prime_offer;
  logic mc_readonly_int_commit,mc_fp_self_prime,fp_shared_mem_admit;
  wire old_commit,new_commit,mc_prime_v_branch,v_br_taken_eff,mc_reg_v_br_taken;
  prime_reg_leaf dut(.*);
  integer seed=32'h61425783;
  integer guarded=0,accepted=0,rejected=0,alu=0,shifted=0,preserved=0;
  integer unrelated_difference=0;
  logic [15:0] cc_seen=0;
  initial begin
    for(integer i=0;i<65536;i=i+1) begin
      pipe_u_eff='0;pipe_v_eff='0;
      pipe_u_eff.simple=1;pipe_v_eff.simple=1;
      pipe_u_eff.alu_op=5'(i>>9);pipe_u_eff.wflags=1'(i>>4);
      pipe_u_eff.w8=1'(i>>7);pipe_u_eff.w16=1'(i>>8);
      pipe_u_eff.is_mem=1'(i>>5);pipe_u_eff.mem_lhs=1'(i>>6);
      pipe_u_eff.is_load=1'($random(seed));pipe_u_eff.is_store=1'($random(seed));
      pipe_u_eff.is_branch=1'(i>>13);pipe_u_eff.br_cond=1;
      pipe_u_eff.is_shift=1'(i>>11);pipe_u_eff.shrot=3'($random(seed));
      pipe_u_eff.shimm=5'($random(seed));pipe_u_eff.use_imm=1'(i>>12);
      pipe_u_eff.imm=$random(seed);pipe_u_eff.br_taken=1'($random(seed));
      pipe_v_eff.is_branch=1;pipe_v_eff.br_cond=1;pipe_v_eff.cc=4'(i);
      u_dst_reg_val=$random(seed);u_src_reg_val=$random(seed);mem_rdata=$random(seed);
      eflags=$random(seed);u_sh=$random(seed);u_shm1=$random(seed);u_shcf=1'($random(seed));
      case(i%16)
        0: begin u_dst_reg_val=0;u_src_reg_val=0;end
        1: begin u_dst_reg_val=32'hffffffff;u_src_reg_val=1;end
        2: begin u_dst_reg_val=32'h7fffffff;u_src_reg_val=1;end
        3: begin u_dst_reg_val=32'h80000000;u_src_reg_val=32'hffffffff;end
        4: begin u_dst_reg_val=32'h00008000;u_src_reg_val=1;end
        5: begin u_dst_reg_val=32'h00000080;u_src_reg_val=1;end
        default: ;
      endcase
      mc_valid_q=1'($random(seed));pipe_mem_active_q=1'($random(seed));
      pipe_pair_lookahead=1'($random(seed));u_pred_taken=1'($random(seed));
      v_pred_taken=1'($random(seed));mc_offer=1'($random(seed));mc_prime_offer=1'($random(seed));
      mc_readonly_int_commit=1'($random(seed));mc_fp_self_prime=1'($random(seed));
      fp_shared_mem_admit=1'($random(seed));
      // One half forces a real eligible V-branch; every cc/width/ALU and
      // stale/current carry combination still varies. The other half checks
      // complete rejection/retained/U-branch/FP-hint equations too.
      if((i%2)==0) begin
        mc_valid_q=0;pipe_mem_active_q=0;pipe_pair_lookahead=1;
        pipe_u_eff.is_mem=0;pipe_u_eff.is_store=0;pipe_u_eff.is_branch=0;
        v_pred_taken=0;mc_offer=0;mc_prime_offer=1;mc_readonly_int_commit=1;
        pipe_v_eff.cc=4'(i>>1);
      end
      #1;
      if(old_commit !== new_commit)
        $fatal(1,"PRIME-REG-MISMATCH i=%0d old=%b new=%b cc=%h op=%h",i,old_commit,new_commit,pipe_v_eff.cc,pipe_u_eff.alu_op);
      if(mc_prime_v_branch) begin
        if(v_br_taken_eff !== mc_reg_v_br_taken)$fatal(1,"PRIME-REG-OUTCOME i=%0d",i);
        guarded=guarded+1;cc_seen[pipe_v_eff.cc]=1;
        if(old_commit)accepted=accepted+1;else rejected=rejected+1;
        if(pipe_u_eff.is_shift)shifted=shifted+1;
        else if(pipe_u_eff.wflags)alu=alu+1;else preserved=preserved+1;
      end else if(v_br_taken_eff !== mc_reg_v_br_taken)
        unrelated_difference=unrelated_difference+1;
    end
`ifdef VEN_RAW_BRANCH_FALLTHROUGH_PRIME
    if(guarded==0 || accepted==0 || rejected==0 || alu==0 || shifted==0 || preserved==0 || cc_seen!=16'hffff)
      $fatal(1,"missing guarded branch coverage");
`elsif VEN_PIPE_BRANCH_LOAD_PRIME
    if(guarded==0 || accepted==0 || rejected==0 || alu==0 || shifted==0 || preserved==0 || cc_seen!=16'hffff)
      $fatal(1,"missing guarded branch coverage");
`else
    if(guarded!=0)$fatal(1,"unexpected branch admission without feature");
`endif
    if(unrelated_difference==0)$fatal(1,"missing memory-source anti-vacuity");
    $display("PRIME-REG-LEAF-OK checks=65536 guarded=%0d accepted=%0d rejected=%0d alu=%0d shift=%0d preserve=%0d unrelated=%0d",
      guarded,accepted,rejected,alu,shifted,preserved,unrelated_difference);
    $finish;
  end
endmodule
'''


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for key in ('source','out'):
        ap.add_argument('--'+key,required=True,type=Path)
    args=ap.parse_args()
    source,root=args.source.resolve(strict=True),args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and os.environ.get('INVOCATION_ID') and os.sched_getaffinity(0)==set(range(32))
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE']=='ipc_parallel32'
    assert os.environ['VENTIUM_BUILD_SCOPE_UNIT']=='ventium-ipc-parallel32'
    assert os.environ['VENTIUM_VERILATOR_BIN']=='/tools/verilator/v5.046/bin/verilator'
    subprocess.run([HERE.parents[1]/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    assert Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and root!=scratch and not root.exists()
    sources={name:(source/name).read_text() for name in recipe.PARENTS}
    candidate=recipe.transform(sources)
    pins={str(p):sha(p) for p in [Path(__file__),Path(recipe.__file__),HERE/'run_parallel_tag_cache.py',
          Path('/tools/verilator/v5.046/bin/verilator'),HERE.parents[1]/'tools/build_scope.sh',
          HERE.parents[1]/'tools/verilator_serial.sh',*[source/n for n in recipe.PARENTS]]}
    root.mkdir()
    for name,text in sources.items():
        (root/name).write_text(text)
    (root/'candidate_core_mem_chain.svh').write_text(candidate)
    def save(name,value):
        with (root/name).open('x') as stream:json.dump(value,stream,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],affinity=list(range(32))))
    result=dict(passed=False,rows=[],errors=[],whole_core_qualified=False,timing_measured=False,standard_suite=False,gameplay_ipc=None)
    begin=time.monotonic()
    try:
        cases=[(branch,ror,None) for branch in (0,1,2) for ror in (0,1)]
        cases += [(2,1,mutation) for mutation in ('stale-alu','stale-shift','wrong-prediction')]
        for branch,ror,mutation in cases:
            name=f'b{branch}-r{ror}-'+(mutation or 'positive')
            folder=root/name;folder.mkdir()
            (folder/'miter.sv').write_text(module(sources,mutation)+bench())
            defines=['-DVEN_PIPE_REG_LOAD_PRIME']
            if branch==1:defines+=['-DVEN_PIPE_BRANCH_LOAD_PRIME']
            if branch==2:defines+=['-DVEN_RAW_BRANCH_FALLTHROUGH_PRIME']
            if ror:defines+=['-DVEN_FAST_ROR_IMM']
            command=[HERE.parents[1]/'tools/verilator_serial.sh','--binary','--timing','--assert',
                '-j','32','--top-module','tb_prime_reg_flags','--Mdir',folder/'obj',
                '-Wno-fatal','-Wno-UNUSED',
                *['-Werror-'+warning for warning in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                *defines,
                *[root/n for n in ('ventium_alu_pkg.sv','ventium_decode_pkg.sv','u_pipe.sv','uv_common.sv')],folder/'miter.sv']
            for stage,cmd in (('compile',command),('simulate',[folder/'obj/Vtb_prime_reg_flags'])):
                with (folder/(stage+'-command.json')).open('x') as stream:
                    json.dump(list(map(str,cmd)),stream,indent=2)
                with (folder/(stage+'.log')).open('x') as stream:
                    native=subprocess.run(cmd,stdout=stream,stderr=subprocess.STDOUT,pass_fds=(9,),timeout=50)
                if stage=='compile':assert native.returncode==0,(name,'compile')
            log=(folder/'simulate.log').read_text()
            assert (native.returncode!=0 and ('PRIME-REG-MISMATCH' in log or 'PRIME-REG-OUTCOME' in log)) if mutation else (native.returncode==0 and 'PRIME-REG-LEAF-OK checks=65536 ' in log),(name,log)
            result['rows'].append(dict(name=name,native_exit=native.returncode,expected_failure=bool(mutation),
                coverage=log.strip(),artifacts={str(p):sha(p) for p in folder.iterdir() if p.is_file()}))
        result['passed']=True
    except Exception as error:
        result['errors'].append(repr(error))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=all(sha(p)==h for p,h in pins.items()),
                  derivative_sha256=sha(root/'candidate_core_mem_chain.svh'))
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='rows'}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
