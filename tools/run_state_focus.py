#!/usr/bin/env python3
"""Guarded offline reconstruction plus phase tests; never launches a CPU model."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--trace', type=Path, required=True)
    p.add_argument('--layout', type=Path, required=True)
    p.add_argument('--schema', type=Path, help='recorded schema; defaults to wave7.schema.tsv beside layout')
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    subprocess.run([ROOT / 'tools/build_scope.sh', '--is-active'], check=True, close_fds=False)
    if os.path.lexists(a.out):
        raise FileExistsError(a.out)
    out = a.out.resolve()
    trace, layout = a.trace.resolve(strict=True), a.layout.resolve(strict=True)
    schema_path = (a.schema or layout.with_name('wave7.schema.tsv')).resolve(strict=True)
    sources = [ROOT / 'tools' / name for name in ('state_delta_analyze.cpp', 'state_delta_focus.h',
        'test_state_delta_focus.cpp', 'test_state_delta_control.py', 'test_vload_attribution.py',
        'run_state_focus.py', 'build_scope.sh', 'state_delta_read.py', 'fpd_layout.py')]
    frozen = {str(path): sha(path) for path in [*sources, trace, layout, schema_path]}
    out.mkdir()
    (out / 'inputs.json').write_text(json.dumps(frozen, indent=2)+'\n')
    receipt = dict(scope=__doc__, stages=[], error=None, complete=False)
    def run(name, argv):
        start = time.monotonic()
        with (out / (name+'.log')).open('x') as log:
            result = subprocess.run(list(map(str, argv)), cwd=ROOT, stdout=log,
                stderr=subprocess.STDOUT, close_fds=False, timeout=1800)
        receipt['stages'].append(dict(name=name, argv=list(map(str, argv)), exit=result.returncode,
                                      seconds=time.monotonic()-start))
        print(name, 'exit='+str(result.returncode), flush=True)
        if result.returncode:
            raise RuntimeError('stage failed: '+name)
    def rows(name):
        with (out / name).open() as stream:
            return list(csv.DictReader(stream, delimiter='\t'))
    try:
        run('build-unit', ['g++', '-std=c++17', '-O2', '-Wall', '-Wextra', '-Werror',
                           ROOT / 'tools/test_state_delta_focus.cpp', '-o', out / 'test-focus'])
        run('unit', [out / 'test-focus', out / 'unit'])
        hole = rows('unit.frontend_repair.tsv')
        if len(hole)!=1 or int(hole[0]['linear_pc'])!=0x1234 or int(hole[0]['woff'])!=2:
            raise RuntimeError('wrong pre-edge frontend sample')
        mem = rows('unit.slow_memory_width.tsv')
        if len(mem)!=1 or int(mem[0]['q_pc'])!=0x5678 or int(mem[0]['width'])!=4 or int(mem[0]['ack'])!=0:
            raise RuntimeError('wrong pre-edge memory sample')
        service = rows('unit.slow_memory_service.tsv')
        if len(service)!=1 or any(int(service[0][key])!=expected for key, expected in
            dict(wq_count=2, b_hs=1, bridge_state=4, read_capture=1).items()):
            raise RuntimeError('wrong pre-edge backing-service sample')
        if rows('unit-missing.focus_status.tsv')[0]['available']!='0':
            raise RuntimeError('missing schema falsely reported complete')
        vga = rows('unit.vga_service.tsv')
        if len(vga)!=1 or any(int(vga[0][key])!=value for key,value in
            dict(backend_state=9,vga_busy=1,vga_write=1,vga_be=15,vga_byte=2,
                 vga_word=0x123,vga_next_be=15,q_pc=0x5678).items()):
            raise RuntimeError('wrong pre-edge VGA service sample')
        run('build-analyzer', ['g++', '-std=c++17', '-O2', ROOT / 'tools/state_delta_analyze.cpp',
                               '-lz', '-o', out / 'analyze'])
        run('phase', [sys.executable, ROOT / 'tools/test_state_delta_control.py', out / 'analyze'])
        run('vload', [sys.executable, ROOT / 'tools/test_vload_attribution.py', schema_path,
                      '--analyzer', out / 'analyze'])
        run('vload-corrected-perf', [sys.executable, ROOT / 'tools/test_vload_attribution.py',
                                     schema_path, '--analyzer', out / 'analyze', '--corrected-perf'])
        run('vload-old-schema', [sys.executable, ROOT / 'tools/test_vload_attribution.py', schema_path,
                                 '--analyzer', out / 'analyze', '--omit-chain-accept'])
        run('reconstruct', [out / 'analyze', trace, out / 'wave7', layout])
        # The new per-PC string service must conserve the independent generic
        # slow-memory table's K_STR load/store clocks and acknowledgements.
        slow_string = {}
        for row in rows('wave7.slow_memory_service.tsv'):
            if int(row['q_kind']) != 13:
                continue
            key = (int(row['q_pc']), int(row['core_state']))
            counts = slow_string.setdefault(key, [0, 0])
            clocks = int(row['clocks'])
            counts[0] += clocks
            counts[1] += clocks * int(row['ack'])
        measured_string = {}
        for row in rows('wave7.string_service.tsv'):
            pc = int(row['q_pc'], 16)
            for state, prefix in ((3, 'load'), (6, 'store')):
                if int(row[prefix]) == 0:
                    continue
                counts = measured_string.setdefault((pc, state), [0, 0])
                counts[0] += int(row[prefix])
                counts[1] += int(row[prefix + '_ack'])
            if (int(row['fused_load_ack']) > int(row['load_ack']) or
                    int(row['streamed_store_ack']) > int(row['store_ack']) or
                    int(row['load_busy']) + int(row['load_hit_capture']) +
                    int(row['load_miss']) > int(row['load'])):
                raise RuntimeError('string service subset exceeds its parent')
        if measured_string != slow_string:
            raise RuntimeError('string service disagrees with generic slow-memory table')
        status = rows('wave7.focus_status.tsv')[0]
        if status['available']!='1':
            raise RuntimeError('recording lacks required focus fields')
        if status['backend_available']!='1':
            raise RuntimeError('recording lacks required VGA backend fields')
        before = (out / 'wave7.initial.bin').read_bytes()
        after = (out / 'wave7.final.bin').read_bytes()
        schema = rows('wave7.schema.tsv')
        end_field = next(f for f in schema if f['name'].endswith('__DOT__pp_umap_fastend') and
                         f['name'].startswith('system__'))
        off, size = int(end_field['offset']), int(end_field['size'])
        if size!=48:
            raise RuntimeError('unexpected end-reason counter shape')
        expected = [(int.from_bytes(after[n:n+8], 'little') - int.from_bytes(before[n:n+8], 'little'))
                    for n in range(off, off+size, 8)]
        observed = [0]*6
        for row in rows('wave7.frontend_repair.tsv'):
            observed[int(row['end_reason'])] += int(row['clocks'])
        if observed!=expected or sum(observed)!=int(status['verified_fast_context_holes']):
            raise RuntimeError('per-PC frontend counts do not conserve hardware end-reason counters')
        receipt.update(complete=True, frontend_end_reason_counts=observed,
                       focus_status=status, analyzer_sha256=sha(out / 'analyze'))
    except Exception as exc:
        receipt['error'] = repr(exc)
    finally:
        receipt['input_drift'] = [name for name, old in frozen.items() if sha(Path(name))!=old]
        receipt['complete'] &= not receipt['input_drift']
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print('STATE-FOCUS-'+('PASS' if receipt['complete'] else 'FAIL'), out, flush=True)
    raise SystemExit(0 if receipt['complete'] else 1)


if __name__ == '__main__':
    main()
