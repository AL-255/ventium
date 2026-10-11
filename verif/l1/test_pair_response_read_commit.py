#!/usr/bin/env python3
"""Exercise extracted U/V owner transitions and a prospective response cut.

No full core or cache is instantiated. Decoder/translation/admission conditions
are independent inputs; fresh V acceptance obeys the existing core assertion.
Only the target raw-prime / no-dual-prime / no-regmem profile is covered.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time

from prove_pair_response_read_commit import CORE, sha


def equation(source, name, contains):
    matches = [s for s in re.findall(r'  assign '+name+r' = .*?;\n', source, re.S)
               if contains in s]
    assert len(matches) == 1, (name, len(matches))
    return matches[0]


def between(source, start, end):
    assert source.count(start) == 1, start
    begin = source.index(start)
    return source[begin:source.index(end, begin)]


def fixture(core, mutant=None):
    requests = between(core, '    pipe_new_load_req  = ', '    pipe_load_base = ')
    hit = between(core, '`ifdef VEN_P54_DUAL_LOAD_PAIR\n      // Only a fresh U capture',
                  '`ifndef SYNTHESIS\n      if (smi_apic_store_commit')
    owner = between(core, '      if (pipe_mem_active_q && (state == S_PIPE) && !pipe_mem_abort_now &&\n',
                    '      // A LOCK session starts only')
    commit = equation(core, 'pipe_int_commit', 'fsm_case_enabled')
    readcommit = commit.replace('pipe_int_commit =', 'pair_read_commit =').replace(
        '!pipe_mem_wait', '!pipe_store_req && (!pipe_load_req || mem_read_ack)')
    old = equation(core, 'mem_pair_rsp_ready', '!pipe_mem_v_hit_q').replace(
        'mem_pair_rsp_ready =', 'old_ready =')
    new = old.replace('old_ready =', 'new_ready =').replace('pipe_int_commit', 'pair_read_commit')
    fault = '      pipe_mem_active_q <= 1\'b0;\n      pipe_mem_v_hit_q <= 1\'b0;\n'
    if mutant == 'missing-read-ack':
        readcommit = readcommit.replace('(!pipe_load_req || mem_read_ack)', "1'b1")
    elif mutant == 'raw-fragment-ack':
        readcommit = readcommit.replace('mem_read_ack', 'bus_read_ack')
    elif mutant == 'lost-orphan-drain':
        new = new.replace('(!pipe_mem_v_hit_q || pair_read_commit)', 'pair_read_commit')
    elif mutant == 'lost-fault-clear':
        fault = fault.replace("      pipe_mem_v_hit_q <= 1'b0;\n", '')
    prefix = '''`timescale 1ns/1ps
module tb;
  localparam S_PIPE=0,S_OTHER=1,S_HALT=2,S_SHUTDOWN=3;
  logic clk=0,rst_n=0,take_fault=0;
  logic [1:0] state;
  typedef struct packed {logic simple,is_mem,is_store,is_fp; logic [3:0] len;} packet_t;
  packet_t u_d,v_d,pipe_u_eff,pipe_mem_u_q,pipe_mem_v_q,mc_u_q,mc_v_q;
  logic pipe_mem_active_q,pipe_mem_we_q,pipe_mem_v_hit_q,pipe_mem_pair_q;
  logic fp_issue_block,exec_issue_ok,pipe_frontend_ready,fp_sys_bail,cs_extent_fault;
  logic pipe_agi,fp_pipe_rd_haz,fsm_case_enabled;
  logic [6:0] stall_cnt,pending_mem_pen;
  logic [2:0] mispred_bubbles;
  logic pipe_new_load_req,pipe_new_store_req,pipe_new_mem_req,pipe_load_req,pipe_store_req;
  logic pipe_mem_wait,pipe_int_commit,pair_read_commit,mem_ack,mem_read_ack,mem_we;
  logic bus_read_ack,write_ack,fx_hold_e,xlate_miss,fe_xlate_pend,pipe_mem_abort_now;
  logic pipe_v_pair_accept,bank_accept,mc_chain_accept,mc_prime_accept,mc_pair_q,pipe_pair;
  logic [31:0] pipe_mem_v_phys_q,pipe_v_pair_phys,pipe_mem_ea_q,pipe_mem_eip_q;
  logic [31:0] pipe_mem_wdata_q,pipe_store_data,pipe_load_addr,eip,mc_ea_q,mc_pc_q;
  logic [2:0] pipe_mem_seg_q,pipe_mem_seg,mc_seg_q;
  logic [1:0] mem_pair_rsp_valid,old_ready,new_ready;
  logic [63:0] rng=64'h12349a239405ffa8;
  integer checks=0,owned=0,read_waits=0,stores=0,orphans=0,accepts=0;
  assign pipe_u_eff=pipe_mem_active_q ? pipe_mem_u_q : u_d;
  assign mem_we=state==S_PIPE ? (!pipe_load_req && pipe_store_req) : 1'b1;
  assign mem_ack=(mem_we ? write_ack : bus_read_ack) && !fx_hold_e;
  assign mem_read_ack=bus_read_ack && !fx_hold_e;
  // Conservatively arbitrary cache/bank acceptance, constrained only by the
  // existing fresh-V assertion in the exact source. Not a cache proof.
  assign pipe_v_pair_accept=bank_accept && pipe_new_load_req && !mem_ack && !pipe_mem_abort_now;
'''
    body = '  always_comb begin\n'+requests+'  end\n'
    body += equation(core, 'pipe_mem_wait', 'mem_ack')+commit+readcommit+old+new
    body += '''  always @(posedge clk) begin
    if (!rst_n) begin
      pipe_mem_active_q<=0; pipe_mem_we_q<=0; pipe_mem_v_hit_q<=0;
      pipe_mem_u_q<='0; pipe_mem_v_q<='0; pipe_mem_pair_q<=0;
    end else begin
'''+hit+owner+'''      if (take_fault) begin
'''+fault+'''      end
    end
  end
'''
    suffix = '''
  task automatic defaults;
    state=S_PIPE; take_fault=0; u_d='0; v_d='0; u_d.simple=1; u_d.is_mem=1;
    fp_issue_block=0; exec_issue_ok=1; pipe_frontend_ready=1; fp_sys_bail=0;
    cs_extent_fault=0; pipe_agi=0; fp_pipe_rd_haz=0; fsm_case_enabled=1;
    stall_cnt=0; pending_mem_pen=0; mispred_bubbles=0;
    bus_read_ack=0; write_ack=1; fx_hold_e=0; xlate_miss=0; fe_xlate_pend=0;
    pipe_mem_abort_now=0; bank_accept=1; mc_chain_accept=0; mc_prime_accept=0;
    mc_pair_q=0; pipe_pair=0; mc_u_q='0; mc_v_q='0;
    pipe_v_pair_phys=32'h1004; pipe_store_data=0; pipe_load_addr=32'h1000;
    eip=0; mc_ea_q=32'h2000; mc_pc_q=10; pipe_mem_seg=0; mc_seg_q=0;
    mem_pair_rsp_valid=2'b10;
  endtask
  task automatic check;
    #1;
    if (rst_n) begin
      if (pipe_mem_v_hit_q && (!pipe_mem_active_q || pipe_mem_we_q))
        $fatal(1,"PAIR-RESPONSE owner invariant n=%0d",checks);
      if (old_ready !== new_ready)
        $fatal(1,"PAIR-RESPONSE ready mismatch n=%0d old=%b new=%b",checks,old_ready,new_ready);
      checks++;
      if (pipe_mem_v_hit_q) owned++;
      if (pipe_mem_v_hit_q && !mem_read_ack) read_waits++;
      if (pipe_mem_active_q && pipe_mem_we_q) stores++;
      if (!pipe_mem_v_hit_q && old_ready[1]) orphans++;
      if (pipe_v_pair_accept) accepts++;
    end
    clk=1; #1; clk=0;
  endtask
  initial begin
    defaults(); check(); rst_n=1;
    // Real source transitions: fresh pair, held read, fragment, then precise
    // fault and orphan draining even while global issue is blocked.
    check(); check(); bus_read_ack=1; fx_hold_e=1; check();
    take_fault=1; check(); defaults(); fp_issue_block=1; check();
    defaults(); u_d.is_store=1; write_ack=0; check(); check();
    write_ack=1; check(); defaults(); check(); bus_read_ack=1; check();
    // Exercise every control combination WITH an owned response; unweighted
    // random issue blockers otherwise produce mostly empty/orphan states.
    for (integer i=0;i<4096;i++) begin
      defaults(); rst_n=0; check(); rst_n=1; check();
      {state,bus_read_ack,write_ack,fx_hold_e,fp_issue_block,fsm_case_enabled,
       xlate_miss,fe_xlate_pend,pipe_mem_abort_now,mc_chain_accept,mc_prime_accept}=12'(i);
      check(); defaults(); take_fault=1; check();
    end
    for (integer i=0;i<65536;i++) begin
      defaults();
      rng=rng^(rng<<13); rng=rng^(rng>>7); rng=rng^(rng<<17);
      {state,take_fault,fp_issue_block,exec_issue_ok,pipe_frontend_ready,
       fp_sys_bail,cs_extent_fault,pipe_agi,fp_pipe_rd_haz,fsm_case_enabled,
       bus_read_ack,write_ack,fx_hold_e,xlate_miss,fe_xlate_pend,pipe_mem_abort_now,
       bank_accept,mc_chain_accept,mc_prime_accept,mc_pair_q,pipe_pair}=rng[21:0];
      u_d=rng[32:25]; v_d=rng[40:33];
      stall_cnt=rng[63]?0:rng[47:41]; pending_mem_pen=rng[62]?0:rng[54:48];
      mispred_bubbles=rng[61]?0:rng[57:55]; mem_pair_rsp_valid=rng[60:59];
      check();
    end
    if (owned<4096 || read_waits<1000 || !stores || !orphans || accepts<4096)
      $fatal(1,"PAIR-RESPONSE missing class");
    $display("PAIR-RESPONSE-LEAF-OK checks=%0d owned=%0d waits=%0d stores=%0d orphans=%0d accepts=%0d",
             checks,owned,read_waits,stores,orphans,accepts);
    $finish;
  end
endmodule
'''
    return prefix+body+suffix


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--core', required=True, type=Path)
    ap.add_argument('--out', required=True, type=Path)
    args = ap.parse_args()
    source = args.core.resolve(strict=True); root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert sha(source) == CORE
    core = source.read_text()
    pins = {str(p): sha(p) for p in (source, Path(__file__).resolve(),
                                   Path(__file__).with_name('prove_pair_response_read_commit.py').resolve())}
    root.mkdir(); started = time.monotonic()
    result = dict(passed=False, pins=pins, rows=[], whole_core=False,
                  rtl_modified=False, gameplay_ipc=None, fmax_mhz=None)
    try:
        for mutant in (None,'missing-read-ack','raw-fragment-ack','lost-orphan-drain','lost-fault-clear'):
            label = mutant or 'positive'; folder = root/label; folder.mkdir()
            source_tb = folder/'tb.sv'; binary = folder/'a.out'
            source_tb.write_text(fixture(core, mutant))
            with (folder/'build.log').open('x') as stream:
                compile_result = subprocess.run(['iverilog','-g2012','-DVEN_FP_PIPE',
                    '-DVEN_PIPE_MEM_CHAIN','-DVEN_PIPE_REG_LOAD_PRIME','-DVEN_RAW_V_READ_PRIME',
                    '-DVEN_P54_DUAL_LOAD_PAIR','-s','tb','-o',str(binary),str(source_tb)],
                    stdout=stream,stderr=subprocess.STDOUT,timeout=15)
            assert compile_result.returncode == 0, label
            with (folder/'run.log').open('x') as stream:
                run = subprocess.run(['vvp',binary],stdout=stream,stderr=subprocess.STDOUT,timeout=30)
            log = (folder/'run.log').read_text()
            result['rows'].append(dict(label=label, native_exit=run.returncode, log=log,
                artifacts={str(p): sha(p) for p in (source_tb,binary,folder/'build.log',folder/'run.log')}))
            assert (run.returncode != 0 and 'PAIR-RESPONSE' in log) if mutant else (
                run.returncode == 0 and 'PAIR-RESPONSE-LEAF-OK' in log), result['rows'][-1]
        result['passed'] = True
    finally:
        result.update(seconds=time.monotonic()-started,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
        result['passed'] &= result['pins_unchanged']
        (root/'closed.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps({k:v for k,v in result.items() if k != 'pins'},indent=2))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
