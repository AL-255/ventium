#!/usr/bin/env python3
"""Source-extracted V carry cofactor with real V ALUs and two negative controls.

This proves paired payload equivalence only, not whole-core reachability,
architectural correctness, timing, standard-suite or FPGA acceptance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess
import time
from prepare_v_carry_payload import OLD, NEW, transform

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent-export', required=True, type=Path)
    ap.add_argument('--out', required=True, type=Path)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    parent, out = args.parent_export.resolve(strict=True), args.out.resolve()
    assert __debug__ and out.is_relative_to(scratch) and not out.is_relative_to(parent)
    assert Path(os.environ['TMPDIR']).resolve().is_relative_to(scratch)
    assert shutil.disk_usage(scratch).free > 4 * 1024**3
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], check=True, pass_fds=(9,))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    source = parent/'ventium/rtl/core/core.sv'
    original = source.read_text()
    changed = transform(original)
    manifest = parent/'input-manifest.json'
    defines = set(json.loads(manifest.read_text())['hardware_defines']) - {'SYNTHESIS'}
    assert {'VEN_P54_DUAL_READ_ALU_PAIR', 'VEN_P54_DUAL_BYTE_LOAD_PAIR', 'VEN_SYS_FASTPATH'} <= defines
    modules = [parent/'ventium/rtl'/p for p in (
        'ventium_pkg.sv', 'core/ventium_alu_pkg.sv', 'core/ventium_decode_pkg.sv', 'core/v_pipe.sv')]
    paths = [source, manifest, *modules, Path(__file__), HERE/'prepare_v_carry_payload.py',
             HERE/'test_v_carry_payload.py', HERE/'v_carry_payload_leaf.svh']
    pins = {str(p): sha(p) for p in paths}
    out.mkdir()

    def save(name, value):
        with (out/name).open('x') as f:
            json.dump(value, f, indent=2)

    def run(name, command, timeout, env=None):
        save(name+'.command.json', list(map(str, command)))
        with (out/(name+'.log')).open('x') as f:
            child = subprocess.run(command, stdout=f, stderr=subprocess.STDOUT,
                                   timeout=timeout, env=env, pass_fds=(9,))
        return child.returncode, (out/(name+'.log')).read_text()

    started = time.monotonic()
    result = dict(passed=False, runs=[], error=None, standard_suite=False,
                  hardware_acceptance=False, gameplay_ipc=None, timing_mhz=None)
    try:
        with (out/'core.sv').open('x') as f:
            f.write(changed)
        rc, _ = run('recipe', ['python3', '-B', HERE/'test_v_carry_payload.py', '-v'], 30,
                    dict(os.environ, V_CARRY_PARENT=str(source)))
        assert rc == 0, ('recipe', rc)
        # Both equations come verbatim from the pinned transform, not a
        # separately reimplemented carry formula in the miter.
        assert original.count(OLD) == 1 and changed.count(NEW) == 1
        body = (HERE/'v_carry_payload_leaf.svh').read_text()
        marker = '  // SOURCE_EXTRACTED_CARRY_BLOCKS'
        assert body.count(marker) == 1
        body = body.replace(marker, OLD.replace('v_input_flags', 'reference_flags') + '\n' +
                            NEW.replace('v_input_flags', 'candidate_flags'))
        tb = out/'tb_v_carry_payload.sv'
        with tb.open('x') as f:
            f.write('module tb_v_carry_payload;\n' + body + '\nendmodule\n')
        pins.update({str(tb): sha(tb), str(out/'core.sv'): sha(out/'core.sv')})
        rc, _ = run('build', ['/tools/verilator/v5.046/bin/verilator', '--binary', '--timing',
            '--assert', '-j', '32', '-Wno-fatal', '-Wno-UNUSED',
            *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
            '--top-module', 'tb_v_carry_payload', '--Mdir', str(out/'obj'),
            *['+define+'+d for d in sorted(defines)], *map(str, modules), str(tb)], 180)
        assert rc == 0, ('build', rc)
        binary = out/'obj/Vtb_v_carry_payload'
        pins[str(binary)] = sha(binary)
        for name, plusarg in (('hardware', None), ('mutant-carry', '+mutant_carry'),
                              ('mutant-zero-count', '+mutant_zero')):
            rc, log = run(name, [binary] + ([plusarg] if plusarg else []), 60)
            if plusarg:
                assert rc != 0 and 'V_CARRY_PAYLOAD_EQ' in log, (name, rc)
            else:
                assert rc == 0 and 'V-CARRY-PAYLOAD-OK samples=688128 paired=344064 ' in log, (name, rc)
            result['runs'].append(dict(name=name, native_exit=rc, expected_negative=bool(plusarg),
                                       log_sha256=sha(out/(name+'.log'))))
        result.update(passed=True, defines=sorted(defines), candidate_core_sha256=sha(out/'core.sv'))
    except Exception as error:
        result['error'] = repr(error)
    finally:
        result.update(pins_unchanged=all(sha(p) == h for p, h in pins.items()),
                      seconds=time.monotonic()-started)
        result['passed'] &= result['pins_unchanged']
        save('pins.json', pins)
        save('closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
