#!/usr/bin/env python3
"""Characterize the actual resident-fetch guard in raw/uop configurations.

This is a small source-extracted Icarus test, not full-core/guest acceptance.
Without --require-raw it records the current disabled raw guard as a known
performance defect. With that switch the same observed disable is a failure.
No production source, memory image, architectural trace or live run is changed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[2]


def source_fragment(core):
    start = '`ifdef VEN_UOPCACHE\n`ifdef VEN_IC_BRAM\n`ifdef VEN_UOP_SFETCH\n'
    end = '\n`ifdef VEN_P54_PREFIX_EX_CHAIN\n'
    assert core.count(start) == 1
    begin = core.index(start)
    guard = core[begin:core.index(end, begin)]
    function = re.search(r'  function automatic logic ic_buffered\(.*?\n  endfunction',
                         core, re.S)
    assert function and 'assign sfetch_resident_fast' in guard
    return function[0] + '\n' + guard


HARNESS = r'''`timescale 1ns/1ps
module tb;
  localparam int S_FETCH=1, S_DECODE=2, IWORDS=4, IC_IDXW=7, IC_WAYW=1;
  localparam bit EXPECT_ENABLED = EXPECT_VALUE;
  logic sfetch_resident_fast, sfetch_short_fast, sfetch_uop_fast;
  logic sfetch_resident_q, sfetch_uop_q=0, sfetch_boundary, exec_issue_ok;
  logic [2:0] fetch_word;
  logic [3:0] sfetch_short_len_q=0;
  logic [31:0] flin;
  logic [6:0] rdA_set_q, rdB_set_q;
  logic rdA_way_q, rdB_way_q, ic_rd_collA, ic_rd_collB;
  logic present_a, present_b;
  int state, checks=0;
  function automatic logic ic_present(input logic [31:0] addr);
    return addr[31:5] == flin[31:5] ? present_a : present_b;
  endfunction
  function automatic logic ic_hit_way(input logic [31:0] addr);
    return addr[5];
  endfunction
ACTUAL_SOURCE
  task automatic good(input int offset, input bit swap_ports);
    logic [31:0] last_addr;
    // Use a distinct page for each independent vector. Icarus does not
    // resensitize a continuous function call to globals read in a nested
    // mock function; changing the argument ensures each vector is evaluated.
    flin=32'h00123500+32'(offset)+32'(checks)*32'h1000;
    last_addr=flin+15;
    sfetch_resident_q=1; sfetch_boundary=0; exec_issue_ok=1;
    state=S_FETCH; fetch_word=0; present_a=1; present_b=1;
    ic_rd_collA=0; ic_rd_collB=0;
    rdA_set_q=swap_ports ? last_addr[11:5] : flin[11:5];
    rdB_set_q=swap_ports ? flin[11:5] : last_addr[11:5];
    rdA_way_q=swap_ports ? last_addr[5] : flin[5];
    rdB_way_q=swap_ports ? flin[5] : last_addr[5];
  endtask
  task automatic check(input bit safe, input int vector_id);
    #1;
    if (sfetch_resident_fast !== (EXPECT_ENABLED && safe))
      $fatal(1,"resident guard vector=%0d offset=%0d got=%b expected=%b",
             vector_id,flin[4:0],sfetch_resident_fast,EXPECT_ENABLED&&safe);
    checks++;
  endtask
  initial begin
    for(int offset=0;offset<32;offset++) begin
      for(int swapped=0;swapped<2;swapped++) begin
        for(int hazard=0;hazard<11;hazard++) begin
          good(offset,1'(swapped));
          case(hazard)
            1: sfetch_resident_q=0;
            2: state=2;
            3: fetch_word=1;
            4: sfetch_boundary=1;
            5: exec_issue_ok=0;
            6: begin present_a=0; present_b=0; end
            7: begin rdA_set_q^=7'h40; rdB_set_q^=7'h40; end
            8: begin rdA_way_q=~rdA_way_q; rdB_way_q=~rdB_way_q; end
            9: begin ic_rd_collA=1; ic_rd_collB=1; end
            10: present_b=0;
            default: ;
          endcase
          check((hazard==0)||((hazard==10)&&(offset<=16)),hazard);
        end
      end
    end
    $display("RESIDENT-GUARD checks=%0d enabled=%0d",checks,EXPECT_ENABLED);
    $finish;
  end
endmodule
'''


CAPTURE_HARNESS = HARNESS.split('  task automatic good')[0] + r'''
  logic clk=0, sfetch_fast=0;
  logic icsnp_v1,icsnp_v2,ic_snoop_valid;
  logic sfetch_early_nm=0,sfetch_early_gp=0,sfetch_demand_req=0;
  logic d_fetch_meta_ready=0,mem_req=0,mem_ack=0;
  logic [4:0] sfetch_valid_q=0,sfetch_demand_size=0;
  logic [31:0] mem_rdata=0;
  logic [7:0] ibuf[16],ic_front_bytes[16];
  always @(posedge clk) case(state)
ACTUAL_CAPTURE
    default: ;
  endcase
  initial begin
    for(int hazard=0;hazard<4;hazard++) begin
      flin=32'h00400000+32'(hazard)*32'h1000;
      rdA_set_q=flin[11:5]; rdB_set_q=flin[11:5];
      rdA_way_q=flin[5]; rdB_way_q=flin[5];
      present_a=1; present_b=1; ic_rd_collA=0; ic_rd_collB=0;
      state=S_FETCH; fetch_word=0; sfetch_resident_q=1;
      sfetch_boundary=0; exec_issue_ok=1;
      icsnp_v1=(hazard==1); icsnp_v2=(hazard==2); ic_snoop_valid=(hazard==3);
      for(int i=0;i<16;i++) begin ibuf[i]=8'h55; ic_front_bytes[i]=8'ha0+8'(i); end
      #1;
      if(sfetch_resident_fast !== 1'b1) $fatal(1,"capture path was not enabled");
      clk=1; #1; clk=0;
      if(sfetch_resident_q !== 1'b0) $fatal(1,"token survived consumption");
      if(state != ((hazard==0)?S_DECODE:S_FETCH)) $fatal(1,"bad snoop state hazard=%0d",hazard);
      for(int i=0;i<16;i++)
        if(ibuf[i] !== ((hazard==0)?(8'ha0+8'(i)):8'h55))
          $fatal(1,"stale capture hazard=%0d byte=%0d",hazard,i);
      checks++;
      if(hazard!=0) begin
        icsnp_v1=0; icsnp_v2=0; ic_snoop_valid=0;
        #1; clk=1; #1; clk=0;
        if(state!=S_FETCH || sfetch_resident_fast!==1'b0)
          $fatal(1,"consumed token reused after snoop");
        for(int i=0;i<16;i++) if(ibuf[i]!==8'h55) $fatal(1,"replayed stale capture");
        checks++;
      end
    end
    $display("RESIDENT-CAPTURE checks=%0d",checks);
    $finish;
  end
endmodule
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True,
                        help='new output subdirectory on external scratch filesystem')
    parser.add_argument('--core', type=Path, default=ROOT/'rtl/core/core.sv')
    parser.add_argument('--fetch', type=Path,
                        help='also test actual S_FETCH capture and same-edge snoop veto')
    parser.add_argument('--require-raw', action='store_true')
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert args.out.resolve().is_relative_to(scratch)
    assert shutil.disk_usage(scratch).free > 2*1024**3
    args.out.mkdir()
    core = args.core.read_text()
    fragment = source_fragment(core)
    capture_text = args.fetch.read_text() if args.fetch else None
    capture = None
    if capture_text:
        capture = re.search(r'        S_FETCH: begin.*?(?=\n\n        S_DECODE:)',
                            capture_text, re.S)
        assert capture
    cases = [
        ('raw', ['VEN_IC_BRAM', 'VEN_FE_PIPE', 'VEN_SFETCH_RESIDENT'], args.require_raw),
        ('uop', ['VEN_IC_BRAM', 'VEN_UOPCACHE', 'VEN_UOP_SFETCH', 'VEN_SFETCH_RESIDENT'], True),
        ('off', ['VEN_IC_BRAM', 'VEN_FE_PIPE'], False),
        ('no_bram', ['VEN_FE_PIPE', 'VEN_SFETCH_RESIDENT'], False),
    ]
    receipt = dict(core=str(args.core.resolve()),
                   core_sha256=hashlib.sha256(core.encode()).hexdigest(),
                   fragment_sha256=hashlib.sha256(fragment.encode()).hexdigest(),
                   script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                   known_raw_disable=not args.require_raw,
                   full_core_acceptance=False, results=[])
    runs = [(name,defines,enabled,HARNESS) for name,defines,enabled in cases]
    if capture:
        receipt['fetch_sha256'] = hashlib.sha256(capture_text.encode()).hexdigest()
        for name,defines,_ in cases[:2]:
            runs.append((name+'-capture',defines+['VEN_L1_AXI'],True,
                         CAPTURE_HARNESS.replace('ACTUAL_CAPTURE',capture[0])))
    for name, defines, enabled, harness in runs:
        source = args.out/f'{name}.sv'
        executable = args.out/f'{name}.vvp'
        source.write_text(harness.replace('EXPECT_VALUE', str(int(enabled))).replace(
            'ACTUAL_SOURCE', fragment))
        command = ['iverilog', '-g2012', '-s', 'tb', '-o', str(executable),
                   *['-D'+d for d in defines], str(source)]
        with (args.out/f'{name}.build.log').open('x') as log:
            built = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=30)
        status = None
        if built.returncode == 0:
            with (args.out/f'{name}.run.log').open('x') as log:
                run = subprocess.run(['vvp', str(executable)], stdout=log,
                                     stderr=subprocess.STDOUT, timeout=30)
            status = run.returncode
        receipt['results'].append(dict(name=name,defines=defines,expected_enabled=enabled,
                                       build_exit=built.returncode,native_exit=status))
    receipt['all_expected_observations'] = all(r['build_exit']==0 and r['native_exit']==0
                                               for r in receipt['results'])
    receipt['inputs_unchanged'] = (args.core.read_text() == core and
                                  (not args.fetch or args.fetch.read_text()==capture_text))
    (args.out/'result.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt,indent=2))
    return 0 if receipt['all_expected_observations'] and receipt['inputs_unchanged'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
