#!/usr/bin/env python3
"""Whole-FPU A/B for start-sampled SRT payload selection.

Run inside the shared ipc_parallel32 scope, after any active Vivado family.
The existing complete FPU/SRT tests retain all architectural/response checks.
Only mode/A/B, which the SRT samples on start, may differ in invalid cycles.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

import prepare_srt_payload_select as recipe

UNITS = (
    'rtl/core/ventium_decode_pkg.sv', 'rtl/fpu/fpu_x87_pkg.sv',
    'rtl/core/ventium_x87_pkg.sv', 'rtl/fpu/fpu_srt_div.sv',
    'rtl/fpu/ven_bcd.sv', 'rtl/fpu/ven_bcd_to_fp.sv', 'rtl/fpu/fpu_estdiv.sv',
    'fp_shared/ven_fp_state.sv', 'fp_shared/ven_fp_alu.sv',
    'fp_shared/ven_fp_misc.sv', 'fp_shared/ven_fp_widemul.sv',
    'fp_shared/ven_fp_estdiv.sv', 'fp_shared/ven_fp_trans.sv',
)
INCLUDES = ('fpu_fsincos_rom.svh', 'fpu_f2xm1_rom.svh',
            'fpu_fpatan_rom.svh', 'fpu_fyl2x_rom.svh')


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source-root', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    repo = Path(__file__).resolve().parents[2]
    source = args.source_root.resolve(strict=True)
    out = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'ipc_parallel32'
    assert subprocess.run([str(repo/'tools/build_scope.sh'), '--is-active']).returncode == 0
    assert shutil.disk_usage(scratch).free > 2*1024**3
    out.mkdir()
    top = source/'fp_shared/ven_fp_top.sv'
    tb = repo/'fp_shared/tb/tb_ven_fp_srt_top_ab.sv'
    paths = [*(source/p for p in UNITS), *(source/'rtl/fpu'/p for p in INCLUDES),
             top, tb, Path(__file__).resolve(), Path(recipe.__file__).resolve(),
             repo/'tools/build_scope.sh', repo/'tools/verilator_serial.sh']
    pins = {str(p): sha(p) for p in paths}
    old = top.read_text()
    declaration = 'module ven_fp_top\n'
    assert old.count(declaration) == 1 and 'module ven_fp_top_old' not in old
    renamed = old.replace(declaration, 'module ven_fp_top_old\n')
    assert renamed.replace('module ven_fp_top_old\n', declaration) == old
    (out/'ven_fp_top_old.sv').write_text(renamed)
    (out/'ven_fp_top.sv').write_text(recipe.transform(old))
    bench = tb.read_text()
    for side in ('old', 'new'):
        marker = f'           {side}_dut.srt_mode, {side}_dut.srt_a, {side}_dut.srt_b,\n'
        assert bench.count(marker) == 1
        bench = bench.replace(marker, '')
    anchor = '        $fatal(1, "%s: SRT ownership/control mismatch", label);'
    assert bench.count(anchor) == 1
    bench = bench.replace(anchor, anchor + '''
      if (new_dut.srt_start &&
          ({new_dut.srt_mode, new_dut.srt_a, new_dut.srt_b} !==
           {old_dut.srt_mode, old_dut.srt_a, old_dut.srt_b}))
        $fatal(1, "%s: start-sampled SRT payload mismatch", label);''')
    (out/'tb.sv').write_text(bench)
    # The input list/order is the existing gate's explicit dependency list.
    files = [*(str(source/p) for p in UNITS), str(out/'ven_fp_top_old.sv'),
             str(out/'ven_fp_top.sv'), str(out/'tb.sv')]
    variants = [('base', []), ('stream', ['VEN_FP_ARITH_STREAM', 'VEN_FP_PERF']),
                ('stream_fwd', ['VEN_FP_ARITH_STREAM', 'VEN_FP_ARITH_FWD', 'VEN_FP_PERF'])]
    for p in (out/'ven_fp_top_old.sv', out/'ven_fp_top.sv', out/'tb.sv'):
        pins[str(p)] = sha(p)
    save(out/'started.json', dict(pins=pins, invocation=os.environ.get('INVOCATION_ID'),
                                native_parent_top_sha256=sha(top), jobs=32))
    results, error = [], None
    started = time.monotonic()
    try:
        for name, flags in variants:
            leaf = out/name
            leaf.mkdir()
            command = [str(repo/'tools/verilator_serial.sh'), '--binary', '--timing', '--assert',
                '-j', '32', '--output-groups', '0', '--output-split', '20000',
                '--output-split-cfuncs', '20000', '-sv', '-Wall', '-Wno-fatal', '-Wno-UNUSED',
                *('-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')),
                '--top-module', 'tb_ven_fp_srt_top_ab', '+define+VEN_FPREM',
                '+define+'+recipe.FLAG, *('+define+'+d for d in flags),
                '-I'+str(source/'rtl/fpu'), '--Mdir', str(leaf/'obj'), *files]
            save(leaf/'command.json', command)
            env = dict(os.environ, CCACHE_DISABLE='1', TMPDIR=str(leaf))
            with (leaf/'build.log').open('x') as log:
                build = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=240)
            assert build.returncode == 0, (name, 'compile', build.returncode)
            binary = leaf/'obj/Vtb_ven_fp_srt_top_ab'
            with (leaf/'run.log').open('x') as log:
                run = subprocess.run([str(binary)], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=60)
            assert run.returncode == 0, (name, 'native', run.returncode)
            assert 'FP-SRT-TOP-AB-OK matrix=12 checks=396' in (leaf/'run.log').read_text().splitlines()
            results.append(dict(variant=name, native_build=0, native_run=0, binary_sha256=sha(binary),
                                rc_pc_cases=12, expected_checks=396))
    except Exception as exc:
        import traceback
        error = dict(error=repr(exc), traceback=traceback.format_exc())
    stable = all(sha(Path(p)) == h for p,h in pins.items())
    passed = error is None and len(results) == len(variants) and stable
    result = dict(passed=passed, results=results, error=error, pins_unchanged=stable,
                  seconds=time.monotonic()-started, full_core=False, gameplay_ipc=None,
                  timing_measured=False, standard_suite=False)
    save(out/'closed.json', result)
    print(json.dumps(result, indent=2), flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
