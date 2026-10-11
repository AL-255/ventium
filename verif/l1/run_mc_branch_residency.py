#!/usr/bin/env python3
"""Four-state full descriptor miter using extracted real I-cache functions.

Reuses the existing residency fixture's 18 cache/returned-port scenarios and
exhaustive start offsets/lengths. No Vivado or full-core build is launched.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

from prepare_mc_address_payload import raw_descriptor
from prepare_mc_branch_residency import NEW, transform

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
RESIDENCY = REPO / 'verif/uopcache/proposals/ic_residency_span'
sys.path.insert(0, str(RESIDENCY))
from extract_reference import extract_function, SIGNATURES


def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def save(path, value):
    with path.open('x') as f:
        json.dump(value, f, indent=2)


def generate(core):
    source = (core / 'core.sv').read_text()
    header = (core / 'core_mem_chain.svh').read_text()
    candidate = transform(header)
    helpers = (core / 'core_ic_residency_span.svh').read_text()
    pkg = (core / 'ventium_decode_pkg.sv').read_text()
    start = pkg.index('  typedef struct packed {')
    struct = pkg[start:pkg.index('  } fpd_t;', start) + len('  } fpd_t;')]
    assert "ALU_ADD = 5'd0" in (core / 'ventium_alu_pkg.sv').read_text()
    assert 'FK_MEM    = FK_NONE' in pkg and "FK_NONE   = 3'd0" in pkg
    begin, end = '// BEGIN IC FRONT SPAN', '// END IC FRONT SPAN'
    assert source.count(begin) == source.count(end) == 1
    span = source[source.index(begin):source.index(end) + len(end)]
    functions = '\n'.join(extract_function(source, s) for s in SIGNATURES)
    tb = (RESIDENCY / 'tb_ic_residency_span.sv').read_text()
    tb = tb.replace('  typedef struct packed { logic [3:0] len; } tiny_decode_t;\n  tiny_decode_t u_d, v_d;',
                    struct + '\n  fpd_t u_d, v_d;')
    # The previous caller test is not relevant here. Retain the exact existing
    # real-cache fixtures and helper checks, replacing only its caller task.
    start = tb.index('  // Intended production substitutions')
    end = tb.index('  task automatic check_bit', start)
    tb = tb[:start] + tb[end:]
    declarations = '''
  localparam int SG_CS=1, SG_SS=2, SG_DS=3;
  localparam logic [4:0] ALU_ADD=0;
  localparam logic [2:0] FK_MEM=0;
  wire [31:0] eip=flin-seg_base[SG_CS];
  logic [31:0] seg_base[6],seg_limit[6];
  wire [31:0] pipe_mem_eip_q=0;
  wire mc_prime_v_branch=1,mc_fp_self_prime=0,mc_held_read_prime=0;
  wire pipe_mem_active_q=0,mc_valid_q=0,pipe_pair_lookahead=1,v_bytes_ok=1;
  wire [$bits(fpd_t)-1:0] unused_packet='0;
  fpd_t pipe_u_eff,pipe_v_eff,pipe_mem_u_q,pipe_mem_v_q;
  assign pipe_u_eff=u_d; assign pipe_v_eff=v_d;
  assign pipe_mem_u_q=unused_packet; assign pipe_mem_v_q=unused_packet;
  integer accepted=0,rejected=0,wrong_pc=0;
'''
    original = raw_descriptor(header).replace('mc_descriptor(', 'mc_descriptor_old(', 1)
    revised = raw_descriptor(candidate).replace('mc_descriptor(', 'mc_descriptor_new(', 1)
    tb = tb.replace('  `include "ic_residency_reference.svh"', declarations + functions + '\n' + span)
    tb = tb.replace('  `include "ic_front_residency.svh"', helpers + '\n' +
                    (core / 'core_raw_branch_mov.svh').read_text() + '\n' + original + '\n' + revised)
    start = tb.index('  task automatic check_callers;')
    end = tb.index('  endtask', start) + len('  endtask')
    tb = tb[:start] + '''  task automatic check_callers;
    logic [31:0] pc;
    fpd_t old_d,new_d;
    begin
      #1;
      pc=eip+{28'd0,u_d.len}+{28'd0,v_d.len};
      old_d=mc_descriptor_old(pc); new_d=mc_descriptor_new(pc);
      checks++;
      if (!(new_d === old_d))
        $fatal(1,"MC-BRANCH-RESIDENCY-MISMATCH flin=%h U=%h V=%h old=%h new=%h",flin,u_d.len,v_d.len,old_d,new_d);
      if (old_d.len != 0) accepted++; else rejected++;
      // The public function accepts arbitrary PCs; sharing is valid only
      // behind its unchanged equality guard, not for another branch target.
      old_d=mc_descriptor_old(pc^32'h1000); new_d=mc_descriptor_new(pc^32'h1000);
      checks++; wrong_pc++;
      if (!(new_d === old_d) || !(old_d === '0))
        $fatal(1,"MC-BRANCH-RESIDENCY-WRONG-PC");
    end
  endtask''' + tb[end:]
    tb = tb.replace("ic_rd_lineA={32{8'ha5}}; ic_rd_lineB={32{8'h3c}};",
                    "ic_rd_lineA={8{32'h408b008b}}; ic_rd_lineB={8{32'hff508b90}};")
    # Do not leave other fpd_t bits uninitialized merely because the reused
    # fixture originally contained a length-only type.
    tb = tb.replace('fp_pipe_decode_win_last=6\'d5; u_d.len=0; v_d.len=0;',
                    "fp_pipe_decode_win_last=6'd5; u_d='0; v_d='0;")
    tb = tb.replace('    exhaustive_known_lengths();', '''    foreach(seg_base[i]) begin seg_base[i]=32'h13579000; seg_limit[i]=32'hffffffff; end
    exhaustive_known_lengths();''')
    start = tb.index('`ifdef VEN_IC_NO_FETCH_BYPASS\n    $display(')
    end = tb.index('    $finish;', start)
    tb = tb[:start] + '''    if (accepted < 1000 || rejected < 1000 || wrong_pc < 1000)
      $fatal(1,"MC-BRANCH-RESIDENCY-VACUOUS accepted=%0d rejected=%0d wrong_pc=%0d",accepted,rejected,wrong_pc);
    $display("MC-BRANCH-RESIDENCY-OK checks=%0d accepted=%0d rejected=%0d wrong_pc=%0d",checks,accepted,rejected,wrong_pc);
''' + tb[end:]
    assert 'ic_residency_reference.svh' not in tb and 'ic_front_residency.svh' not in tb
    assert tb.count('ic_res_buffered_offset({1\'b0,off})') == 1
    return candidate, tb


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--core', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    core, out = args.core.resolve(strict=True), args.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert shutil.disk_usage(scratch).free > 4*1024**3
    assert re.fullmatch('[0-9a-f]{32}', os.environ.get('INVOCATION_ID', ''))
    inputs = [core / n for n in ('core.sv', 'core_mem_chain.svh', 'core_raw_branch_mov.svh',
              'core_ic_residency_span.svh', 'ventium_decode_pkg.sv', 'ventium_alu_pkg.sv')]
    inputs += [Path(__file__).resolve(), HERE/'prepare_mc_branch_residency.py',
               HERE/'prepare_mc_address_payload.py', RESIDENCY/'extract_reference.py',
               RESIDENCY/'tb_ic_residency_span.sv', Path('/usr/bin/iverilog'), Path('/usr/bin/vvp')]
    pins = {str(p): sha(p) for p in inputs}
    candidate, tb = generate(core)
    out.mkdir()
    with (out/'core_mem_chain.svh').open('x') as f: f.write(candidate)
    variants = [(f'positive-{b}', tb, b, 0) for b in (0, 1)]
    variants += [
        ('lost-ownership', tb.replace('ic_res_buffered_offset({1\'b0,off})', 'ic_res_present_offset({1\'b0,off})')
             .replace("ic_res_buffered_end({1'b0,off}+{2'b0,branch_d.len})", "ic_res_present_end({1'b0,off}+{2'b0,branch_d.len})"), 0, 1),
        ('wrong-line', tb.replace("ic_res_buffered_offset({1'b0,off})", "ic_res_buffered_offset(6'd0)")
             .replace("ic_res_buffered_end({1'b0,off}+{2'b0,branch_d.len})", "ic_res_buffered_offset(6'd0)"), 0, 1),
    ]
    for name, text, _, _ in variants:
        with (out/(name+'.sv')).open('x') as f: f.write(text)
        pins[str(out/(name+'.sv'))] = sha(out/(name+'.sv'))
    pins[str(out/'core_mem_chain.svh')] = sha(out/'core_mem_chain.svh')
    save(out/'started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
         source=str(core), live_synthesis_modified=False, full_core=False))

    def one(item):
        name, _, bypass, expected = item
        command = ['/usr/bin/iverilog', '-g2012', '-gstrict-ca-eval', '-s', 'tb_ic_residency_span',
                   '-DVEN_IC_BRAM', '-DVEN_IC_RESIDENCY_SPAN', '-DVEN_RAW_BRANCH_FALLTHROUGH_PRIME',
                   '-DVEN_FAST_XCHG_R']
        if bypass: command += ['-DVEN_IC_NO_FETCH_BYPASS']
        command += ['-o', str(out/(name+'.vvp')), str(out/(name+'.sv'))]
        save(out/(name+'.command.json'), command)
        with (out/(name+'.compile.log')).open('x') as log:
            p = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=30)
        assert p.returncode == 0, name+' compile failed'
        start = time.monotonic()
        with (out/(name+'.log')).open('x') as log:
            p = subprocess.run(['/usr/bin/vvp', str(out/(name+'.vvp'))], stdout=log,
                               stderr=subprocess.STDOUT, timeout=150)
        text = (out/(name+'.log')).read_text()
        marker = 'MC-BRANCH-RESIDENCY-MISMATCH' if expected else 'MC-BRANCH-RESIDENCY-OK '
        return dict(name=name, native_exit=p.returncode, seconds=time.monotonic()-start,
                    passed=p.returncode == expected and marker in text,
                    log_sha256=sha(out/(name+'.log')), result=text[-1200:])

    error, rows = None, []
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            rows = list(pool.map(one, variants))
    except BaseException as exc:
        error = repr(exc)
    stable = all(sha(Path(p)) == h for p, h in pins.items())
    result = dict(passed=error is None and stable and len(rows)==len(variants) and all(r['passed'] for r in rows),
        error=error, rows=rows, pins_unchanged=stable, invocation=os.environ['INVOCATION_ID'],
        full_core=False, timing_mhz=None, gameplay_ipc=None,
        limitation='Settled four-state descriptor/cache-function equivalence; no whole-core or timing acceptance.')
    save(out/'closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
