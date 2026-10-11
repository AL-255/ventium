#!/usr/bin/env python3
"""Bounded native helper or actual-engine checks for SRT input normalization.

The engine mode requires the existing shared heavy-build lock. Helper mode
uses only Icarus/Z3 in a separately memory/CPU-bounded service, not Vivado.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import traceback
from prepare_input_norm_tree import HELPER, transform
from test_input_norm_tree import proof


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('helper', 'engine'))
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    source, out = args.source.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    repo = Path(__file__).resolve().parents[2]
    here = Path(__file__).resolve().parent
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert scratch != Path('/') and Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 4 * 1024**3
    assert os.environ.get('INVOCATION_ID'), 'use a bounded native service'
    old = source.read_text()
    new = transform(old)
    if args.mode == 'engine':
        subprocess.run([repo/'tools/build_scope.sh', '--is-active'],
                       pass_fds=(9,), check=True, timeout=10)
    out.mkdir()

    def save(name, value):
        with (out/name).open('x') as stream:
            json.dump(value, stream, indent=2)

    def write(name, value):
        with (out/name).open('x') as stream:
            stream.write(value)
        pins[str(out/name)] = sha(out/name)

    pins = {str(p): sha(p) for p in (source, Path(__file__),
        here/'prepare_input_norm_tree.py', here/'test_input_norm_tree.py',
        here/'tb_input_norm_helper.svh', here/'tb_input_norm_miter.sv',
        repo/'tools/build_scope.sh', repo/'tools/verilator_serial.sh',
        Path('/usr/bin/iverilog').resolve(), Path('/usr/bin/vvp').resolve(),
        Path('/usr/bin/z3').resolve())}
    rows = []

    def run(label, command, expected=0, seconds=120, marker=None, heavy=False):
        command = list(map(str, command))
        save(label+'.command.json', command)
        with (out/(label+'.log')).open('x') as stream:
            native = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT,
                timeout=seconds, pass_fds=(9,) if heavy else ())
        record = dict(label=label, native_exit=native.returncode,
                      log_sha256=sha(out/(label+'.log')))
        rows.append(record)
        assert native.returncode == expected, record
        if marker is not None:
            assert marker in (out/(label+'.log')).read_text(), record

    began = time.monotonic()
    result = dict(passed=False, errors=[], mode=args.mode, whole_core=False,
                  independent_numeric_oracle=False, gameplay_ipc=None, timing_mhz=None)
    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0)), mode=args.mode))
    try:
        if args.mode == 'helper':
            variants = (
                ('positive', HELPER, None, 0),
                ('wrong-zero', HELPER.replace("return 6'd0;", "return 6'd63;"), 'zero', 1),
                ('wrong-half', HELPER.replace('if (|x[63:32]) w32 = x[63:32];',
                    'if (|x[63:32]) w32 = x[31:0];'), 'half', 1),
            )
            for label, body, mutation, expected in variants:
                assert not expected or body != HELPER
                write(label+'.sv', 'module tb;\n'+body+
                      (here/'tb_input_norm_helper.svh').read_text()+'\nendmodule\n')
                write(label+'.smt2', proof(mutation))
                run(label+'-proof', ['/usr/bin/z3', '-smt2', out/(label+'.smt2')],
                    marker='sat' if expected else 'unsat')
                assert (out/(label+'-proof.log')).read_text().strip() == ('sat' if expected else 'unsat')
                run(label+'-build', ['/usr/bin/iverilog', '-g2012', '-s', 'tb',
                    '-o', out/(label+'.vvp'), out/(label+'.sv')], seconds=30)
                pins[str(out/(label+'.vvp'))] = sha(out/(label+'.vvp'))
                run(label, ['/usr/bin/vvp', out/(label+'.vvp')], expected,
                    marker='SRT_INPUT_HELPER_MISMATCH' if expected else
                    'SRT-INPUT-HELPER-OK count=378852 fourstate=16514')
        else:
            package = source.with_name('fpu_x87_pkg.sv')
            pins[str(package)] = sha(package)
            pins['/tools/verilator/v5.046/bin/verilator_bin'] = sha('/tools/verilator/v5.046/bin/verilator_bin')
            assert old.count('module fpu_srt_div\n') == 1
            write('control.sv', old.replace('module fpu_srt_div\n', 'module fpu_srt_div_control\n'))
            write('candidate.sv', new)
            # A wrong shift for the lowest set bit must be detected in the real
            # engine, not merely by testing a helper in isolation.
            bad = new.replace("cz = int'(srt_input_clz64(manr));",
                              "cz = int'(srt_input_clz64(manr)) ^ 1;")
            assert bad != new
            write('bad-sqrt.sv', bad)
            for label, candidate, expected in (('positive', 'candidate.sv', 0), ('bad-sqrt', 'bad-sqrt.sv', 1)):
                obj = out/('obj-'+label)
                command = [repo/'tools/verilator_serial.sh', '-j', '32', '--binary',
                    '--timing', '--assert', '--threads', '1', '-Wall', '-Wno-UNUSED',
                    '-Wno-fatal', '-Werror-IMPLICIT', '-Werror-PINMISSING', '-Werror-UNDRIVEN',
                    '-Werror-MULTIDRIVEN', '-Werror-LATCH', '-Werror-UNOPTFLAT',
                    '+define+VEN_FPREM', '--Mdir', obj, '--top-module', 'tb_input_norm_miter',
                    package, out/'control.sv', out/candidate, here/'tb_input_norm_miter.sv']
                run(label+'-build', command, seconds=300, heavy=True)
                binary = obj/'Vtb_input_norm_miter'
                pins[str(binary)] = sha(binary)
                run(label, [binary], expected, seconds=90,
                    marker='SRT_INPUT_STATE_MISMATCH' if expected else
                    'SRT-INPUT-NORM-MITER-OK samples=4544 ')
        result['passed'] = True
    except BaseException as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(pins=pins, pins_unchanged=all(sha(p)==h for p,h in pins.items()),
                  rows=rows, seconds=time.monotonic()-began)
    result['passed'] &= result['pins_unchanged']
    save('closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
