#!/usr/bin/env python3
"""Check actual seam/backend/final-fragment equations under read ACK equivalence.

The premise is independently checked by run_fp_read_ack_split_r2.py. This is
not a whole-core, cache-array, fault-delivery or FPGA acceptance test.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from prepare_fp_read_ack_split import PARENTS, transform


def sha(p):
    with p.open('rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()


def assignments(source, name):
    source = re.sub(r'/\*.*?\*/|//[^\n]*', '', source, flags=re.S)
    return re.findall(r'\bassign\s+'+re.escape(name)+r'\s*=\s*([^;]+);', source)


def rename(expression, names):
    return re.sub(r'\b\w+\b', lambda m: names.get(m[0], m[0]), expression)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for arg in ('parent', 'leaf', 'out'): ap.add_argument('--'+arg, type=Path, required=True)
    args = ap.parse_args()
    parent, leaf = args.parent.resolve(strict=True), args.leaf.resolve(strict=True)
    out = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 4*1024**3
    closed = json.loads((leaf/'closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged'] and len(closed['runs']) == 13
    pins = json.loads((leaf/'pins.json').read_text())
    for p in (Path(__file__), leaf/'pins.json', leaf/'closed.json'):
        pins[str(p)] = sha(p)
    old = {n: (parent/n).read_text() for n in PARENTS}
    new = {n: (leaf/'candidate'/n).read_text() for n in PARENTS}
    assert all(new[n] == transform(n, old[n]) for n in PARENTS)
    assert all(sha(Path(p)) == h for p,h in pins.items())
    l1, top, core = ('rtl/mem/ventium_l1_axi.sv', 'rtl/ventium_top.sv', 'rtl/core/core.sv')
    # Check the actual port bindings used by the algebra, including read/write
    # identity. No implicit constant or disconnected cofactor is admitted.
    for source, wanted in ((new[l1], ('.c_we    (core_we)', '.c_read_ack(l1d_c_read_ack)')),
                           (new[top], ('.core_we   (core_mem_we)', '.core_read_ack(l1_c_read_ack)',
                                       '.bus_read_ack (core_mem_read_ack)'))):
        for text in wanted: assert text in source, text
    equations = []
    def emit(name, expr, mapping=None):
        equations.append('  assign '+name+' = '+rename(expr, mapping or {})+';')
    def one(source, name):
        found = assignments(source, name)
        assert len(found) == 1, (name, len(found))
        return found[0]
    emit('core_ack', one(old[l1], 'core_ack'))
    emit('seam_read_raw', one(new[l1], 'core_read_ack'))
    for name, source, symbol in (('top_ack', old[top], 'core_mem_ack'),
                                 ('top_read_raw', new[top], 'core_mem_read_ack')):
        found = assignments(source, symbol)
        assert len(found) == 2
        mapping = {'mem_ack': 'external_ack', 'l1_c_ack': 'core_ack', 'l1_c_read_ack': 'seam_read'}
        emit(name, found[0], mapping)
        emit('legacy_'+name, found[1], mapping)
    expr = one(old[core], 'mem_ack')
    read = assignments(new[core], 'mem_read_ack')
    assert len(read) == 2 and read[1].strip() == 'mem_ack'
    emit('final_ack', expr, {'bus_ack': 'top_ack'})
    emit('final_read_raw', read[0], {'bus_read_ack': 'top_read'})
    emit('legacy_final_ack', expr, {'bus_ack': 'legacy_top_ack'})
    emit('legacy_final_read', read[0], {'bus_read_ack': 'legacy_top_read_raw'})
    emit('fallback_final', read[1], {'mem_ack': 'final_ack'})
    body = '''module tb_fp_read_ack_seam;
  logic seam_core_rst_n, dma_drain_stall, core_smram_deny, core_route_deny;
  logic core_req, l1d_c_ack, l1axi_en, bus_mode, bus_c_ack, external_ack, fx_hold_e;
  wire l1d_c_read_ack = l1d_c_ack; // proven premise, read context only
  wire core_ack, seam_read_raw, top_ack, top_read_raw;
  wire legacy_top_ack, legacy_top_read_raw, final_ack, final_read_raw;
  wire legacy_final_ack, legacy_final_read, fallback_final;
  bit drop_reset, drop_dma, drop_fragment, wrong_backend;
  wire seam_read = (drop_reset && !seam_core_rst_n) ? l1d_c_read_ack :
                   (drop_dma && dma_drain_stall) ? l1d_c_read_ack : seam_read_raw;
  wire top_read = wrong_backend ? seam_read : top_read_raw;
  wire final_read = drop_fragment ? top_read : final_read_raw;
  // EQUATIONS
  initial begin
    drop_reset = $test$plusargs("drop_reset");
    drop_dma = $test$plusargs("drop_dma");
    drop_fragment = $test$plusargs("drop_fragment");
    wrong_backend = $test$plusargs("wrong_backend");
    for (integer i = 0; i < 2048; i++) begin
      {seam_core_rst_n, dma_drain_stall, core_smram_deny, core_route_deny,
       core_req, l1d_c_ack, l1axi_en, bus_mode, bus_c_ack, external_ack, fx_hold_e} = 11'(i);
      #1;
      if (core_ack !== seam_read || top_ack !== top_read ||
          legacy_top_ack !== legacy_top_read_raw || final_ack !== final_read ||
          legacy_final_ack !== legacy_final_read || fallback_final !== final_ack)
        $fatal(1, "FP_READ_ACK_SEAM_EQ sample=%0d", i);
    end
    $display("FP-READ-ACK-SEAM-OK samples=2048 comparisons=12288");
    $finish;
  end
endmodule
'''
    out.mkdir()
    with (out/'tb.sv').open('x') as f: f.write(body.replace('  // EQUATIONS', '\n'.join(equations)))
    runs = []
    def run(name, argv, expected, marker=None):
        with (out/(name+'.argv.json')).open('x') as f: json.dump(list(map(str,argv)), f)
        with (out/(name+'.log')).open('x') as f:
            proc = subprocess.run(argv, stdout=f, stderr=subprocess.STDOUT, timeout=30)
        runs.append(dict(name=name, native_exit=proc.returncode, log_sha256=sha(out/(name+'.log'))))
        assert proc.returncode == expected, runs[-1]
        if marker: assert marker in (out/(name+'.log')).read_text()
    run('build', ['/usr/bin/iverilog','-g2012','-s','tb_fp_read_ack_seam','-o',out/'test.vvp',out/'tb.sv'], 0)
    run('positive', ['/usr/bin/vvp',out/'test.vvp'], 0, 'samples=2048 comparisons=12288')
    for mutant in ('drop_reset','drop_dma','drop_fragment','wrong_backend'):
        run(mutant, ['/usr/bin/vvp',out/'test.vvp','+'+mutant], 1, 'FP_READ_ACK_SEAM_EQ')
    for p in (out/'tb.sv',out/'test.vvp'): pins[str(p)] = sha(p)
    assert all(sha(Path(p)) == h for p,h in pins.items())
    result = dict(passed=True, runs=runs, pins=pins, samples=2048, comparisons=12288,
                  premise='c_read_ack == c_ack for reads; independently checked leaf',
                  whole_core=False, sequential_cache=False, gameplay_ipc=None, timing_mhz=None)
    with (out/'closed.json').open('x') as f: json.dump(result, f, indent=2)
    print(json.dumps({k:v for k,v in result.items() if k != 'pins'}), flush=True)


if __name__ == '__main__': main()
