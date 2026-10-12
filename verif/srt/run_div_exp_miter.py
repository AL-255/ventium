#!/usr/bin/env python3
"""Sequential divider-width A/B gate; needs the shared heavy-build scope.

Compiles actual old/new engines in both remainder-port configurations. Each
bad arithmetic variant is separately compiled and must fail in the real engine.
This does not provide an independent numerical oracle or whole-core acceptance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import signal
import subprocess
import time
import traceback

import prepare_div_exp_width as recipe


def sha(p):
    with Path(p).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def variants(source):
    new = recipe.transform(source)
    result = [('positive', new)]
    for label, before, after in (
        ('zero-bias', "? 15'd1 : encoded", "? 15'd0 : encoded"),
        ('unsigned', '{{16{adjusted[15]}}, adjusted}', "{16'd0, adjusted}"),
        ('too-narrow', '[15:0] adjusted', '[14:0] adjusted'),
    ):
        assert new.count(before) == 1
        bad = new.replace(before, after)
        if label == 'too-narrow':
            bad = bad.replace('{{16{adjusted[15]}}, adjusted}', '{{17{adjusted[14]}}, adjusted}')
        result.append((label, bad))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'leaf', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    leaf = args.leaf.resolve(strict=True)
    out = args.out.resolve()
    repo = Path(__file__).resolve().parents[2]
    here = Path(__file__).resolve().parent
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and os.environ.get('INVOCATION_ID')
    assert out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 4*1024**3
    assert os.environ['VENTIUM_VERILATOR_BIN'] == '/tools/verilator/v5.046/bin/verilator'
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    subprocess.run([repo/'tools/build_scope.sh', '--is-active'],
                   pass_fds=(9,), check=True, timeout=10)
    leaf_closed = json.loads((leaf/'closed.json').read_text())
    assert leaf_closed['passed'] and leaf_closed['pins_unchanged']
    assert all(sha(p) == h for p, h in leaf_closed['pins'].items())
    old = source.read_text()
    package = source.with_name('fpu_x87_pkg.sv')
    assert sha(source) == recipe.PARENT and sha(package) == recipe.PACKAGE
    assert (leaf/'candidate.sv').read_text() == recipe.transform(old)
    assert old.count('module fpu_srt_div\n') == 1
    inputs = (source, package, leaf/'closed.json', here/'tb_div_exp_miter.sv',
        Path(__file__), Path(recipe.__file__), repo/'tools/build_scope.sh',
        repo/'tools/verilator_serial.sh', Path('/tools/verilator/v5.046/bin/verilator'),
        Path('/tools/verilator/v5.046/bin/verilator_bin'))
    pins = {str(p): sha(p) for p in inputs}
    pins.update(leaf_closed['pins'])
    out.mkdir()

    def save(name, data):
        with (out/name).open('x') as stream:
            json.dump(data, stream, indent=2)

    def write(name, text):
        with (out/name).open('x') as stream:
            stream.write(text)
        pins[str(out/name)] = sha(out/name)

    rows = []

    def run(label, command, seconds, heavy=False):
        command = list(map(str, command))
        save(label+'.command.json', command)
        began = time.monotonic()
        with (out/(label+'.log')).open('x') as stream:
            with subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT,
                    pass_fds=(9,) if heavy else (), start_new_session=True) as child:
                # This samples the real launched child, not a systemd property.
                affinity = sorted(os.sched_getaffinity(child.pid))
                try:
                    native_exit = child.wait(timeout=seconds)
                except BaseException:
                    if child.poll() is None:
                        os.killpg(child.pid, signal.SIGTERM)
                        try:
                            child.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            os.killpg(child.pid, signal.SIGKILL)
                            child.wait(timeout=10)
                    raise
        row = dict(label=label, command=command, native_exit=native_exit,
                   child_affinity=affinity, seconds=time.monotonic()-began,
                   log_sha256=sha(out/(label+'.log')))
        rows.append(row)
        return row, (out/(label+'.log')).read_text()

    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
                              controller_affinity=sorted(os.sched_getaffinity(0))))
    began = time.monotonic()
    result = dict(passed=False, errors=[], whole_engine=True, whole_core=False,
                  independent_numeric_oracle=False, gameplay_ipc=None, fmax_mhz=None)
    try:
        write('control.sv', old.replace('module fpu_srt_div\n', 'module fpu_srt_div_control\n'))
        for label, text in variants(old):
            write(label+'.sv', text)
            for split in ((False, True) if label == 'positive' else (True,)):
                name = label+('-split' if split else '-shared')
                obj = out/('obj-'+name)
                command = [repo/'tools/verilator_serial.sh', '-j', '32', '--binary',
                    '--timing', '--assert', '--threads', '1', '-Wall', '-Wno-UNUSED',
                    '-Wno-fatal', *['-Werror-'+w for w in (
                    'IMPLICIT', 'PINMISSING', 'UNDRIVEN', 'MULTIDRIVEN', 'LATCH', 'UNOPTFLAT')],
                    '+define+VEN_FPREM', *(['+define+VEN_SRT_REM_OPERAND_SPLIT'] if split else []),
                    '--Mdir', obj, '--top-module', 'tb_div_exp_miter', package,
                    out/'control.sv', out/(label+'.sv'), here/'tb_div_exp_miter.sv']
                built, _ = run(name+'-build', command, 240, heavy=True)
                assert built['native_exit'] == 0, built
                binary = obj/'Vtb_div_exp_miter'
                pins[str(binary)] = sha(binary)
                native, log = run(name, [binary], 90)
                if label == 'positive':
                    assert native['native_exit'] == 0 and 'DIV-EXP-MITER-OK samples=29537 ' in log, native
                else:
                    assert native['native_exit'] != 0 and 'DIV_EXP_STATE_MISMATCH' in log, native
        result['passed'] = True
    except BaseException as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(rows=rows, pins=pins, seconds=time.monotonic()-began,
                  pins_unchanged=all(sha(p) == h for p, h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save('closed.json', result)
    print(json.dumps({k: v for k, v in result.items() if k != 'pins'}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
