#!/usr/bin/env python3
"""Four actual queue configurations, 32 aggregate compile jobs in one scope.

Parent and flag-off must retain m32 behavior; enabled candidate must preserve
wide data, ordered responses, metadata and reset. Unchanged parent with the
wide test enabled must fail at actual wide admission (sensitivity control).
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import subprocess

REPO = Path(__file__).resolve().parents[2]
FILES = '''rtl/core/ventium_decode_pkg.sv rtl/fpu/fpu_x87_pkg.sv
rtl/core/ventium_x87_pkg.sv rtl/fpu/fpu_srt_div.sv rtl/fpu/ven_bcd.sv
rtl/fpu/ven_bcd_to_fp.sv rtl/fpu/fpu_estdiv.sv fp_shared/ven_fp_state.sv
fp_shared/ven_fp_alu.sv fp_shared/ven_fp_misc.sv fp_shared/ven_fp_widemul.sv
fp_shared/ven_fp_estdiv.sv fp_shared/ven_fp_trans.sv fp_shared/ven_fp_top.sv
fp_shared/ven_fp_fxch_queue.sv'''.split()


def sha(p):
    with p.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def save(p, v):
    with p.open('x') as f:
        json.dump(v, f, indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'candidate', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert args.out.resolve().is_relative_to(scratch)
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], check=True, close_fds=False)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    args.out.mkdir()
    tb = REPO/'fp_shared/tb/tb_ven_fp_mem_queue.sv'
    roots = dict(parent=args.parent.resolve(strict=True), candidate=args.candidate.resolve(strict=True))
    pins = {str(p): sha(p) for p in [Path(__file__), tb, REPO/'tools/build_scope.sh'] +
            [root/name for root in roots.values() for name in FILES]}
    save(args.out/'inputs.json', pins)

    def test(case):
        name, model, wide, negative = case
        root = roots[model]
        leaf = args.out/name
        leaf.mkdir()
        flags = ['+define+VEN_FP_MEM_QUEUE64'] if wide else []
        command = ['/tools/verilator/v5.046/bin/verilator', '--binary', '--timing', '--assert',
                   '-j', '8', '--output-groups', '0', '--output-split', '12000',
                   '--output-split-cfuncs', '12000', '-Wall', '-Wno-UNUSED', '-Wno-fatal',
                   *['-Werror-'+w for w in ('IMPLICIT', 'PINMISSING', 'UNDRIVEN', 'MULTIDRIVEN', 'LATCH', 'UNOPTFLAT')],
                   '--top-module', 'tb_ven_fp_mem_queue', '--Mdir', leaf/'obj', '-o', 'tb_queue',
                   '-I'+str(root/'rtl/fpu'), '+define+VEN_FPREM', '+define+VEN_FP_ARITH_STREAM',
                   '+define+VEN_FP_MEM_QUEUE', *flags, *[root/name for name in FILES], tb]
        save(leaf/'command.json', list(map(str, command)))
        with (leaf/'build.log').open('x') as log:
            rc = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                env=dict(os.environ, TMPDIR=str(leaf), CCACHE_DISABLE='1',
                                         VERILATOR_CXXCACHE=''), timeout=240).returncode
        assert rc == 0, (name, 'build', rc)
        binary = leaf/'obj/tb_queue'
        with (leaf/'run.log').open('x') as log:
            rc = subprocess.run([binary], stdout=log, stderr=subprocess.STDOUT, timeout=15).returncode
        text = (leaf/'run.log').read_text()
        if negative:
            assert rc != 0 and 'memory command did not queue before old divide response' in text, (name, rc, text)
            assert 'FP-MEM-QUEUE-LEAF-OK' not in text
        else:
            assert rc == 0, (name, rc, text)
            assert re.findall(r'FP-MEM-QUEUE-LEAF-OK checks=(\d+)', text) == [str(25 if wide else 12)]
        result = dict(name=name, exit=rc, expected_negative=negative, passed=True,
                      binary_sha256=sha(binary), checks=0 if negative else 25 if wide else 12)
        save(leaf/'closed.json', result)
        return result

    result = dict(passed=False, variants=[], errors=[], standard_suite=False, gameplay_ipc=None)
    try:
        cases = [('parent', 'parent', False, False), ('disabled', 'candidate', False, False),
                 ('enabled', 'candidate', True, False), ('negative-parent', 'parent', True, True)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            futures = [pool.submit(test, case) for case in cases]
            for future in concurrent.futures.as_completed(futures):
                try:
                    result['variants'].append(future.result())
                except Exception as exc:
                    result['errors'].append(repr(exc))
        result['passed'] = len(result['variants']) == 4 and not result['errors']
    finally:
        result['inputs_unchanged'] = all(sha(Path(p)) == h for p, h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        save(args.out/'closed.json', result)
    print(json.dumps(result), flush=True)
    assert result['passed']


if __name__ == '__main__':
    main()
