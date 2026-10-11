#!/usr/bin/env python3
"""Source-extracted read-hint commit checks, not full-core acceptance.

All original issue qualifiers remain in the extracted equations. Translation,
cache readiness and the shared-FP admission predicate are independent inputs;
they are not assumed to succeed. Read ACK retains the fragment hold qualifier.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

import prepare_mc_read_commit as patch


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def choose(source, name, contains):
    rows = re.findall(r'  assign '+name+r' = .*?;\n', source, re.S)
    rows = [row for row in rows if contains in row]
    assert len(rows) == 1, (name, len(rows))
    return rows[0]


def fixture(core, header, held, mutant=None):
    changed = patch.transform(core, header)
    # These are the real procedural request expressions, including the
    # mutually exclusive U load/store decode and the retained read/write owner.
    begin = core.index('    pipe_new_load_req  = ')
    end = core.index('    pipe_load_base = ', begin)
    requests = core[begin:end]
    assert requests.count('u_d.is_store') == 2
    prefix = '''`timescale 1ns/1ps
module tb;
  localparam S_PIPE=0, S_OTHER=1, FK_MEM=0;
  typedef struct packed {
    logic simple,is_mem,is_store,is_stack,is_fp,is_branch,br_taken,ext;
    logic [3:0] len;
    logic [1:0] fp_kind;
    logic [2:0] fp_role,fp_sti,fp_aluop;
  } packet_t;
  packet_t u_d,pipe_u_eff,pipe_v_eff,pipe_mem_u_q,mc_u_q;
  function automatic logic fp_is_ext_load(input packet_t u);
    return u.ext; // conservative independent extra exclusion
  endfunction
  logic state,pipe_mem_active_q,pipe_mem_we_q,pipe_mem_pair_q,mc_valid_q,mc_held_v_valid_q;
  logic fp_issue_block,exec_issue_ok,pipe_frontend_ready,fp_sys_bail,cs_extent_fault;
  logic pipe_agi,fp_pipe_rd_haz,fsm_case_enabled,pipe_pair_lookahead,mc_boundary_ok;
  logic mc_prime_u_branch,mc_prime_v_branch,mc_prime_branch,u_pred_taken,v_pred_taken;
  logic v_br_taken_eff,mc_fresh_read_pair_block,mc_prepare_ok,fp_shared_mem_admit;
  logic agi_prime_commit,ref_prime_commit,bus_read_ack,write_ack,fx_hold_e;
  logic [6:0] stall_cnt,pending_mem_pen;
  logic [2:0] mispred_bubbles;
  logic [31:0] mc_pc_q,pipe_commit_eip;
  logic pipe_new_load_req,pipe_new_store_req,pipe_new_mem_req,pipe_load_req,pipe_store_req;
  logic mc_fp_self_prime,mc_held_read_prime,mc_fresh_read_prime,mc_prime_base;
  logic mc_offer,mc_prime_offer,pipe_mem_wait,pipe_int_commit,mc_readonly_int_commit;
  logic old_commit,new_commit,mem_ack,mem_read_ack,mem_we;
  logic [63:0] rng=64'h8d304755743651a1;
  integer checks=0,commits=0,read_commits=0,nonmem_commits=0,blocked_reads=0;
  // This is the S_PIPE driver's actual load-before-store write direction.
  // Requests outside S_PIPE are zero by the extracted request equations.
  assign mem_we = state==S_PIPE ? (!pipe_load_req && pipe_store_req) : 1'b1;
  assign mem_ack = (mem_we ? write_ack : bus_read_ack) && !fx_hold_e;
  assign mem_read_ack = bus_read_ack && !fx_hold_e;
'''
    body = '  always_comb begin\n'+requests+'  end\n'
    for source, name, contains in (
            (header, 'mc_fp_self_prime', 'pipe_u_eff.is_fp'),
            (held, 'mc_held_read_prime', 'mc_held_v_valid_q'),
            (held, 'mc_fresh_read_prime', 'pipe_new_load_req'),
            (header, 'mc_prime_base', 'mc_fp_self_prime'),
            (header, 'mc_offer', 'mc_valid_q'),
            (header, 'mc_prime_offer', 'mc_prepare_ok'),
            (core, 'pipe_mem_wait', 'mem_ack'),
            (core, 'pipe_int_commit', 'fsm_case_enabled')):
        body += choose(source, name, contains)
    cofactor = patch.assignment(changed, 'mc_readonly_int_commit')
    if mutant == 'missing-read-ack':
        cofactor = cofactor.replace('(!pipe_load_req || mem_read_ack)', "1'b1")
    elif mutant == 'raw-fragment-ack':
        cofactor = cofactor.replace('mem_read_ack', 'bus_read_ack')
    body += cofactor
    old = patch.assignment(header, 'mem_next_commit').replace('mem_next_commit =', 'old_commit =')
    new = patch.assignment(changed, 'mem_next_commit').replace('mem_next_commit =', 'new_commit =')
    if mutant == 'lost-fp-admission':
        new = new.replace('(mc_fp_self_prime && fp_shared_mem_admit)', "1'b0")
    body += old+new
    suffix = '''
  task automatic defaults;
    state=S_PIPE; pipe_mem_active_q=1; pipe_mem_we_q=0;
    mc_valid_q=1; mc_held_v_valid_q=0; pipe_mem_pair_q=0; mc_boundary_ok=1;
    fp_issue_block=0; exec_issue_ok=1; pipe_frontend_ready=1; fp_sys_bail=0;
    cs_extent_fault=0; pipe_agi=0; fp_pipe_rd_haz=0; fsm_case_enabled=1;
    pipe_pair_lookahead=0; mc_prime_u_branch=0; mc_prime_v_branch=0;
    mc_prime_branch=0; u_pred_taken=0; v_pred_taken=0; v_br_taken_eff=0;
    mc_fresh_read_pair_block=0; mc_prepare_ok=1; fp_shared_mem_admit=0;
    agi_prime_commit=0; ref_prime_commit=0; bus_read_ack=1; write_ack=0; fx_hold_e=0;
    stall_cnt=0; pending_mem_pen=0; mispred_bubbles=0;
    u_d='0; pipe_u_eff='0; pipe_v_eff='0; pipe_mem_u_q='0; mc_u_q='0;
    u_d.simple=1; pipe_u_eff.simple=1; pipe_u_eff.len=3;
    mc_pc_q=3; pipe_commit_eip=0;
  endtask
  task automatic check;
    #1;
    if (old_commit !== new_commit)
      $fatal(1,"MC-READ-COMMIT-MISMATCH n=%0d old=%b new=%b load=%b store=%b ack=%b readack=%b",
             checks,old_commit,new_commit,pipe_load_req,pipe_store_req,mem_ack,mem_read_ack);
    checks++;
    if (old_commit) commits++;
    if (old_commit && pipe_load_req && !agi_prime_commit && !ref_prime_commit) read_commits++;
    if (old_commit && !pipe_load_req && !pipe_store_req) nonmem_commits++;
    if (mc_offer && pipe_load_req && !mem_ack && !old_commit) blocked_reads++;
  endtask
  initial begin
    defaults(); bus_read_ack=0; check();
    defaults(); fx_hold_e=1; check();
    defaults(); pipe_mem_active_q=0; mc_valid_q=0; pipe_u_eff.is_fp=1;
    fp_shared_mem_admit=1; check();
    // Directed Cartesian sweep: every retained owner, read/write ACK and
    // fragment hold combination, plus live nonmemory/read/store and FP modes.
    for (integer mode=0;mode<6;mode++)
      for (integer i=0;i<4096;i++) begin
        defaults();
        {bus_read_ack,write_ack,fx_hold_e,mc_boundary_ok,mc_prepare_ok,
         fsm_case_enabled,fp_issue_block,exec_issue_ok,pipe_frontend_ready,
         fp_sys_bail,pipe_agi,fp_pipe_rd_haz}=12'(i);
        case (mode)
          1: pipe_mem_we_q=1;
          2: begin pipe_mem_active_q=0; mc_valid_q=0; end
          3: begin pipe_mem_active_q=0; mc_valid_q=0; u_d.is_mem=1; end
          4: begin pipe_mem_active_q=0; mc_valid_q=0; u_d.is_mem=1; u_d.is_store=1; end
          5: begin pipe_mem_active_q=0; mc_valid_q=0; pipe_u_eff.is_fp=1; fp_shared_mem_admit=i[0]; end
          default: ;
        endcase
        check();
      end
    for (integer i=0;i<131072;i++) begin
      defaults();
      rng=rng^(rng<<13); rng=rng^(rng>>7); rng=rng^(rng<<17);
      {state,pipe_mem_active_q,pipe_mem_we_q,mc_valid_q,mc_held_v_valid_q,
       fp_issue_block,exec_issue_ok,pipe_frontend_ready,fp_sys_bail,cs_extent_fault,
       pipe_agi,fp_pipe_rd_haz,fsm_case_enabled,pipe_pair_lookahead,mc_boundary_ok,
       mc_prime_u_branch,mc_prime_v_branch,mc_prime_branch,u_pred_taken,v_pred_taken,
       v_br_taken_eff,mc_fresh_read_pair_block,mc_prepare_ok,fp_shared_mem_admit,
       agi_prime_commit,ref_prime_commit,bus_read_ack,write_ack,fx_hold_e}=rng[28:0];
      pipe_mem_pair_q=rng[29]; u_d=rng[62:40];
      pipe_u_eff=rng[50:28]; pipe_v_eff=rng[46:24];
      pipe_mem_u_q=rng[54:32]; mc_u_q=rng[38:16];
      stall_cnt=rng[63]?0:rng[62:56]; pending_mem_pen=rng[62]?0:rng[55:49];
      mispred_bubbles=rng[61]?0:rng[48:46];
      mc_pc_q={28'd0,pipe_u_eff.len}+(pipe_pair_lookahead?{28'd0,pipe_v_eff.len}:32'd0);
      if (rng[60]) mc_pc_q=~mc_pc_q;
      check();
    end
    if (!read_commits || !nonmem_commits || !blocked_reads)
      $fatal(1,"MC-READ-COMMIT missing transaction class");
    $display("MC-READ-COMMIT-LEAF-OK checks=%0d commits=%0d read=%0d nonmem=%0d blocked=%0d",
             checks,commits,read_commits,nonmem_commits,blocked_reads);
    $finish;
  end
endmodule
'''
    return prefix+body+suffix


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    root = args.out.resolve(); source = args.source.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    files = [source/name for name in ('core.sv','core_mem_chain.svh','core_raw_held_prime.svh')]
    core, header, held = [p.read_text() for p in files]
    assert sha(files[2]) == '032530542135f8744c332aa16fbfbf4bd36fac24230b8b1c20c4d989a0630040'
    changed = patch.transform(core, header)
    for badcore, badhead in ((core+'\n',header),(core,changed)):
        try: patch.transform(badcore,badhead)
        except ValueError: pass
        else: raise AssertionError('recipe accepted source drift/reapplication')
    root.mkdir()
    pins = {str(p):sha(p) for p in [Path(__file__).resolve(),Path(patch.__file__).resolve(),*files]}
    result = dict(passed=False,pins=pins,rows=[],whole_core=False,formal=False,
                  gameplay_ipc=None,fmax_mhz=None,invocation=os.environ.get('INVOCATION_ID'))
    start = time.monotonic()
    try:
        (root/'core_mem_chain.svh').write_text(changed)
        for label, mutant in [('positive',None),('missing-read-ack','missing-read-ack'),
                              ('raw-fragment-ack','raw-fragment-ack'),('lost-fp-admission','lost-fp-admission')]:
            folder = root/label; folder.mkdir()
            sv = folder/'tb.sv'; binary = folder/'a.out'
            sv.write_text(fixture(core,header,held,mutant))
            with (folder/'build.log').open('x') as stream:
                compiled = subprocess.run(['iverilog','-g2012','-DVEN_FP_PIPE','-s','tb',
                    '-o',str(binary),str(sv)],stdout=stream,stderr=subprocess.STDOUT,timeout=15)
            assert compiled.returncode == 0,label
            with (folder/'run.log').open('x') as stream:
                run = subprocess.run(['vvp',str(binary)],stdout=stream,stderr=subprocess.STDOUT,timeout=45)
            log = (folder/'run.log').read_text()
            assert (run.returncode != 0 and 'MC-READ-COMMIT-MISMATCH' in log) if mutant else (
                run.returncode == 0 and 'MC-READ-COMMIT-LEAF-OK' in log), (label,log)
            result['rows'].append(dict(label=label,native_exit=run.returncode,log=log,
                artifacts={str(p):sha(p) for p in (sv,binary,folder/'build.log',folder/'run.log')}))
        result['passed'] = True
    finally:
        result.update(seconds=time.monotonic()-start,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
        result['passed'] &= result['pins_unchanged']
        (root/'closed.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')}))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
