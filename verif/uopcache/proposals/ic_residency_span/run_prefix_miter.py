#!/usr/bin/env python3
"""Extract exact prefix gather/oracle; compare four-state settled byte outputs.

Reuses the existing independent cache-metadata fixture, not a copied proposed
datapath. Includes same-address metadata/data turnover (no address pulsing).
Artifacts are retained, and a wrong stale-line mutation must fail natively.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

from prepare_prefix_integration import FLAG, HEADER, transform

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]

CHECK = '''  integer comparisons = 0;
  integer fixed_address_checks = 0;
  task automatic check_front(input string label);
    logic [31:0] addr;
    logic [7:0] expected;
    begin
      #1;
      for (int i=0; i<IWORDS*4; i++) begin
        addr = flin + 32'(i);
        expected = ic_byte(addr);
        if (ic_prefix_bytes[i] !== expected)
          die(label, $sformatf("prefix byte %0d got=%02x want=%02x addr=%08x",
                              i, ic_prefix_bytes[i], expected, addr));
        comparisons = comparisons + 1;
      end
    end
  endtask'''

EXTRA = '''
  task automatic four_state_and_fixed_address;
    logic [31:0] saved_addr;
    begin
      configure_resident_pair(32'h12345019);
      saved_addr = flin;
      check_front("fixed-start");
      // Every update below leaves the address unchanged. There is no X pulse
      // or test-only recomputation of the DUT to hide sensitivity mistakes.
      for (int k=0; k<4; k++) begin
        ic_val_o[0][0] = k[0];
        ic_val_o[1][1] = k[1];
        check_front("fixed-valid"); fixed_address_checks++;
        ic_tag_o[0][0][0] = !ic_tag_o[0][0][0];
        check_front("fixed-tag"); fixed_address_checks++;
        ic_rd_lineA = ~ic_rd_lineA;
        check_front("fixed-data"); fixed_address_checks++;
        ic_rd_collA = k[0]; ic_rd_collB = k[1];
        check_front("fixed-collision"); fixed_address_checks++;
      end
      for (int z=0; z<2; z++) begin
        configure_resident_pair(saved_addr);
        ic_val_o[0][0] = z ? 1'bz : 1'bx;
        check_front("unknown-valid");
        ic_tag_o[1][1][0] = z ? 1'bz : 1'bx;
        check_front("unknown-tag");
        install_bypass(0,saved_addr,1'b1);
        check_front("fixed-bypass"); fixed_address_checks++;
        icbp_way[0] = z ? 1'bz : 1'bx;
        check_front("unknown-bypass-way");
        icbp_v[0] = z ? 1'bz : 1'bx;
        check_front("unknown-bypass-valid");
        configure_resident_pair(saved_addr);
        rdA_way_q = z ? 1'bz : 1'bx;
        check_front("unknown-returned-way");
        rdB_set_q[0] = z ? 1'bz : 1'bx;
        check_front("unknown-returned-set");
        configure_resident_pair(saved_addr);
        ic_rd_collA = z ? 1'bz : 1'bx;
        ic_rd_collB = z ? 1'bx : 1'bz;
        check_front("unknown-collisions");
        ic_rd_lineA[255:248] = 8'bx1z01xz0;
        ic_rd_lineB[7:0] = 8'b01zx1z01;
        check_front("unknown-data");
        for (int bitno=0; bitno<32; bitno++) begin
          flin = saved_addr;
          flin[bitno] = z ? 1'bz : 1'bx;
          check_front("unknown-base");
        end
      end
      for (int setno=0; setno<IC_SETS; setno++) begin
        for (int low=0; low<32; low++) begin
          configure_resident_pair(32'h24680000+32'(setno*32+low));
          check_front("all-sets-offsets");
          // Highest cache-way and last bypass-slot priority with different
          // returned contents; misses still have defined stale-A byte data.
          install_cache(flin,1'b1);
          set_b_buffer(flin,1'b1,32'h98765432,1'b0);
          check_front("duplicate-way");
          install_bypass(0,flin,1'b0);
          install_bypass(1,flin,1'b1);
          check_front("duplicate-bypass");
        end
      end
      if (fixed_address_checks != 18) die("coverage", "fixed-address count");
    end
  endtask
'''


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f,'sha256').hexdigest()


def function(source, signature):
    if source.count(signature) != 1:
        raise ValueError('oracle function drift: '+signature)
    start = source.index(signature)
    end = source.index('endfunction',start)+len('endfunction')
    return source[start:end]


def prepare(core, out):
    text = core.read_text()
    new = transform(text)
    header = (HERE/'ic_prefix_span.svh').read_text()
    fixture = (REPO/'verif/uopcache/tb_ic_front_span_miter.sv').read_text()
    assert fixture.count('  task automatic check_front(') == 1
    first = fixture.index('  task automatic check_front(')
    last = fixture.index('  endtask',first)+len('  endtask')
    fixture = fixture[:first]+CHECK+fixture[last:]
    anchor = '    directed_cases();'
    assert fixture.count(anchor) == 1
    fixture = fixture.replace(anchor, anchor+'\n    four_state_and_fixed_address();')
    anchor = '  initial begin\n`ifdef VEN_IC_BRAM'
    assert fixture.count(anchor) == 1
    fixture = fixture.replace(anchor,EXTRA+'\n'+anchor)
    fixture = fixture.replace('  localparam int IC_SETS = 128;',
        '  localparam int IWORDS = 4;\n  localparam int IC_SETS = 128;')
    fixture = fixture.replace('  logic [31:0] flin;',
        '  logic [31:0] flin;\n  wire [31:0] p54_prefix_ex_flin = flin;')
    anchor = '    $display("IC-FRONT-SPAN-MITER-OK bypass=%0d",'
    assert fixture.count(anchor) == 1
    fixture = fixture.replace(anchor,
        '    $display("IC-PREFIX-COVERAGE comparisons=%0d fixed_address=%0d", comparisons, fixed_address_checks);\n'
        '    $display("IC-PREFIX-SPAN-MITER-OK bypass=%0d",')
    oracle = '\n\n'.join(function(text,s) for s in (
        'function automatic logic ic_present(',
        'function automatic logic [IC_WAYW-1:0] ic_hit_way(',
        'function automatic logic [7:0] ic_byte(',
        'function automatic logic [IC_WAYW:0] ic_front_probe('))
    out.mkdir()
    for name, value in {'core.sv':new,HEADER:header,
        'ic_front_span_extracted.svh':oracle+'\n`include "'+HEADER+'"\n',
        'tb.sv':fixture}.items():
        (out/name).write_text(value)
    return [core,Path(__file__),HERE/'prepare_prefix_integration.py',HERE/'ic_prefix_span.svh',
            REPO/'verif/uopcache/tb_ic_front_span_miter.sv']


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--core',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True)
    args=p.parse_args()
    assert os.environ['TMPDIR']=='/home/yukidama/external/tmp' and __debug__
    args.core=args.core.resolve(strict=True); args.out=args.out.resolve()
    assert args.out.parent.stat().st_dev != REPO.stat().st_dev
    inputs=prepare(args.core,args.out)
    inputs += list(args.out.iterdir()) + [Path('/usr/bin/iverilog'),Path('/usr/bin/vvp')]
    pins={str(f):sha(f) for f in inputs}
    (args.out/'started.json').write_text(json.dumps(dict(pins=pins,flag=FLAG,
        controller_invocation=os.environ.get('INVOCATION_ID'),candidate_gameplay_ipc=None),indent=2))
    start=time.monotonic()
    def run_variant(bypass):
        d=args.out/('bypass' if bypass else 'no-bypass'); d.mkdir()
        cmd=['/usr/bin/taskset','-c',str(12 if bypass else 13),'/usr/bin/iverilog','-g2012',
             '-s','tb_ic_front_span_miter','-DVEN_IC_BRAM','-DVEN_P54_PREFIX_EX_CHAIN',
             '-I'+str(args.out),'-o',str(d/'miter.vvp'),str(args.out/'tb.sv')]
        if not bypass: cmd.insert(7,'-DVEN_IC_NO_FETCH_BYPASS')
        (d/'command.json').write_text(json.dumps(cmd))
        with (d/'compile.log').open('x') as f:
            built=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,timeout=60)
        assert built.returncode==0, str(d/'compile.log')
        native=['/usr/bin/taskset','-c',str(12 if bypass else 13),'/usr/bin/vvp',str(d/'miter.vvp')]
        with (d/'run.log').open('x') as f:
            child=subprocess.Popen(native,stdout=f,stderr=subprocess.STDOUT)
            affinity=sorted(os.sched_getaffinity(child.pid))
            # Verify the taskset exec has happened, rather than accepting the
            # parent's wider affinity between fork and exec.
            for _ in range(200):
                affinity=sorted(os.sched_getaffinity(child.pid))
                if affinity==[12 if bypass else 13]: break
                time.sleep(.005)
            assert affinity==[12 if bypass else 13]
            rc=child.wait(timeout=120)
        text=(d/'run.log').read_text()
        assert rc==0 and f'IC-PREFIX-SPAN-MITER-OK bypass={int(bypass)}' in text, str(d/'run.log')
        coverage=re.findall(r'IC-PREFIX-COVERAGE comparisons=(\d+) fixed_address=(\d+)',text)
        assert len(coverage)==1 and int(coverage[0][0])>200000 and coverage[0][1]=='18'
        assert not Path('/proc',str(child.pid)).exists()
        return dict(bypass=bypass,native_exit=rc,affinity=affinity,pid=child.pid,reaped=True,
                    comparisons=int(coverage[0][0]),fixed_address_checks=18)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results=list(pool.map(run_variant,[True,False]))
    stable=all(sha(p)==v for p,v in pins.items())
    assert stable
    (args.out/'closed.json').write_text(json.dumps(dict(passed=True,native=results,
        seconds=time.monotonic()-start,inputs_unchanged=stable,candidate_gameplay_ipc=None,
        four_state=True,no_address_refresh_workaround=True,standard_suite=False),indent=2))
    print(json.dumps(results))


if __name__=='__main__':
    main()
