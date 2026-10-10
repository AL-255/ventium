#!/usr/bin/env python3
"""Actual decoder + source-extracted FP admission miter, with negative controls."""
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
from prepare_fp_nomem_exec import transform

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def statement(source, name, assigned=True):
    source = re.sub(r'/\*.*?\*/|//[^\n]*', '', source, flags=re.S)
    prefix = r'  assign ' if assigned else r'    '
    matches = re.findall(prefix + re.escape(name) + r'\s*=.*?;', source, re.S)
    if len(matches) != 1:
        raise ValueError((name, len(matches)))
    s = matches[0].strip()
    return (s if assigned else 'assign ' + s) + '\n'


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
    out.mkdir()
    source = parent/'ventium/rtl/core/core.sv'
    original = source.read_text()
    changed = transform(original)
    manifest = parent/'input-manifest.json'
    defs = set(json.loads(manifest.read_text())['hardware_defines']) - {'SYNTHESIS'}
    assert {'VEN_FP_SHARED_DIRECT', 'VEN_FP_MEM_ADMIT', 'VEN_SYS_FASTPATH'} <= defs
    modules = [parent/'ventium/rtl'/p for p in (
        'ventium_pkg.sv', 'core/ventium_alu_pkg.sv', 'core/ventium_decode_pkg.sv', 'core/decode.sv')]
    pins = {str(p): sha(p) for p in [source, manifest, *modules, Path(__file__),
        HERE/'prepare_fp_nomem_exec.py', HERE/'prepare_fp_nomem_arm.py', HERE/'test_fp_nomem_exec.py', HERE/'fp_nomem_exec_leaf.svh']}

    def save(name, value):
        with (out/name).open('x') as f:
            json.dump(value, f, indent=2)

    def run(name, command, timeout):
        save(name+'.command.json', list(map(str, command)))
        with (out/(name+'.log')).open('x') as f:
            p = subprocess.run(command, stdout=f, stderr=subprocess.STDOUT, timeout=timeout, pass_fds=(9,))
        return p.returncode, (out/(name+'.log')).read_text()

    baseline = statement(original, 'pipe_u_eff')
    # Select the SYS_FASTPATH arm, shared by all three tested profiles.
    uncommented = re.sub(r'/\*.*?\*/|//[^\n]*', '', original, flags=re.S)
    sys_bail = uncommented[uncommented.index('  assign fp_sys_bail ='):].split(';', 1)[0] + ';\n'
    baseline += sys_bail
    for name in ('pipe_new_load_req', 'pipe_new_store_req', 'pipe_new_mem_req', 'pipe_load_req', 'pipe_store_req'):
        baseline += statement(original, name, False)
    baseline += statement(original, 'pipe_mem_wait')
    baseline += statement(original, 'fp_fast_trap_bail')
    baseline += statement(original, 'pipe_fp_live_arm').replace('pipe_fp_live_arm', 'reference_arm')
    baseline += statement(original, 'pipe_fp_fast_exec_ok').replace('pipe_fp_live_arm', 'reference_arm').replace('pipe_fp_fast_exec_ok', 'reference_exec')
    assert statement(changed, 'pipe_fp_live_arm') == statement(original, 'pipe_fp_live_arm')
    raw_live = statement(changed, 'pipe_fp_live_arm').replace('pipe_fp_live_arm', 'candidate_live_raw')
    cand_arm = statement(changed, 'pipe_fp_nomem_arm').replace('pipe_fp_nomem_arm', 'candidate_arm')
    cand_exec = statement(changed, 'pipe_fp_fast_exec_ok').replace('pipe_fp_nomem_arm', 'candidate_arm').replace('pipe_fp_fast_exec_ok', 'candidate_exec')
    template = (HERE/'fp_nomem_exec_leaf.svh').read_text()
    marker = '  // ASSIGNMENTS_INSERTED_FROM_FROZEN_CORE'
    assert template.count(marker) == 1
    rows = []
    start = time.monotonic()
    result = dict(passed=False, rows=rows, errors=[], standard_suite=False, gameplay_ipc=None)
    try:
        env = dict(os.environ, FP_NOMEM_PARENT=str(source))
        with (out/'recipe-tests.log').open('x') as f:
            p = subprocess.run(['python3', '-B', HERE/'test_fp_nomem_exec.py', '-v'], env=env, stdout=f, stderr=subprocess.STDOUT)
        assert p.returncode == 0
        profiles = [
            ('hardware', defs, None),
            ('strict-mf', defs | {'VEN_X87_MF_STRICT'}, None),
            ('legacy', {'VTM_NO_DPI', 'VEN_SYS_FASTPATH', 'VEN_FP_PIPE', 'VEN_FP_PIPE2', 'VEN_SRT_ITER'}, None),
            ('mutant-owner', defs, 'owner'),
            ('mutant-ack', defs, 'ack'),
            ('mutant-trap', defs | {'VEN_X87_MF_STRICT'}, 'trap'),
            ('mutant-shared-permit', defs, 'shared')]
        for label, profile, mutation in profiles:
            leaf = out/label
            leaf.mkdir()
            arm, executable, live = cand_arm, cand_exec, raw_live
            if mutation == 'shared': live = 'assign candidate_live_raw = candidate_arm;\n'
            if mutation == 'owner': arm = arm.replace('!pipe_mem_active_q', "1'b1")
            if mutation == 'ack': arm = arm.replace('!u_d.is_store;', '!u_d.is_store && mem_ack;')
            if mutation == 'trap': executable = executable.replace('!fp_fast_trap_bail', "1'b1")
            tb = leaf/'tb_fp_nomem_arm.sv'
            with tb.open('x') as f:
                f.write('module tb_fp_nomem_arm;\nimport ventium_pkg::*;\nimport ventium_alu_pkg::*;\nimport ventium_decode_pkg::*;\n')
                f.write(template.replace(marker, baseline + arm + executable + live))
                f.write('\nendmodule\n')
            pins[str(tb)] = sha(tb)
            command = ['/tools/verilator/v5.046/bin/verilator', '--binary', '--timing', '--assert',
                '-j', '32', '-Wno-fatal', '-Wno-UNUSED', *['-Werror-'+w for w in
                    ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                '--top-module', 'tb_fp_nomem_arm', '--Mdir', str(leaf/'obj'),
                *['+define+'+d for d in sorted(profile)], *map(str, modules), str(tb)]
            rc, log = run(label+'-build', command, 180)
            assert rc == 0, (label, 'build', rc)
            binary = leaf/'obj/Vtb_fp_nomem_arm'
            rc, log = run(label+'-run', [binary], 120)
            if mutation:
                assert rc != 0 and ('NOMEM_EQUIV' in log or 'NOMEM_WAIT_ESCAPE' in log or 'NOMEM_SHARED_PERMIT' in log), (label, rc)
            else:
                assert rc == 0 and len(re.findall(r'^FP-NOMEM-MITER-OK ', log, re.M)) == 1, (label, rc)
            rows.append(dict(profile=label, defines=sorted(profile), native_exit=rc,
                binary_sha256=sha(binary), expected_negative=bool(mutation), log_sha256=sha(out/(label+'-run.log'))))
        result['passed'] = True
    except Exception as error:
        result['errors'].append(repr(error))
    finally:
        result.update(pins_unchanged=all(sha(p) == h for p, h in pins.items()), seconds=time.monotonic()-start)
        result['passed'] &= result['pins_unchanged']
        save('pins.json', pins)
        save('closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
