#!/usr/bin/env python3
"""Actual-source SRT start/accepted-payload miter, with required mutants.

This is a selector microgate, not a full FPU/core or timing qualification.
It reuses the existing exhaustive RC/PC controls stimulus and actual ready
expressions. Only start-sampled mode/A/B may differ while start is zero.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

import prepare_srt_payload_select as recipe
import run_ven_fp_srt_controls as extract


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    repo = Path(__file__).resolve().parents[2]
    source = args.source.resolve(strict=True)
    out = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 1024**3
    out.mkdir()
    stimulus = repo/'fp_shared/tb/tb_ven_fp_srt_controls.sv'
    package = repo/'rtl/core/ventium_decode_pkg.sv'
    paths = [source, stimulus, package, Path(__file__).resolve(),
             Path(recipe.__file__).resolve(), Path(extract.__file__).resolve()]
    pins = {str(p): sha(p) for p in paths}
    old = source.read_text()
    transformed = recipe.transform(old)
    (out/'candidate.sv').write_text(transformed)
    # No changed payload/admission/priority survives with the feature disabled.
    begin = transformed.index('`ifdef '+recipe.FLAG+'\n')
    mid = transformed.index('\n`else\n', begin)
    end = transformed.index('\n`endif', mid)
    disabled = transformed[:begin] + transformed[mid+len('\n`else\n'):end] + transformed[end+len('\n`endif'):]
    assert disabled.split() == old.split()
    before = extract.check_source_layout(old, 'native parent', True)
    after = dict(before, start_block=recipe.active_block(old))
    old_compare = '''          (old_srt_start !== new_srt_start) || (old_srt_mode !== new_srt_mode) ||
          (old_srt_rc !== new_srt_rc) || (old_srt_pc !== new_srt_pc) ||
          (old_srt_a !== new_srt_a) || (old_srt_b !== new_srt_b)) begin'''
    new_compare = '''          (old_srt_start !== new_srt_start) ||
          (old_srt_rc !== new_srt_rc) || (old_srt_pc !== new_srt_pc) ||
          ((old_srt_start === 1'b1) && ((old_srt_mode !== new_srt_mode) ||
           (old_srt_a !== new_srt_a) || (old_srt_b !== new_srt_b)))) begin'''
    bench = stimulus.read_text()
    assert bench.count(old_compare) == 1
    bench = bench.replace(old_compare, new_compare)
    (out/'tb.sv').write_text(bench)
    variants = [('base', [], None), ('stream', ['-DVEN_FP_ARITH_STREAM'], None),
                ('wrong-sqrt-mode', [], ("srt_mode = 2'd1;", "srt_mode = 2'd0;")),
                ('wrong-trans-operand', [], ('srt_a = trans_divide_a;', 'srt_a = trans_divide_b;')),
                ('dropped-start', [], ("srt_start = 1'b1;", "srt_start = 1'b0;"))]
    save(out/'started.json', dict(pins=pins, invocation=os.environ.get('INVOCATION_ID'),
         native_source_sha256=sha(source), default_off_identical=True,
         compared='ready, accept, start, live RC/PC always; mode/A/B on every start'))
    results = []
    started = time.monotonic()
    error = None
    try:
        for name, defines, mutant in variants:
            leaf = out/name
            leaf.mkdir()
            pieces = dict(after)
            if mutant:
                assert mutant[0] in pieces['start_block']
                pieces['start_block'] = pieces['start_block'].replace(*mutant)
            generated = ('`default_nettype none\n' + extract.wrapper('srt_controls_old_actual', before, True, sha(source)) +
                         '\n' + extract.wrapper('srt_controls_new_actual', pieces, True, sha(out/'candidate.sv')))
            (leaf/'srt_controls_actual_extract.sv').write_text(generated)
            executable = leaf/'test.vvp'
            commands = [['/usr/bin/iverilog', '-g2012', *defines, '-s', 'tb_ven_fp_srt_controls',
                         '-I', str(leaf), '-o', str(executable), str(package), str(out/'tb.sv')],
                        ['/usr/bin/vvp', str(executable)]]
            exits = []
            for phase, command in zip(('compile', 'run'), commands):
                with (leaf/(phase+'.log')).open('x') as log:
                    child = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=120)
                exits.append(child.returncode)
                assert child.returncode == (1 if phase == 'run' and mutant else 0), (name, phase, exits)
            text = (leaf/'run.log').read_text()
            if mutant:
                assert 'source-extracted old/new selector mismatch' in text
                assert 'VEN-FP-SRT-CONTROLS-OK' not in text
            else:
                marker = re.findall(r'VEN-FP-SRT-CONTROLS-OK config=(base|stream) comparisons=(\d+)', text)
                assert len(marker) == 1 and marker[0][0] == name and int(marker[0][1]) > 300000
            results.append(dict(variant=name, native_exits=exits, required_negative=bool(mutant),
                                comparisons=int(marker[0][1]) if not mutant else None))
    except Exception as exc:
        import traceback
        error = dict(error=repr(exc), traceback=traceback.format_exc())
    stable = all(sha(Path(p)) == h for p,h in pins.items())
    passed = error is None and len(results) == len(variants) and stable
    result = dict(passed=passed, results=results, error=error, pins_unchanged=stable,
                  seconds=time.monotonic()-started, full_fpu=False, full_core=False,
                  gameplay_ipc=None, timing_measured=False)
    save(out/'closed.json', result)
    print(json.dumps(result, indent=2), flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
