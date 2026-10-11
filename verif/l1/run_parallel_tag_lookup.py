#!/usr/bin/env python3
"""Execute the actual old/new first-line lookup equations with writable arrays.

Leaf only: table writes are test stimulus, not the cache's allocation/coherence
FSM. All request and sequential cache behavior still require whole-module and
whole-core testing. Run under the shared build guard; do not launch Vivado.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from prepare_parallel_tag_lookup import lookup_block, transform


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


WRAPPER = '''#(parameter L1_SETS=`TEST_SETS, OFFW=5,
  IDXW=$clog2(L1_SETS), TAGW=32-OFFW-IDXW)
 (input logic clk, wr, input logic [IDXW-1:0] wr_set,
  input logic wr_way, wr_valid, input logic [TAGW-1:0] wr_tag,
  input logic [31:0] c_addr, c_next_addr, input logic sel,
  output wire [3:0] result);
  logic dc_val[L1_SETS][2];
`ifdef VEN_L1D_TAG_LUTRAM
  logic [TAGW-1:0] dc_tag[L1_SETS*2];
  always @(posedge clk) if(wr) dc_tag[{wr_set,wr_way}] <= wr_tag;
`else
  logic [TAGW-1:0] dc_tag[L1_SETS][2];
  always @(posedge clk) if(wr) dc_tag[wr_set][wr_way] <= wr_tag;
`endif
  always @(posedge clk) if(wr) dc_val[wr_set][wr_way] <= wr_valid;
  wire mc_lookup_next =
`ifdef VEN_PIPE_MEM_CHAIN
      sel;
`else
      1'b0;
`endif
  wire [31:0] lookup_addr=mc_lookup_next ? c_next_addr : c_addr;
  wire [IDXW-1:0] set_c;
  wire [TAGW-1:0] tag_c;
  wire hit0,hit1,hit,hit_way;
  assign result={hit_way,hit,hit1,hit0};
'''
TB = '''module tb;
  localparam L1_SETS=`TEST_SETS, IDXW=$clog2(L1_SETS), TAGW=27-IDXW;
  reg clk=0, wr=0, wr_way=0, wr_valid=0, sel=0;
  reg [IDXW-1:0] wr_set=0;
  reg [TAGW-1:0] wr_tag=0;
  reg [31:0] c_addr=0, c_next_addr=0;
  wire [3:0] old_result,new_result;
  old_lookup control(clk,wr,wr_set,wr_way,wr_valid,wr_tag,c_addr,c_next_addr,sel,old_result);
  new_lookup candidate(clk,wr,wr_set,wr_way,wr_valid,wr_tag,c_addr,c_next_addr,sel,new_result);
  integer samples=0, seen=0, differing_sources=0;
  reg [31:0] rng=32'h19a476f3, a,b;
  function automatic [31:0] next_rng(input [31:0] x);
    reg [31:0] y;
    begin y=x^(x<<13); y=y^(y>>17); next_rng=y^(y<<5); end
  endfunction
  task automatic put(input integer s, input bit w,v, input [TAGW-1:0] t);
    begin wr=1; wr_set=IDXW'(s); wr_way=w; wr_valid=v; wr_tag=t;
      #1; clk=1; #1; clk=0; wr=0; end
  endtask
  task automatic check;
    begin #1;
      if(old_result!==new_result)
        $fatal(1,"TAG_LOOKUP_MISMATCH sample=%0d sel=%0d c=%x n=%x old=%x new=%x",
               samples,sel,c_addr,c_next_addr,old_result,new_result);
      if ((^old_result)===1'bx) $fatal(1,"TAG_LOOKUP_UNKNOWN");
      seen=seen | (1<<old_result[1:0]); samples++;
    end
  endtask
  initial begin
    for(integer s=0;s<L1_SETS;s++) begin put(s,0,0,0); put(s,1,0,0); end
    for(integer k=0;k<8192;k++) begin
      rng=next_rng(rng); a=rng;
      rng=next_rng(rng); b=rng;
      // Alternate same/different sets, all-hit/one-hit/miss and invalid tags.
      // Same physical line and set wrap are included, with arbitrary offsets.
      if ((k&7)==0) b=a;
      if ((k&7)==1) b=a^(32'd1<<5);
      if ((k&7)==2) a=32'hffffffe0 | (32'(k)&31);
      put(integer'(a[5+:IDXW]),0,(k&1)!=0,a[5+IDXW+:TAGW]);
      put(integer'(a[5+:IDXW]),1,(k&2)!=0,a[5+IDXW+:TAGW]);
      if (a[5+:IDXW]!=b[5+:IDXW]) begin
        put(integer'(b[5+:IDXW]),0,(k&4)!=0,b[5+IDXW+:TAGW]);
        put(integer'(b[5+:IDXW]),1,(k&8)!=0,b[5+IDXW+:TAGW]);
      end
      c_addr=a; c_next_addr=b; sel=0; check();
      begin : compare_selects
        reg [3:0] prior;
        prior=old_result; sel=1; check();
        if(prior!=old_result) differing_sources++;
      end
    end
    if(samples!=16384 || seen!=15) $fatal(1,"TAG_LOOKUP_VACUOUS samples=%0d seen=%x",samples,seen);
`ifdef VEN_PIPE_MEM_CHAIN
    if(differing_sources==0) $fatal(1,"TAG_LOOKUP_SELECT_VACUOUS");
`else
    if(differing_sources!=0) $fatal(1,"TAG_LOOKUP_DISABLED_CHANGED");
`endif
    $display("PARALLEL-TAG-LOOKUP-OK samples=%0d seen=%x differing_sources=%0d",
             samples,seen,differing_sources);
    $finish;
  end
endmodule
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    source, out = args.source.resolve(strict=True), args.out.resolve()
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 4*1024**3
    assert subprocess.run([str(repo/'tools/build_scope.sh'), '--is-active'],
                          pass_fds=(9,)).returncode == 0
    old = source.read_text()
    new = transform(old)
    out.mkdir()
    pins = {str(p): sha(p) for p in (source, Path(__file__),
        Path(__file__).with_name('prepare_parallel_tag_lookup.py'),
        repo/'tools/build_scope.sh', Path('/usr/bin/iverilog').resolve(),
        Path('/usr/bin/vvp').resolve())}

    def save(name, value):
        with (out/name).open('x') as stream:
            json.dump(value, stream, indent=2)

    variants = {'positive': new,
        'reversed-select': new.replace(
            'mc_lookup_next ? tag_prime_hit[0] : tag_current_hit[0]',
            'mc_lookup_next ? tag_current_hit[0] : tag_prime_hit[0]'),
        'wrong-way': new.replace(
            'mc_lookup_next ? tag_prime_hit[1] : tag_current_hit[1]',
            'mc_lookup_next ? tag_prime_hit[0] : tag_current_hit[1]')}
    for label, candidate in variants.items():
        tb = out/(label+'.sv')
        with tb.open('x') as stream:
            for name, text in (('old_lookup', old), ('new_lookup', candidate)):
                stream.write('module '+name+WRAPPER+lookup_block(text)+'endmodule\n')
            stream.write(TB)
        pins[str(tb)] = sha(tb)
    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0)), whole_cache=False, gameplay_ipc=None))
    result = dict(passed=False, rows=[], error=None, whole_cache=False, gameplay_ipc=None,
                  standard_suite=False, hardware_acceptance=False, timing_mhz=None)
    began = time.monotonic()
    try:
        for label in variants:
            for sets in (2,64,128,256) if label=='positive' else (128,):
                for flat in (False,True):
                    for chain in (False,True) if label=='positive' else (True,):
                        name=f'{label}-s{sets}-lut{int(flat)}-chain{int(chain)}'
                        binary=out/(name+'.vvp')
                        command=['/usr/bin/iverilog','-g2012','-s','tb',f'-DTEST_SETS={sets}',
                            *(['-DVEN_L1D_TAG_LUTRAM'] if flat else []),
                            *(['-DVEN_PIPE_MEM_CHAIN'] if chain else []),
                            '-o',str(binary),str(out/(label+'.sv'))]
                        save(name+'.command.json',command)
                        row=dict(name=name)
                        result['rows'].append(row)
                        for phase, cmd in (('build',command), ('run',['/usr/bin/vvp',str(binary)])):
                            log=out/(name+'-'+phase+'.log')
                            with log.open('x') as stream:
                                p=subprocess.run(cmd,stdout=stream,stderr=subprocess.STDOUT,timeout=60)
                            row[phase+'_exit']=p.returncode
                            row[phase+'_log_sha256']=sha(log)
                            assert p.returncode == (1 if label!='positive' and phase=='run' else 0), row
                            if phase=='run':
                                expected='PARALLEL-TAG-LOOKUP-OK samples=16384 ' if label=='positive' else 'TAG_LOOKUP_MISMATCH'
                                assert expected in log.read_text(),row
                        pins[str(binary)]=sha(binary)
        result['passed']=True
    except BaseException as exc:
        import traceback
        result['error']=dict(error=repr(exc),traceback=traceback.format_exc())
    result.update(pins=pins,pins_unchanged=all(sha(p)==h for p,h in pins.items()),
                  seconds=time.monotonic()-began)
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
