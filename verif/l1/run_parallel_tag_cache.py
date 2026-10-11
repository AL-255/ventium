#!/usr/bin/env python3
"""Whole-L1 sequential A/B checks using unchanged request/reset/coherence fixtures.

Run inside the shared build guard. These are actual cache instances, not mocked
tag tables. This is not whole-core, full-PC, timing or hardware acceptance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import time
from prepare_parallel_tag_lookup import transform


BASE_OUTPUTS = dict(c_rdata=32, c_ack=1, dbg_serve=8, m_req=1, m_we=1,
    m_addr=32, m_wdata=32, m_wstrb=4, m_rd_narrow=1, m_rd_size=2,
    c_next_ready=1, c_rdata_hi=32, c_rdata_hi_valid=1)
STREAM_OUTPUTS = dict(c_req_ready=1, c_rsp_valid=1, c_rsp_addr=32, c_rsp_cancel=1)
COMMON = ['VEN_PIPE_MEM_CHAIN', 'VEN_FP_LOAD64', 'VEN_L1D_BANKED_DATA',
          'VEN_L1D_WINDOW_REUSE', 'VEN_L1D_TAG_INVALIDATE']
CHAIN = ['VEN_L1D_WINDOW_KEEP_STORE', 'VEN_L1D_HIT_UNDER_FILL',
         'VEN_L1D_FILL_FORWARD', 'VEN_PIPE_REG_LOAD_PRIME', 'VEN_RAW_V_READ_PRIME',
         'VEN_L1D_PERF', 'VEN_L1_HONOR_CD']


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def miter_fixture(original, stream, flat):
    """Insert only a shadow instance and checks; retain all original stimuli."""
    matches = list(re.finditer(r'^[ \t]*ven_l1d\s+dut\s*\((.*?)\);', original, re.S | re.M))
    if len(matches) != 1 or 'parallel_cache_checks' in original:
        raise ValueError('fixture instance drift')
    match = matches[0]
    outputs = BASE_OUTPUTS | (STREAM_OUTPUTS if stream else {})
    # The reset fixture deliberately leaves this output open. Explicit shadow
    # wiring must replace that open connection, not create a duplicate port.
    args = match[1].replace('.c_next_ready(), ', '')
    if any(re.search(r'\.' + name + r'\s*\(', args) for name in outputs):
        raise ValueError('unexpected explicit output connection')
    decl = '\n'.join(f'  logic [{width-1}:0] shadow_{name};' for name, width in outputs.items())
    wiring = ', '.join(f'.{name}(shadow_{name})' for name in outputs)
    block = decl + '\n  control_l1d control(' + wiring + ', ' + args + ');\n'
    block += '''  integer parallel_cache_checks=0, parallel_cache_next_checks=0;
  always @(posedge clk or negedge clk) begin
    // Sample after stimulus, combinational settling and nonblocking updates.
    #1;
'''
    for name in outputs:
        # Unconnected DUT next_ready in the reset fixture is still observed.
        block += f'    if (dut.{name} !== shadow_{name}) $fatal(1,"PARALLEL-CACHE-MISMATCH output {name}");\n'
    for name in ('hit0', 'hit1', 'hit_way', 'mc_lookup_next', 'mc_capture_next',
                 'st', 'fw', 'fset', 'fway', 'ftag', 'fbase', 'bypass_q',
                 'rd_armed', 'rd_window_q', 'rd_addr_q', 'rd_full_line_q',
                 'window_valid_q'):
        block += f'    if (dut.{name} !== control.{name}) $fatal(1,"PARALLEL-CACHE-MISMATCH state {name}");\n'
    block += '''    for (integer s=0;s<128;s++) begin
      if (dut.dc_lru[s] !== control.dc_lru[s]) $fatal(1,"PARALLEL-CACHE-MISMATCH lru");
      for (integer w=0;w<2;w++) begin
        if (dut.dc_val[s][w] !== control.dc_val[s][w]) $fatal(1,"PARALLEL-CACHE-MISMATCH valid");
'''
    index = 's*2+w' if flat else 's][w'
    block += f'        if (dut.dc_tag[{index}] !== control.dc_tag[{index}]) $fatal(1,"PARALLEL-CACHE-MISMATCH tag");\n'
    block += '''      end
    end
    parallel_cache_checks++;
    if (dut.mc_lookup_next) parallel_cache_next_checks++;
  end
  for (genvar bank=0;bank<8;bank++) begin : g_compare_all_data
    always @(posedge clk or negedge clk) begin
      #1;
      for (integer row=0;row<256;row++)
        if (dut.g_banked_read[bank].data[row] !== control.g_banked_read[bank].data[row])
          $fatal(1,"PARALLEL-CACHE-MISMATCH data bank=%0d row=%0d",bank,row);
    end
  end
  final $display("PARALLEL-CACHE-MITER checks=%0d next=%0d",parallel_cache_checks,parallel_cache_next_checks);
'''
    return original[:match.end()] + '\n' + block + original[match.end():]


def archive_products(folder, top):
    """Retain binaries/headers/inputs; compress closed generated objects only."""
    obj = folder / 'obj'
    selected = [p for p in sorted(obj.iterdir()) if p.name.startswith('V' + top)
        and p.suffix in ('.cpp', '.o', '.a', '.gch')]
    assert selected and all(p.is_file() and not p.is_symlink() and p.stat().st_nlink == 1 for p in selected)
    rows = [dict(path=str(p.relative_to(folder)), sha256=sha(p), bytes=p.stat().st_size) for p in selected]
    archive = folder / 'compiler-products.tar.zst'
    names = folder / 'compiler-products.names0'
    with names.open('xb') as f:
        f.write(b'\0'.join(r['path'].encode() for r in rows) + b'\0')
    env = dict(os.environ, ZSTD_NBTHREADS='1')
    subprocess.run(['tar', '--zstd', '-cf', str(archive), '-C', str(folder), '--null', '-T', str(names)],
                   check=True, env=env, timeout=120)
    subprocess.run(['tar', '--zstd', '--compare', '-f', str(archive), '-C', str(folder)],
                   check=True, env=env, timeout=120)
    assert all(sha(folder / r['path']) == r['sha256'] for r in rows)
    for p in selected:
        p.unlink()
    return dict(path=str(archive), sha256=sha(archive), objects=rows,
                recovery=['tar', '--zstd', '-xf', str(archive), '-C', str(folder)])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'leaf', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    source, leaf, out = args.source.resolve(strict=True), args.leaf.resolve(strict=True), args.out.resolve()
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 5*1024**3
    assert subprocess.run([str(repo/'tools/build_scope.sh'), '--is-active'], pass_fds=(9,)).returncode == 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    audit_path = leaf / 'audit.json'
    assert sha(audit_path) == 'eb17979d81449de4bb7336f51b8026576e789a954af1468f271ca08cc5ccf313'
    audit = json.loads(audit_path.read_text())
    assert audit['passed'] and audit['samples'] == 262144 and not audit['whole_cache']
    pins = dict(audit['pins'])
    fixtures = {name: repo/'verif/l1'/('tb_l1d_'+name+'.sv') for name in ('mem_chain', 'window_keep_reset')}
    for p in (source, audit_path, Path(__file__), Path(__file__).with_name('prepare_parallel_tag_lookup.py'),
              repo/'tools/build_scope.sh', repo/'tools/verilator_serial.sh', *fixtures.values()):
        pins[str(p)] = sha(p)
    assert all(sha(p) == h for p, h in pins.items())
    old = source.read_text()
    changed = transform(old)
    assert hashlib.sha256(changed.encode()).hexdigest() == '61161ec0f9231f3c6c714f66552828381192cb29191f6984368447bca744143e'
    wrong = changed
    for bit in (0, 1):
        a = f'mc_lookup_next ? tag_prime_hit[{bit}] : tag_current_hit[{bit}]'
        assert wrong.count(a) == 1
        wrong = wrong.replace(a, f'mc_lookup_next ? tag_current_hit[{bit}] : tag_prime_hit[{bit}]')
    out.mkdir()
    for name, text in [('control_l1d.sv', old.replace('module ven_l1d #(', 'module control_l1d #(', 1)),
                       ('ven_l1d.sv', changed), ('wrong_select.sv', wrong)]:
        with (out/name).open('x') as f:
            f.write(text)
        pins[str(out/name)] = sha(out/name)

    def save(name, value):
        with (out/name).open('x') as f:
            json.dump(value, f, indent=2)

    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0)), source_sha256=sha(source),
        candidate_sha256=sha(out/'ven_l1d.sv'), whole_core=False, gameplay_ipc=None))
    result = dict(passed=False, rows=[], error=None, whole_cache=True, whole_core=False,
                  standard_suite=False, hardware_acceptance=False, gameplay_ipc=None, timing_mhz=None)
    start = time.monotonic()
    try:
        for mutant in (False, True):
            for flat in (False, True):
                for profile in ('chain',) if mutant else ('chain', 'reset_drop', 'reset_keep'):
                    assert shutil.disk_usage(out).free > 4*1024**3
                    label = f'{"wrong" if mutant else "positive"}-{profile}-lut{int(flat)}'
                    folder = out/label
                    folder.mkdir()
                    stream = profile != 'chain'
                    top = 'tb_l1d_' + ('window_keep_reset' if stream else 'mem_chain')
                    fixture = fixtures['window_keep_reset' if stream else 'mem_chain']
                    tb = folder/(top+'.sv')
                    with tb.open('x') as f:
                        f.write(miter_fixture(fixture.read_text(), stream, flat))
                    pins[str(tb)] = sha(tb)
                    flags = COMMON + (['VEN_L1D_TAG_LUTRAM'] if flat else [])
                    flags += (['VEN_L1D_HIT_STREAM'] + (['VEN_L1D_WINDOW_KEEP_STORE'] if profile == 'reset_keep' else [])) if stream else CHAIN
                    command = [str(repo/'tools/verilator_serial.sh'), '--binary', '--assert', '-sv',
                        '--top-module', top, '--Mdir', str(folder/'obj'), '-j', '32',
                        '--output-split', '20000', '--output-split-cfuncs', '2000',
                        '-Wall', '-Wno-UNUSED', '-Wno-fatal',
                        *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                        *['+define+'+v for v in flags], str(out/'control_l1d.sv'),
                        str(out/('wrong_select.sv' if mutant else 'ven_l1d.sv')), str(tb)]
                    save(label+'/command.json', command)
                    row = dict(label=label, mutant=mutant, flat=flat, profile=profile, defines=flags)
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
                        assert native.returncode != 0 and 'PARALLEL-CACHE-MISMATCH' in log, label
                    else:
                        assert native.returncode == 0 and not re.search(r'%Error|%Fatal|Assertion failed|MISMATCH', log), label
                        marker = 'L1D-WINDOW-KEEP-RESET-OK' if stream else 'L1D-MEM-CHAIN-OK accepted=150 '
                        assert marker in log, label
                        counts = re.findall(r'^PARALLEL-CACHE-MITER checks=(\d+) next=(\d+)$', log, re.M)
                        assert len(counts) == 1 and int(counts[0][0]) >= 100, label
                        row.update(cycle_samples=int(counts[0][0]), next_samples=int(counts[0][1]))
                        assert stream or row['next_samples'] > 0, label
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
