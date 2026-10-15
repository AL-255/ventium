"""Masked multi-step regression on both SRT operand-port configurations.

Use the existing exact-integer oracle and complete sequence test unchanged,
except for explicitly tying the new candidate's UM input high. Compare every
result, quotient, exception bit and cycle count with the retained parent.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import traceback

import run_remainder_exact as exact
import prepare_remainder_underflow_core as recipe
from remainder_execution import execute

REPO = Path(__file__).resolve().parents[2]
sha, save = exact.sha, exact.save


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for n in ('core', 'out'): ap.add_argument('--'+n, type=Path, required=True)
    a = ap.parse_args(); core = a.core.resolve(strict=True); root = a.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    assert os.sched_getaffinity(0) == set(range(32)) and os.environ['INVOCATION_ID']
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], check=True, pass_fds=(9,))
    subprocess.run(['systemctl', '--user', 'set-property', '--runtime',
        'ventium-ipc-parallel32.scope', 'MemoryMax=10G', 'MemorySwapMax=2G'], check=True)
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    started, built = [json.loads((core/n).read_text()) for n in ('build-started.json', 'build-closed.json')]
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    parent = Path(started['parent'])
    assert sha(core/'obj/tb_ventium') == built['binary_sha256'] == \
        '77c0c895122a6d7c890924e4806af51d287cd64c5d2094aa9eaa8032079fab1d'
    pins = dict(started['pins'])
    assert all(sha(p) == h for p,h in pins.items())
    for name in recipe.PARENTS:
        assert recipe.transform((parent/'candidate'/name).read_text(), name) == (core/'candidate'/name).read_text()
    tb = Path(__file__).with_name('tb_remainder_exact.sv')
    text = tb.read_text()
    tied = recipe.leaf.once(text, '.mode(2\'d2),.prem1,.a,.b,',
        ".mode(2'd2),.prem1,.rem_underflow_mask(1'b1),.a,.b,")
    for p in (Path(__file__), Path(exact.__file__), Path(exact.oracle.__file__),
              Path(recipe.__file__), Path(recipe.leaf.__file__),
              REPO/'verif/srt/remainder_execution.py',
              REPO/'verif/qemu-trace/remainder_sequence/run_small_quotient.py',
              tb, core/'build-started.json', core/'build-closed.json'):
        pins[str(p.resolve())] = sha(p)
    root.mkdir(); rows = exact.cases(); save(root/'cases.json', rows)
    vectors = root/'vectors.txt'
    with vectors.open('x') as f:
        for r in rows:
            f.write(f"{r['id']} {r['kind']} {(r['cw']>>8)&3} {(r['cw']>>10)&3} "
                f"{r['a'][0]:04x}{r['a'][1]:016x} {r['b'][0]:04x}{r['b'][1]:016x}\n")
    pins[str(vectors)] = sha(vectors)
    save(root/'started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        cases=len(rows), masked_underflow=True, comparison_policy_unchanged=True))
    result = dict(passed=False, rows=[], errors=[], whole_core=False,
        canonical_gate_passed=False, standard_suite=False, gameplay_ipc=None)
    begin = time.monotonic()
    try:
        for split in (True, False):
            for label, source, fixture in (('parent', parent, text), ('candidate', core, tied)):
                name = label+('-split' if split else '-unsplit')
                dest = root/name; dest.mkdir()
                testbench = dest/'tb_remainder_exact.sv'; testbench.write_text(fixture)
                pkg = source/'candidate/rtl/fpu/fpu_x87_pkg.sv'
                dut = source/'candidate/rtl/fpu/fpu_srt_div.sv'
                command = [REPO/'tools/verilator_serial.sh', '-j', '32', '--binary', '--timing',
                    '--assert', '--threads', '1', '-Wall', '-Wno-UNUSED', '-Wno-fatal',
                    *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                    '+define+VEN_FPREM', *(['+define+VEN_SRT_REM_OPERAND_SPLIT'] if split else []),
                    '--Mdir', dest/'obj', '--top-module', 'tb_remainder_exact', pkg, dut, testbench]
                with (dest/'build.log').open('x') as f:
                    code = subprocess.run(command, stdout=f, stderr=subprocess.STDOUT,
                                          timeout=180, pass_fds=(9,)).returncode
                save(dest/'build.json', dict(command=list(map(str, command)), native_exit=code,
                    dut_sha256=sha(dut), testbench_sha256=sha(testbench)))
                assert code == 0
                binary = dest/'obj/Vtb_remainder_exact'; records = dest/'records.txt'
                os.sched_setaffinity(0, {12})
                try:
                    native = execute(name, [binary, '+input='+str(vectors), '+output='+str(records)], root)
                finally: os.sched_setaffinity(0, set(range(32)))
                graded = exact.grade(rows, records)
                save(dest/'graded.json', graded)
                assert graded['passed'] and not graded['errors']
                result['rows'].append(dict(name=name, **{k:v for k,v in graded.items() if k!='errors'},
                    binary_sha256=sha(binary), records_sha256=sha(records), native=native))
        assert len({r['records_sha256'] for r in result['rows']}) == 1
        result['passed'] = True
    except Exception as e:
        result['errors'].append(dict(error=repr(e), traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin, pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save(root/'closed.json', result)
    print(json.dumps(result, indent=2), flush=True)
    return int(not result['passed'])


if __name__ == '__main__': raise SystemExit(main())
