#!/usr/bin/env python3
"""Check parallel tags on the actual paired-store/load-store cache path.

Retain the existing pair fixture's stimulus and expectations. Use full P5
geometry and inject rejected lookahead during stores, with a different tag
and set. Run inside the shared build guard, after the basic cache miter.
"""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import time
from run_parallel_tag_cache import BASE_OUTPUTS, archive_products, sha


PAIR_OUTPUTS = dict(c_pair_ready=1, c_pair_ack=1, m_pair_req=1,
                    m_pair_addr=32, m_pair_wdata=32, m_pair_wstrb=4)
FLAGS = ['VEN_PIPE_MEM_CHAIN', 'VEN_PIPE_REG_LOAD_PRIME', 'VEN_RAW_V_READ_PRIME',
         'VEN_FP_LOAD64', 'VEN_L1D_BANKED_DATA', 'VEN_P54_DUAL_STORE_PAIR',
         'VEN_P54_LOAD_STORE_PAIR']


def fixture(original, flat):
    pattern = r'  ven_l1d #\(\.L1_SETS\(64\)\) dut \((.*?)\);'
    found = list(re.finditer(pattern, original, re.S))
    if len(found) != 1 or 'parallel_pair_checks' in original:
        raise ValueError('paired-store fixture drift')
    match = found[0]
    outputs = BASE_OUTPUTS | PAIR_OUTPUTS
    # Missing ports belong to enabled features absent in the original fixture.
    extra = '''
      .c_next_req(c_we), .c_next_commit(1'b1), .c_next_cacheable(1'b1),
      .c_next_addr(c_addr ^ 32'h12345020), .c_next_wstrb(4'hf),
      .c_next_ready(), .c_rdata_hi(), .c_rdata_hi_valid(),'''
    args = extra + match[1]
    shadow = args
    for name in outputs:
        port = r'\.' + name + r'(?:\([^()]*\))?(?=\s*(?:,|$))'
        shadow, count = re.subn(port, f'.{name}(shadow_{name})', shadow)
        if count != 1:
            raise ValueError('ambiguous output ' + name)
    block = '\n'.join(f'  logic [{w-1}:0] shadow_{n};' for n, w in outputs.items())
    block += '\n  ven_l1d #(.L1_SETS(128)) dut (' + args + ');\n'
    block += '  control_l1d #(.L1_SETS(128)) control (' + shadow + ');\n'
    block += '''  integer parallel_pair_checks=0, pair_accepts=0, rejected_store_hints=0;
  always @(posedge clk or negedge clk) begin
    #2;
'''
    for name in outputs:
        block += f'    if (dut.{name} !== shadow_{name}) $fatal(1,"PARALLEL-PAIR-MISMATCH output {name}");\n'
    for name in ('hit0', 'hit1', 'hit_way', 'mc_lookup_next', 'mc_capture_next',
                 'st', 'rd_armed', 'rd_addr_q', 'store_pair_hit',
                 'bank_store_we', 'bank_pair_store_we'):
        block += f'    if (dut.{name} !== control.{name}) $fatal(1,"PARALLEL-PAIR-MISMATCH state {name}");\n'
    block += '''`ifdef VEN_L1D_WINDOW_REUSE
    if (dut.window_valid_q !== control.window_valid_q) $fatal(1,"PARALLEL-PAIR-MISMATCH state window_valid_q");
`endif
'''
    block += '''    for (integer s=0;s<128;s++) begin
      if (dut.dc_lru[s] !== control.dc_lru[s]) $fatal(1,"PARALLEL-PAIR-MISMATCH lru");
      for (integer w=0;w<2;w++) begin
        if (dut.dc_val[s][w] !== control.dc_val[s][w]) $fatal(1,"PARALLEL-PAIR-MISMATCH valid");
'''
    index = 's*2+w' if flat else 's][w'
    block += f'        if (dut.dc_tag[{index}] !== control.dc_tag[{index}]) $fatal(1,"PARALLEL-PAIR-MISMATCH tag");\n'
    block += '''      end
    end
    parallel_pair_checks++;
    if (c_we) begin
      if (dut.mc_lookup_next || dut.c_next_ready || dut.mc_capture_next)
        $fatal(1,"STORE_ACCEPTED_READ_LOOKAHEAD");
      rejected_store_hints++;
    end
    if (c_pair_ack) pair_accepts++;
  end
  for (genvar bank=0;bank<8;bank++) begin : g_compare_all_data
    always @(posedge clk or negedge clk) begin
      #2;
      for (integer row=0;row<256;row++)
        if (dut.g_banked_read[bank].data[row] !== control.g_banked_read[bank].data[row])
          $fatal(1,"PARALLEL-PAIR-MISMATCH bank=%0d row=%0d",bank,row);
    end
  end
  final $display("PARALLEL-PAIR-MITER checks=%0d pairs=%0d rejected_store_hints=%0d",
                 parallel_pair_checks,pair_accepts,rejected_store_hints);
'''
    return original[:match.start()] + block + original[match.end():]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for key in ('cache', 'out'):
        ap.add_argument('--'+key, type=Path, required=True)
    args = ap.parse_args()
    repo = Path(__file__).resolve().parents[2]
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    cache, out = args.cache.resolve(strict=True), args.out.resolve()
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 5*1024**3
    assert subprocess.run([str(repo/'tools/build_scope.sh'), '--is-active'], pass_fds=(9,)).returncode == 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    prior = json.loads((cache/'closed.json').read_text())
    assert prior['passed'] and prior['pins_unchanged'] and len(prior['rows']) == 8
    pins = dict(prior['pins'])
    tb_source = Path(__file__).with_name('tb_l1d_pair_store.sv')
    for p in (Path(__file__), Path(__file__).with_name('run_parallel_tag_cache.py'),
              cache/'closed.json', tb_source):
        pins[str(p)] = sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    assert sha(cache/'ven_l1d.sv') == '61161ec0f9231f3c6c714f66552828381192cb29191f6984368447bca744143e'
    out.mkdir()

    def save(name, value):
        with (out/name).open('x') as f:
            json.dump(value, f, indent=2)

    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0))))
    start = time.monotonic()
    result = dict(passed=False, rows=[], error=None, gameplay_ipc=None, standard_suite=False)
    try:
        for mutant, flat, keep in [(False,f,k) for f in (False,True) for k in (False,True)] + [(True,f,False) for f in (False,True)]:
            assert shutil.disk_usage(out).free > 4*1024**3
            label = f'{"wrong" if mutant else "positive"}-lut{int(flat)}-keep{int(keep)}'
            folder = out/label
            folder.mkdir()
            top = 'tb_l1d_pair_store'
            tb = folder/(top+'.sv')
            with tb.open('x') as f:
                f.write(fixture(tb_source.read_text(), flat))
            pins[str(tb)] = sha(tb)
            flags = FLAGS + (['VEN_L1D_TAG_LUTRAM'] if flat else [])
            flags += ['VEN_L1D_WINDOW_REUSE', 'VEN_L1D_WINDOW_KEEP_STORE'] if keep else []
            command = [str(repo/'tools/verilator_serial.sh'), '--binary', '--assert', '-sv',
                '--top-module', top, '--Mdir', str(folder/'obj'), '-j', '32',
                '--output-split', '20000', '--output-split-cfuncs', '2000',
                '-Wall', '-Wno-UNUSED', '-Wno-fatal',
                *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                *['+define+'+v for v in flags], str(cache/'control_l1d.sv'),
                str(cache/('wrong_select.sv' if mutant else 'ven_l1d.sv')), str(tb)]
            save(label+'/command.json', command)
            row = dict(label=label, mutant=mutant, flat=flat, keep=keep, defines=flags)
            result['rows'].append(row)
            with (folder/'build.log').open('x') as f:
                native = subprocess.run(command, stdout=f, stderr=subprocess.STDOUT,
                    env={**os.environ, 'CCACHE_DISABLE':'1'}, pass_fds=(9,), timeout=180)
            row['build_exit'] = native.returncode
            assert native.returncode == 0, label
            binary = folder/'obj'/('V'+top)
            with (folder/'run.log').open('x') as f:
                native = subprocess.run([str(binary)], stdout=f, stderr=subprocess.STDOUT, timeout=30)
            row.update(native_exit=native.returncode, binary_sha256=sha(binary),
                       build_log_sha256=sha(folder/'build.log'), run_log_sha256=sha(folder/'run.log'))
            log = (folder/'run.log').read_text()
            if mutant:
                assert native.returncode != 0 and 'PARALLEL-PAIR-MISMATCH' in log, label
            else:
                assert native.returncode == 0 and 'L1D-PAIR-STORE-GATE-OK' in log, label
                assert not re.search(r'FAIL|%Error|%Fatal|MISMATCH', log), label
                counts = re.findall(r'^PARALLEL-PAIR-MITER checks=(\d+) pairs=(\d+) rejected_store_hints=(\d+)$', log, re.M)
                assert len(counts) == 1
                row.update(zip(('cycle_samples','pair_samples','rejected_store_hints'),map(int,counts[0])))
                assert row['cycle_samples'] > 100 and row['pair_samples'] > 10 and row['rejected_store_hints'] > 20, row
                assert '[load/store] registered U hit' in log and '[pair] snoop rejects' in log
            row['compiler_archive'] = archive_products(folder, top)
            save(label+'/closed.json', row)
            print(json.dumps({k:v for k,v in row.items() if k!='compiler_archive'}), flush=True)
        result['passed'] = True
    except BaseException as exc:
        import traceback
        result['error'] = dict(error=repr(exc), traceback=traceback.format_exc())
    result.update(pins=pins, pins_unchanged=all(sha(p)==h for p,h in pins.items()), seconds=time.monotonic()-start)
    result['passed'] &= result['pins_unchanged']
    save('closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
